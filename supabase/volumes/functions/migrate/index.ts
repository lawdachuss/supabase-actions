// =============================================================================
// 🗄️ Remote DB Admin + Migrations API — served at /functions/v1/migrate
// =============================================================================
// Reachable from anywhere over the existing HTTPS tunnel:
//   GET    /functions/v1/migrate                    → list applied migrations + DB info
//   POST   /functions/v1/migrate                    → run SQL / apply migrations
//   DELETE /functions/v1/migrate?name=<file.sql>    → un-track a migration
// (also aliased as /api/migrate via Kong, with key-auth + admin ACL)
//
// Auth: the service_role key is required on EVERY request (exact match against
// SUPABASE_SERVICE_ROLE_KEY, or an HS256 JWT signed with JWT_SECRET that carries
// role=service_role) — exactly like the /api/logs function. The Kong /api/migrate
// alias adds a second layer, but the public /functions/v1 route ALSO reaches this
// function, so the key is always verified here too.
//
// POST bodies (JSON):
//   { "sql": "SELECT count(*) FROM users" }                    → one-off SQL (not tracked)
//   { "name": "003-x.sql", "sql": "ALTER TABLE ..." }           → tracked, idempotent
//   { "name": "003-x.sql", "sql": "...", "force": true }        → re-apply + bump applied_at
//   { "migrations": [ { "name":"...", "sql":"..." }, ... ] }    → batch, idempotent, ordered
//
// Backed by public._schema_migrations — the SAME table the GitHub Actions
// runner uses for committed migrations (supabase/migrations/*.sql). Remote and
// committed migrations therefore share one idempotent source of truth and never
// double-apply, and both survive the 6-hour session restarts via the state
// snapshot (a remote-applied migration is tracked, so the runner skips it too).
//
// Requirements:
//   * Migration SQL must be PURE SQL — no psql meta-commands (\c, \set, ...).
//   * This connects as the postgres superuser, so the service_role key is
//     effectively root. Keep it secret. Set MIGRATE_READONLY=true on the
//     functions service to turn POST/DELETE into 403s (read-only mode).
// =============================================================================
import postgres from 'npm:postgres@3.4.3';

const DB_URL = Deno.env.get('SUPABASE_DB_URL');
const JWT_SECRET = Deno.env.get('JWT_SECRET');
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const READONLY = Deno.env.get('MIGRATE_READONLY') === 'true';
const MAX_BODY = 4 * 1024 * 1024; // 4 MiB
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.sql$/;

let sql: ReturnType<typeof postgres> | null = null;
function db() {
  if (!sql) {
    if (!DB_URL) throw new Error('SUPABASE_DB_URL is not set on the functions service');
    sql = postgres(DB_URL, { max: 10, connect_timeout: 10 });
  }
  return sql;
}

// ── Auth (mirrors the /api/logs function) ──────────────────────────────────
const b64uToBytes = (s: string): Uint8Array => {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 ? '='.repeat(4 - (b64.length % 4)) : '';
  const bin = atob(b64 + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};

function bytesToB64u(b: Uint8Array): string {
  let bin = '';
  for (const byte of b) bin += String.fromCharCode(byte);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifyServiceKey(token: string): Promise<boolean> {
  if (SERVICE_KEY && token === SERVICE_KEY) return true; // exact match (fast path)
  if (!JWT_SECRET) return false;
  const parts = token.split('.');
  if (parts.length !== 3) return false;
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(new TextDecoder().decode(b64uToBytes(parts[1])));
  } catch {
    return false;
  }
  if (payload.role !== 'service_role') return false;
  if (typeof payload.exp === 'number' && payload.exp < Date.now() / 1000) return false;
  const data = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(JWT_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, data));
  return safeEqual(bytesToB64u(sig), parts[2]);
}

async function authorize(req: Request): Promise<boolean> {
  const url = new URL(req.url);
  const token =
    req.headers.get('apikey') ??
    url.searchParams.get('apikey') ??
    req.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  return !!token && (await verifyServiceKey(token));
}

// ── Response helpers ────────────────────────────────────────────────────────
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Max-Age': '86400',
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      ...CORS_HEADERS,
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

// ── Tracking table (shared with the GitHub Actions "Apply committed migrations" step)
async function ensureTrackingTable() {
  await db().unsafe(
    'CREATE TABLE IF NOT EXISTS public._schema_migrations (name text PRIMARY KEY, applied_at timestamptz DEFAULT now())',
  );
}

async function isApplied(name: string): Promise<boolean> {
  const rows = await db()`SELECT 1 FROM public._schema_migrations WHERE name = ${name} LIMIT 1`;
  return rows.length > 0;
}

async function recordApplied(name: string) {
  await db()`INSERT INTO public._schema_migrations (name, applied_at)
    VALUES (${name}, now())
    ON CONFLICT (name) DO UPDATE SET applied_at = now()`;
}

async function forgetApplied(name: string) {
  const res = await db()`DELETE FROM public._schema_migrations WHERE name = ${name}`;
  return Number(res?.[0]?.count ?? res?.count ?? 0) > 0;
}

// ── Handlers ────────────────────────────────────────────────────────────────
async function handleGet() {
  await ensureTrackingTable();
  const rows = await db()`SELECT name, applied_at FROM public._schema_migrations ORDER BY applied_at, name`;
  let database: Record<string, unknown> = { error: 'could not query server' };
  try {
    const r = await db().unsafe(
      'SELECT current_database() AS db, current_user AS user, version() AS version, pg_postmaster_start_time() AS started_at',
    );
    database = (r[0] as Record<string, unknown>) ?? {};
  } catch {
    // keep the fallback above
  }
  return {
    ok: true,
    service: 'migrate',
    readonly: READONLY,
    database,
    count: rows.length,
    applied: rows,
  };
}

async function handleDelete(name: string) {
  if (!NAME_RE.test(name)) {
    throw Object.assign(new Error('invalid migration name'), { status: 400 });
  }
  await ensureTrackingTable();
  const deleted = await forgetApplied(name);
  return { ok: true, untracked: name, deleted };
}

async function applyOne(name: string, scriptSql: string, force: boolean) {
  const already = await isApplied(name);
  if (already && !force) {
    return { name, status: 'skipped', detail: 'already applied (see untrack to re-apply)' };
  }
  try {
    await db().unsafe(scriptSql);
  } catch (e) {
    return { name, status: 'failed', error: e instanceof Error ? e.message : String(e) };
  }
  await recordApplied(name);
  return { name, status: 'applied', replayed: force === true && already ? true : undefined };
}

function bad(message: string) {
  return Object.assign(new Error(message), { status: 400 });
}

async function handlePost(body: unknown) {
  if (!body || typeof body !== 'object') throw bad('POST body must be a JSON object');
  const b = body as Record<string, unknown>;
  await ensureTrackingTable();

  // Batch mode: { migrations: [ {name, sql, force?}, ... ] }
  if (Array.isArray(b.migrations)) {
    const results = [];
    for (const m of b.migrations as Array<Record<string, unknown>>) {
      if (!m || typeof m.name !== 'string' || !NAME_RE.test(m.name)) {
        results.push({ name: (m?.name as string) ?? '?', status: 'failed', error: 'invalid name (must end in .sql, alnum/._-)' });
        continue;
      }
      if (typeof m.sql !== 'string' || !m.sql.trim()) {
        results.push({ name: m.name as string, status: 'failed', error: 'empty sql' });
        continue;
      }
      results.push(await applyOne(m.name as string, m.sql as string, m.force === true));
    }
    return { ok: true, readonly: READONLY, pushed: results.length, results };
  }

  if (typeof b.sql !== 'string' || !b.sql.trim()) {
    throw bad('POST body must be { sql } or { name, sql } or { migrations: [...] }');
  }

  // Tracked migration: { name, sql, force? }
  if (typeof b.name === 'string' && b.name) {
    if (!NAME_RE.test(b.name)) throw bad('invalid migration name (must end in .sql, alnum/._-)');
    const result = await applyOne(b.name, b.sql, b.force === true);
    return { ok: result.status !== 'failed', readonly: READONLY, result };
  }

  // One-off SQL
  const res = await db().unsafe(b.sql);
  return {
    ok: true,
    readonly: READONLY,
    rows: Array.isArray(res) ? (res as unknown[]).slice(0, 50) : res,
    count: Array.isArray(res) ? (res as unknown[]).length : undefined,
  };
}

// ── Entry ───────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (!(await authorize(req))) {
    return json({ ok: false, error: 'Unauthorized — service_role key required (apikey header/query)' }, 401);
  }
  try {
    const url = new URL(req.url);
    if (READONLY && (req.method === 'POST' || req.method === 'DELETE')) {
      return json({ ok: false, error: 'read-only mode (MIGRATE_READONLY=true)' }, 403);
    }
    switch (req.method) {
      case 'GET':
        return json(await handleGet());
      case 'DELETE': {
        const name = url.searchParams.get('name');
        if (!name) throw bad('missing ?name=<file.sql>');
        return json(await handleDelete(name));
      }
      case 'POST': {
        const text = await req.text();
        if (text.length > MAX_BODY) throw Object.assign(new Error('body too large (max 4 MiB)'), { status: 413 });
        let body: unknown = {};
        try {
          body = text.trim() ? JSON.parse(text) : {};
        } catch {
          throw bad('invalid JSON body');
        }
        return json(await handlePost(body));
      }
      default:
        throw Object.assign(new Error(`method ${req.method} not allowed`), { status: 405 });
    }
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    const status = (e as { status?: number }).status ?? 500;
    return json({ ok: false, error: message }, status);
  }
});