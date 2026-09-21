// =============================================================================
// ⚡ Redis Cache API — served at /functions/v1/cache via Kong
// =============================================================================
// Provides a fast HTTP bridge to self-hosted Redis for external frontends
// (React, Vue, Next.js, Flutter, mobile apps).
//
// Usage from frontend:
//   GET    /functions/v1/cache?key=my_key
//   POST   /functions/v1/cache              Body: { "key": "my_key", "value": "data", "ttl": 3600 }
//   DELETE /functions/v1/cache?key=my_key
//   GET    /functions/v1/cache?health=true
//
// Headers:
//   apikey: <SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY>
//   Authorization: Bearer <SUPABASE_ANON_KEY or User JWT>
//
// ── Surviving session gaps ──────────────────────────────────────────────────
// This stack runs on ephemeral GitHub Actions runners, so Redis genuinely
// disappears for 1-2 minutes between sessions. Two rules make clients survive
// that instead of breaking:
//
//   1. NEVER stop retrying. ioredis' `retryStrategy` returning null puts the
//      client in a permanent `end` state — after which every request fails
//      until the container is restarted. We reconnect forever instead, with
//      capped exponential backoff + jitter.
//   2. Fail FAST, not slow. While disconnected we return 503 + `Retry-After`
//      rather than queueing commands (which would hang the HTTP request for the
//      whole outage). A short in-request grace window makes sub-second blips
//      invisible; anything longer is handed back to the client to retry.
// =============================================================================

import Redis from 'npm:ioredis@5.4.1';

const REDIS_URL = Deno.env.get('REDIS_URL') ||
  `redis://default:${Deno.env.get('REDIS_PASSWORD') || ''}@redis:6379/1`;

// How long a request will wait for a reconnect before giving up (ms), and what
// we tell clients to wait before retrying (seconds).
const READY_GRACE_MS = Number(Deno.env.get('REDIS_READY_GRACE_MS') ?? 1500);
const RETRY_AFTER_SECONDS = Number(Deno.env.get('REDIS_RETRY_AFTER') ?? 5);

let redisClient: Redis | null = null;

// Diagnostics surfaced by ?health=true — how often the connection had to be
// re-established, and when/why it last failed.
const conn = {
  reconnects: 0,
  lastError: null as string | null,
  lastErrorAt: null as string | null,
  readySince: null as string | null,
};

function getRedis(): Redis {
  if (!redisClient) {
    redisClient = new Redis(REDIS_URL, {
      db: 1, // Isolated from Kong rate limiting (DB 0)
      keyPrefix: 'app:',
      // Don't queue commands while disconnected: this is an HTTP bridge, so a
      // queued command would hang the request for the entire outage. We check
      // readiness up front and answer 503 instead.
      enableOfflineQueue: false,
      // Small per-command retry budget; the loop that actually matters is
      // `retryStrategy` below, which is what survives the gap.
      maxRetriesPerRequest: 2,
      connectTimeout: 5000,
      keepAlive: 10000,
      enableReadyCheck: true,
      lazyConnect: false,
      // Reconnect FOREVER with capped exponential backoff + jitter.
      // (Returning null here — as this function used to — permanently ends the
      // client and makes the gap unrecoverable.)
      retryStrategy(times: number) {
        const backoff = Math.min(200 * 2 ** Math.min(times, 6), 15000);
        const jitter = Math.floor(Math.random() * 250);
        return backoff + jitter;
      },
    });

    redisClient.on('error', (err: Error) => {
      // Emitted on every failed reconnect attempt — keep only the latest.
      conn.lastError = err.message;
      conn.lastErrorAt = new Date().toISOString();
      console.error('[redis] connection error:', err.message);
    });
    redisClient.on('reconnecting', (delay: number) => {
      conn.reconnects++;
      conn.readySince = null;
      console.log(`[redis] reconnecting in ${delay}ms (attempt ${conn.reconnects})`);
    });
    redisClient.on('ready', () => {
      conn.readySince = new Date().toISOString();
      console.log(`[redis] connection ready (reconnects: ${conn.reconnects})`);
    });
  }
  return redisClient;
}

function isReady(client: Redis): boolean {
  return client.status === 'ready';
}

// Wait briefly for a reconnect so a short blip is transparent to the caller.
async function awaitReady(client: Redis, ms = READY_GRACE_MS): Promise<boolean> {
  if (isReady(client)) return true;
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (isReady(client)) return true;
  }
  return false;
}

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Max-Age': '86400',
};

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
    },
  });
}

function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}

// 503 + Retry-After: the honest answer when Redis is between sessions. Clients
// that honour Retry-After back off cleanly instead of hammering.
function unavailableResponse(client: Redis): Response {
  return new Response(
    JSON.stringify({
      error: 'Redis is temporarily unavailable',
      code: 'REDIS_UNAVAILABLE',
      retryable: true,
      status: client.status,
      reconnects: conn.reconnects,
      last_error: conn.lastError,
      last_error_at: conn.lastErrorAt,
    }),
    {
      status: 503,
      headers: {
        ...CORS_HEADERS,
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
        'Retry-After': String(RETRY_AFTER_SECONDS),
      },
    },
  );
}

Deno.serve(async (req: Request) => {
  // ── 1. Handle CORS preflight ──────────────────────────────────────────────
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  try {
    const url = new URL(req.url);
    const redis = getRedis();

    // ── 2. Health check endpoint (?health=true) ─────────────────────────────
    // Answers 200 when Redis is reachable and 503 when it isn't, so it doubles
    // as a proper liveness probe (a client can tell "session gap" from "bug").
    if (url.searchParams.get('health') === 'true') {
      if (!(await awaitReady(redis, 3000))) {
        return jsonResponse(
          {
            ok: false,
            service: 'redis-cache',
            status: redis.status,
            reconnects: conn.reconnects,
            last_error: conn.lastError,
            last_error_at: conn.lastErrorAt,
          },
          503,
        );
      }
      try {
        const started = performance.now();
        const pong = await redis.ping();
        const latency = Math.round(performance.now() - started);
        const dbsize = await redis.dbsize();
        return jsonResponse({
          ok: true,
          service: 'redis-cache',
          status: redis.status,
          ping: pong,
          latency_ms: latency,
          keys: dbsize,
          reconnects: conn.reconnects,
          ready_since: conn.readySince,
        });
      } catch (err) {
        console.error('[cache function] health ping failed:', err);
        return unavailableResponse(redis);
      }
    }

    // ── 3. Gate every data operation on a live connection ───────────────────
    if (!(await awaitReady(redis))) {
      return unavailableResponse(redis);
    }

    // ── 4. GET: Read a cached key ───────────────────────────────────────────
    if (req.method === 'GET') {
      const key = url.searchParams.get('key');
      if (!key) {
        return errorResponse("Missing 'key' query parameter (e.g. ?key=my_key)");
      }

      const raw = await redis.get(key);
      if (raw === null) {
        return jsonResponse({ key, value: null, exists: false }, 404);
      }

      // Automatically parse JSON if possible, otherwise return raw string
      let parsedValue: unknown = raw;
      try {
        parsedValue = JSON.parse(raw);
      } catch {
        // Leave as string if not JSON
      }

      const ttl = await redis.ttl(key);
      return jsonResponse({
        key,
        value: parsedValue,
        exists: true,
        ttl: ttl > 0 ? ttl : null,
      });
    }

    // ── 5. POST: Write / update a cached key ────────────────────────────────
    if (req.method === 'POST') {
      let body: { key?: string; value?: unknown; ttl?: number };
      try {
        body = await req.json();
      } catch {
        return errorResponse('Invalid JSON body');
      }

      const { key, value, ttl } = body;
      if (!key) {
        return errorResponse("Missing 'key' in JSON body");
      }
      if (value === undefined) {
        return errorResponse("Missing 'value' in JSON body");
      }

      const serialized = typeof value === 'string' ? value : JSON.stringify(value);

      if (typeof ttl === 'number' && ttl > 0) {
        await redis.set(key, serialized, 'EX', Math.floor(ttl));
      } else {
        await redis.set(key, serialized);
      }

      return jsonResponse({
        success: true,
        key,
        ttl: ttl || null,
      });
    }

    // ── 6. DELETE: Remove a cached key ──────────────────────────────────────
    if (req.method === 'DELETE') {
      const key = url.searchParams.get('key');
      if (!key) {
        return errorResponse("Missing 'key' query parameter (e.g. ?key=my_key)");
      }

      const deleted = await redis.del(key);
      return jsonResponse({
        success: true,
        key,
        deleted: deleted > 0,
      });
    }

    return errorResponse(`Method ${req.method} not allowed`, 405);
  } catch (err: unknown) {
    // A command that blew up because the socket dropped mid-request is a gap,
    // not a bug — report it as retryable so the client backs off and retries.
    const client = getRedis();
    if (!isReady(client)) {
      return unavailableResponse(client);
    }
    const message = err instanceof Error ? err.message : String(err);
    console.error('[cache function] error:', message);
    return jsonResponse({ error: 'Internal server error', details: message }, 500);
  }
});
