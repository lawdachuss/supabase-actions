// =============================================================================
// 🔗 redis-http — permanent HTTPS bridge to the self-hosted Redis
// =============================================================================
// Served at /functions/v1/redis-http via Kong. Lets the frontend API (which
// runs on Vercel and therefore cannot run `cloudflared access tcp`) talk to
// the self-hosted Redis over plain HTTPS — no bore.pub, no ephemeral ports, no
// vendor. This is the "permanent Redis" address the app was missing.
//
//   POST /functions/v1/redis-http          { "cmd": "get",  "args": ["api:home"] }
//   POST /functions/v1/redis-http          { "pipeline": [{ "cmd": "setex", "args": [...] }, ...] }
//   GET  /functions/v1/redis-http?health=true
//
// Auth (mandatory, even though FUNCTIONS_VERIFY_JWT is off): send the service
// role key (or REDIS_LINK_TOKEN when set) as `apikey:` header or
// `Authorization: Bearer <key>`. Without it the endpoint answers 401 — the
// commands here can mutate cache data, so it must never be anonymous.
//
// The connection uses DB 0 with no prefix — exactly the keyspace the frontend
// API already used over the old bore tunnel, so the existing cache survives.
// Replies are JSON (deep-converted from Buffers); session gaps answer 503 with
// Retry-After so clients back off instead of hanging (same contract as the
// `cache` function).
// =============================================================================

import Redis from 'npm:ioredis@5.4.1';

const REDIS_URL =
  Deno.env.get('REDIS_URL') ||
  `redis://default:${Deno.env.get('REDIS_PASSWORD') || ''}@redis:6379/0`;

const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const LINK_TOKEN = Deno.env.get('REDIS_LINK_TOKEN') || '';

const READY_GRACE_MS = Number(Deno.env.get('REDIS_READY_GRACE_MS') ?? 1500);
const RETRY_AFTER_SECONDS = Number(Deno.env.get('REDIS_RETRY_AFTER') ?? 5);

// Cap a single request: a big batch is still a tiny fraction of the 128mb
// cache, and the public endpoint must not be a way to stuff the store.
const MAX_PIPELINE_OPS = 256;
const MAX_ARGS_PER_CMD = 32;
const MAX_VALUE_CHARS = 1_000_000;

// Only commands the app actually uses are allowed through. Deliberately no
// FLUSH/KEYS/CONFIG/DEBUG/EVAL/SCRIPT/CLUSTER/SUBSCRIBE.
const ALLOWED_COMMANDS = new Set([
  'PING', 'GET', 'SET', 'SETEX', 'SETNX', 'DEL', 'EXPIRE', 'TTL', 'INCR',
  'SCAN', 'DBSIZE', 'SMEMBERS', 'SADD', 'HEXISTS', 'HGET', 'HMGET', 'HSET',
  'ZADD', 'ZINCRBY', 'ZRANGE', 'ZREVRANGE', 'ZCARD', 'ZREM', 'XADD', 'XTRIM',
  'XGROUP', 'XREADGROUP', 'XACK', 'DECRBY',
]);

// ─── Lazy singleton connection (self-heals across session gaps) ─────────────
let client: Redis | null = null;
const conn = {
  reconnects: 0,
  lastError: null as string | null,
  lastErrorAt: null as string | null,
  readySince: null as string | null,
};

function getRedis(): Redis {
  if (!client) {
    client = new Redis(REDIS_URL, {
      db: 0, // Must match the frontend API's historic keyspace (see header).
      keyPrefix: '',
      enableOfflineQueue: false,
      maxRetriesPerRequest: 2,
      connectTimeout: 5000,
      keepAlive: 10000,
      enableReadyCheck: true,
      retryStrategy(times: number) {
        const backoff = Math.min(200 * 2 ** Math.min(times, 6), 15000);
        const jitter = Math.floor(Math.random() * 250);
        return backoff + jitter;
      },
    });
    client.on('error', (err: Error) => {
      conn.lastError = err.message;
      conn.lastErrorAt = new Date().toISOString();
      console.error('[redis-http] connection error:', err.message);
    });
    client.on('reconnecting', (delay: number) => {
      conn.reconnects++;
      conn.readySince = null;
      console.log(`[redis-http] reconnecting in ${delay}ms (attempt ${conn.reconnects})`);
    });
    client.on('ready', () => {
      conn.readySince = new Date().toISOString();
      console.log(`[redis-http] connection ready (reconnects: ${conn.reconnects})`);
    });
  }
  return client;
}

function isReady(c: Redis): boolean {
  return c.status === 'ready';
}

async function awaitReady(c: Redis, ms = READY_GRACE_MS): Promise<boolean> {
  if (isReady(c)) return true;
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (isReady(c)) return true;
  }
  return false;
}

// ─── Reply serialization ─────────────────────────────────────────────────────
// ioredis returns Buffers for binary-ish replies (except streams/zset, which
// it stringifies via its own reply transformers). Anything else surfaced as a
// Buffer must still round-trip over JSON, so convert every Buffer to utf8.
function toJson(value: unknown): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  // ioredis returns Buffers for binary-ish replies (except streams/zset, which
  // it stringifies via its own reply transformers). Buffer extends Uint8Array,
  // so this single check covers both without depending on Node's Buffer global.
  if (value instanceof Uint8Array) return new TextDecoder().decode(value);
  if (Array.isArray(value)) return value.map(toJson);
  if (value instanceof Error) return { error: value.message };
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = toJson(v);
    }
    return out;
  }
  return String(value);
}

// ─── HTTP helpers ────────────────────────────────────────────────────────────
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Max-Age': '86400',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

function unavailable(c: Redis): Response {
  return new Response(
    JSON.stringify({
      error: 'Redis is temporarily unavailable',
      code: 'REDIS_UNAVAILABLE',
      retryable: true,
      status: c.status,
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

function authorize(req: Request): boolean {
  const header = req.headers.get('apikey') || '';
  const bearer = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const token = header || bearer;
  if (!token) return false;
  if (LINK_TOKEN && token === LINK_TOKEN) return true;
  return SERVICE_ROLE_KEY !== '' && token === SERVICE_ROLE_KEY;
}

interface Cmd {
  cmd: string;
  args: unknown[];
}

function parseCmd(raw: unknown): Cmd | null {
  if (!raw || typeof raw !== 'object') return null;
  const { cmd, args } = raw as { cmd?: unknown; args?: unknown };
  if (typeof cmd !== 'string' || cmd.length === 0 || cmd.length > 64) return null;
  if (!Array.isArray(args) || args.length > MAX_ARGS_PER_CMD) return null;
  return { cmd, args };
}

function stringifyArgs(args: unknown[]): string[] {
  return args.map((a) => {
    if (typeof a === 'string') return a;
    if (typeof a === 'number' || typeof a === 'boolean') return String(a);
    if (a === null || a === undefined) return '';
    return JSON.stringify(a);
  });
}

// ─── Composer that keeps the ioredis `pipeline` reply contract ──────────────
// ioredis pipeline().exec() resolves to [[err | null, reply], ...]. Over HTTP
// we run the batch sequentially on the single keep-alive connection and return
// the same shape so the client's compatibility layer stays trivial.
async function execBatch(rawCmds: unknown[], r: Redis): Promise<unknown> {
  if (!Array.isArray(rawCmds) || rawCmds.length === 0) return [];
  if (rawCmds.length > MAX_PIPELINE_OPS) {
    throw new Error(`pipeline too large: max ${MAX_PIPELINE_OPS} ops`);
  }
  const results: Array<[string | null, unknown]> = [];
  for (const raw of rawCmds) {
    const parsed = parseCmd(raw);
    if (!parsed) {
      results.push([`invalid command: ${JSON.stringify(raw).slice(0, 120)}`, null]);
      continue;
    }
    const canonical = parsed.cmd.toUpperCase();
    if (!ALLOWED_COMMANDS.has(canonical)) {
      results.push([`command '${parsed.cmd}' is not allowed`, null]);
      continue;
    }
    try {
      const args = stringifyArgs(parsed.args);
      const total = args.reduce((n, a) => n + a.length, 0);
      if (total > MAX_VALUE_CHARS) throw new Error('command args too large');
      //eslint-disable-next-line @typescript-eslint/no-explicit-any
      const reply = await (r as any)[canonical.toLowerCase()](...args);
      results.push([null, toJson(reply)]);
    } catch (err) {
      results.push([err instanceof Error ? err.message : String(err), null]);
    }
  }
  return results;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });

  if (!authorize(req)) {
    return json({ error: 'unauthorized', code: 'UNAUTHORIZED' }, 401);
  }

  const url = new URL(req.url);
  const r = getRedis();

  // ── GET ?health=true — liveness probe (not an auth bypass: gated above) ───
  if (req.method === 'GET' && url.searchParams.get('health') === 'true') {
    if (!(await awaitReady(r, 3000))) {
      return json(
        {
          ok: false,
          service: 'redis-http',
          status: r.status,
          reconnects: conn.reconnects,
          last_error: conn.lastError,
          last_error_at: conn.lastErrorAt,
        },
        503,
      );
    }
    try {
      const started = performance.now();
      const pong = await r.ping();
      const latency = Math.round(performance.now() - started);
      const dbsize = await r.dbsize();
      return json({
        ok: true,
        service: 'redis-http',
        status: r.status,
        ping: pong,
        latency_ms: latency,
        keys: dbsize,
        reconnects: conn.reconnects,
        ready_since: conn.readySince,
      });
    } catch (err) {
      console.error('[redis-http] health ping failed:', err);
      return unavailable(r);
    }
  }

  // ── POST — one command or a pipeline ──────────────────────────────────────
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  if (!(await awaitReady(r))) return unavailable(r);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'invalid JSON body' }, 400);
  }

  if (typeof body !== 'object' || body === null) {
    return json({ error: 'body must be { cmd, args } or { pipeline }' }, 400);
  }

  try {
    if ('pipeline' in (body as Record<string, unknown>)) {
      const reply = await execBatch((body as { pipeline?: unknown }).pipeline, r);
      return json({ ok: true, results: reply });
    }

    const parsed = parseCmd(body);
    if (!parsed) return json({ error: 'body must be { cmd, args }' }, 400);

    const canonical = parsed.cmd.toUpperCase();
    if (!ALLOWED_COMMANDS.has(canonical)) {
      return json({ error: `command '${parsed.cmd}' is not allowed`, code: 'COMMAND_NOT_ALLOWED' }, 403);
    }

    const args = stringifyArgs(parsed.args);
    const total = args.reduce((n, a) => n + a.length, 0);
    if (total > MAX_VALUE_CHARS) return json({ error: 'command args too large' }, 413);

    //eslint-disable-next-line @typescript-eslint/no-explicit-any
    const reply = await (r as any)[canonical.toLowerCase()](...args);
    return json({ ok: true, result: toJson(reply) });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    if (!isReady(r)) return unavailable(r);
    console.error('[redis-http] error:', message);
    return json({ error: 'internal error', details: message }, 500);
  }
});