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
// =============================================================================

import Redis from 'npm:ioredis@5.4.1';

const REDIS_URL = Deno.env.get('REDIS_URL') ||
  `redis://default:${Deno.env.get('REDIS_PASSWORD') || ''}@redis:6379/1`;

let redisClient: Redis | null = null;

function getRedis(): Redis {
  if (!redisClient) {
    redisClient = new Redis(REDIS_URL, {
      db: 1, // Isolated from Kong rate limiting (DB 0)
      keyPrefix: 'app:',
      maxRetriesPerRequest: 3,
      enableReadyCheck: true,
      lazyConnect: false,
      retryStrategy(times) {
        if (times > 5) return null;
        return Math.min(times * 100, 2000);
      },
    });

    redisClient.on('error', (err: Error) => {
      console.error('[redis] connection error:', err.message);
    });
  }
  return redisClient;
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

Deno.serve(async (req: Request) => {
  // ── 1. Handle CORS preflight ──────────────────────────────────────────────
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  try {
    const url = new URL(req.url);
    const redis = getRedis();

    // ── 2. Health check endpoint (?health=true) ─────────────────────────────
    if (url.searchParams.get('health') === 'true') {
      const pong = await redis.ping();
      const dbsize = await redis.dbsize();
      return jsonResponse({
        ok: true,
        service: 'redis-cache',
        ping: pong,
        keys: dbsize,
      });
    }

    // ── 3. GET: Read a cached key ───────────────────────────────────────────
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

    // ── 4. POST: Write / update a cached key ────────────────────────────────
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

    // ── 5. DELETE: Remove a cached key ──────────────────────────────────────
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
    const message = err instanceof Error ? err.message : String(err);
    console.error('[cache function] error:', message);
    return jsonResponse({ error: 'Internal server error', details: message }, 500);
  }
});
