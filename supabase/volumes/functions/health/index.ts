// =============================================================================
// 🩺 Health API — served at /functions/v1/health via Kong
// =============================================================================
// Answers the two questions that actually matter for this stack:
//
//   1. Is Redis reachable?      → redis.ok
//   2. Is the tunnel reachable?  → tunnel.ok  (public hostname → Kong → here)
//
// Because this runs on ephemeral GitHub Actions runners, "down for 1-2 minutes
// between sessions" is normal and expected — clients should poll this endpoint
// and back off (it returns 503 + Retry-After) rather than treating a gap as a
// hard failure.
//
// Usage:
//   curl https://<your-domain>/functions/v1/health
//   curl https://<your-domain>/functions/v1/health?verbose=true   # + error text
//
// Status codes:
//   200  Redis + tunnel both reachable
//   503  one of them is down (body says which) — includes Retry-After
//
// No auth required: this exposes only liveness/latency, never data or secrets.
// =============================================================================

import Redis from 'npm:ioredis@5.4.1';

const REDIS_URL = Deno.env.get('REDIS_URL') ||
  `redis://default:${Deno.env.get('REDIS_PASSWORD') || ''}@redis:6379/1`;

// Public base URL. Falls back to the in-cluster Kong when the workflow runs
// without a tunnel domain, in which case there is no tunnel to probe.
const PUBLIC_URL = (Deno.env.get('SUPABASE_PUBLIC_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

// Budget for the whole check. Keep it short: callers may be polling.
const REDIS_TIMEOUT_MS = Number(Deno.env.get('HEALTH_REDIS_TIMEOUT_MS') ?? 3000);
const TUNNEL_TIMEOUT_MS = Number(Deno.env.get('HEALTH_TUNNEL_TIMEOUT_MS') ?? 5000);
const RETRY_AFTER_SECONDS = Number(Deno.env.get('REDIS_RETRY_AFTER') ?? 5);

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Max-Age': '86400',
};

// ── Redis ───────────────────────────────────────────────────────────────────
// A health probe must fail FAST, so this deliberately does the opposite of the
// cache function: no retries, short connect timeout, and a fresh client per
// request (so the report reflects *now*, not a stale pooled connection).
async function probeRedis(): Promise<Record<string, unknown>> {
  const client = new Redis(REDIS_URL, {
    db: 1,
    keyPrefix: 'app:',
    lazyConnect: true,
    enableOfflineQueue: false,
    maxRetriesPerRequest: 1,
    connectTimeout: REDIS_TIMEOUT_MS,
    retryStrategy: () => null, // one shot — we report, we don't heal
  });
  // ioredis emits 'error' asynchronously; without a listener it can crash the
  // worker, so swallow it (the awaited promise below surfaces the failure).
  client.on('error', () => {});

  try {
    const started = performance.now();
    await client.connect();
    const pong = await client.ping();
    const latency = Math.round(performance.now() - started);
    const keys = await client.dbsize();

    // Persistence insight — directly relevant to surviving runner restarts.
    const persistence: Record<string, string> = {};
    try {
      const info = await client.info('persistence');
      for (const key of [
        'aof_enabled',
        'aof_last_bgrewrite_status',
        'aof_last_write_status',
        'rdb_last_bgsave_status',
        'rdb_last_save_time',
      ]) {
        const match = info.match(new RegExp(`^${key}:(.*)$`, 'm'));
        if (match) persistence[key] = match[1].trim();
      }
      if (persistence.rdb_last_save_time) {
        persistence.rdb_last_save_iso =
          new Date(Number(persistence.rdb_last_save_time) * 1000).toISOString();
        delete persistence.rdb_last_save_time;
      }
    } catch {
      // INFO can be disabled/renamed — never fail the probe over it.
    }

    return { ok: true, status: 'ready', ping: pong, latency_ms: latency, keys, persistence };
  } catch (err) {
    return {
      ok: false,
      status: client.status,
      error: err instanceof Error ? err.message : String(err),
    };
  } finally {
    // disconnect() is safe on a never-connected client; quit() can reject.
    try {
      client.disconnect();
    } catch {
      /* already gone */
    }
  }
}

// ── Tunnel ──────────────────────────────────────────────────────────────────
async function probeUrl(url: string, timeoutMs: number): Promise<{ reachable: boolean; status: number | null; latency_ms: number; error?: string }> {
  const started = performance.now();
  try {
    const res = await fetch(url, {
      headers: ANON_KEY ? { apikey: ANON_KEY } : undefined,
      signal: AbortSignal.timeout(timeoutMs),
    });
    return { reachable: true, status: res.status, latency_ms: Math.round(performance.now() - started) };
  } catch (err) {
    return {
      reachable: false,
      status: null,
      latency_ms: Math.round(performance.now() - started),
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function probeTunnel(): Promise<Record<string, unknown>> {
  // No public hostname configured → the workflow is running without a tunnel,
  // so there is nothing to reach and nothing is broken.
  if (!PUBLIC_URL || /localhost|127\.0\.0\.1/.test(PUBLIC_URL)) {
    return {
      ok: true,
      mode: 'local',
      public_url: PUBLIC_URL || null,
      note: 'no public tunnel domain configured (CF_TUNNEL_DOMAIN unset)',
    };
  }

  // Primary probe: all the way out to the edge and back in — Cloudflare →
  // Kong → edge function → Redis. This proves the whole path end to end.
  const edge = await probeUrl(`${PUBLIC_URL}/functions/v1/cache?health=true`, TUNNEL_TIMEOUT_MS);
  if (edge.reachable) {
    return {
      ok: true,
      mode: 'cloudflare',
      public_url: PUBLIC_URL,
      status: edge.status,
      latency_ms: edge.latency_ms,
      // Any HTTP response means the tunnel is up; only a 200 means the whole
      // stack (Redis included) answered.
      end_to_end: edge.status === 200,
    };
  }

  // The edge-function path failed. Fall back to a plain Kong route to tell
  // "tunnel or Kong is down" apart from "only the functions worker is down".
  const kong = await probeUrl(`${PUBLIC_URL}/rest/v1/`, TUNNEL_TIMEOUT_MS);
  return {
    ok: kong.reachable,
    mode: 'cloudflare',
    public_url: PUBLIC_URL,
    status: kong.status,
    latency_ms: kong.latency_ms,
    end_to_end: false,
    gateway_reachable: kong.reachable,
    ...(kong.reachable ? {} : { error: kong.error }),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  const url = new URL(req.url);
  const verbose = url.searchParams.get('verbose') === 'true';

  // Probe both in parallel so the endpoint answers in ~one timeout, not two.
  const [redis, tunnel] = await Promise.all([probeRedis(), probeTunnel()]);

  const redisOk = redis.ok === true;
  const tunnelOk = tunnel.ok === true;
  const ok = redisOk && tunnelOk;

  let redisReport = redis;
  let tunnelReport = tunnel;
  if (!verbose) {
    // Keep failure details (which can include internal addresses) out of the
    // public response; ?verbose=true is available when debugging.
    const strip = ({ error: _drop, ...rest }: Record<string, unknown>) => rest;
    redisReport = strip(redis);
    tunnelReport = strip(tunnel);
  }

  const body = {
    ok,
    service: 'health',
    checked_at: new Date().toISOString(),
    redis: redisReport,
    tunnel: tunnelReport,
  };

  return new Response(JSON.stringify(body), {
    status: ok ? 200 : 503,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      ...(ok ? {} : { 'Retry-After': String(RETRY_AFTER_SECONDS) }),
    },
  });
});
