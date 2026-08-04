// =============================================================================
// 📜 System Logs API — served at /api/logs via Kong (admin-only)
// =============================================================================
// Queries the Vector → Logflare → Postgres log pipeline (stored in the
// '_supabase' database, '_analytics' schema, 'log_events_*' tables) and adds
// live health checks for every service in the stack.
//
// Auth: Kong requires the Supabase service_role key (key-auth + admin ACL):
//   curl -H "apikey: $SERVICE_ROLE_KEY" https://<domain>/api/logs
//
// Endpoints (all under /api/logs):
//   /            recent log events (filtered)
//   /sources     every log table + row count + last event time
//   /health      live health of every service
//   /system      services + log sources + database info in one report
//
// Query params for / :
//   level   info | warn | error (best-effort extraction)
//   q       substring match on the log message
//   limit   max rows (default 100, max 500)
//   after   ISO timestamp (>=)
//   before  ISO timestamp (<=)
// =============================================================================
import postgres from 'npm:postgres@3.4.3';

const LOGS_DB_URL = Deno.env.get('LOGS_DB_URL') ?? Deno.env.get('SUPABASE_DB_URL');

let sql: ReturnType<typeof postgres> | null = null;
function db() {
  if (!sql) sql = postgres(LOGS_DB_URL!, { max: 5 });
  return sql;
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

function clamp(n: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, n));
}

// Logflare table names look like log_events_<uuid> — validate before embedding.
const TABLE_RE = /^log_events_[a-zA-Z0-9_]+$/;

async function logTables(client: ReturnType<typeof postgres>): Promise<string[]> {
  const rows = await client`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = '_analytics' AND table_type = 'BASE TABLE'
    ORDER BY table_name
  `;
  return rows.map((r: { table_name: string }) => r.table_name).filter((n: string) => TABLE_RE.test(n));
}

async function hasColumns(
  client: ReturnType<typeof postgres>,
  table: string,
  columns: string[],
): Promise<boolean> {
  const rows = await client`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = '_analytics' AND table_name = ${table}
  `;
  const names = rows.map((r: { column_name: string }) => r.column_name);
  return columns.every((c) => names.includes(c));
}

// Best-effort log level extraction from a Logflare event body (jsonb).
function extractLevel(body: Record<string, unknown>): string {
  const meta = (body.metadata ?? {}) as Record<string, unknown>;
  const parsed = (meta.parsed ?? {}) as Record<string, unknown>;
  const level =
    (meta.level as string | undefined) ??
    (parsed.error_severity as string | undefined) ??
    (body.level as string | undefined) ??
    'info';
  return String(level).toLowerCase();
}

function extractMessage(body: Record<string, unknown>): string {
  const msg = body.event_message ?? body.message;
  if (typeof msg === 'string') return msg;
  return JSON.stringify(body).slice(0, 500);
}

// Best-effort human-readable source label by sniffing the metadata shape.
function guessSource(body: Record<string, unknown>): string {
  const meta = (body.metadata ?? {}) as Record<string, unknown>;
  if (meta.parsed && (meta.parsed as Record<string, unknown>).error_severity) return 'database';
  if (meta.request && (meta.request as Record<string, unknown>).headers) return 'api-gateway (kong)';
  if (meta.request && (meta.request as Record<string, unknown>).path) return 'api (postgrest)';
  if (meta.project_ref) return 'edge-functions';
  if (meta.level) return 'realtime';
  if (meta.timestamp && meta.msg) return 'auth';
  return 'unknown';
}

async function handleEvents(url: URL) {
  const client = db();
  const level = (url.searchParams.get('level') ?? '').toLowerCase();
  const q = url.searchParams.get('q') ?? '';
  const limit = clamp(parseInt(url.searchParams.get('limit') ?? '100') || 100, 1, 500);
  const after = url.searchParams.get('after');
  const before = url.searchParams.get('before');

  const tables = (await logTables(client)).filter((t) => t.length > 0);
  const usable: string[] = [];
  for (const t of tables) {
    // Every query below uses body + inserted_at — skip tables lacking either.
    if (await hasColumns(client, t, ['body', 'inserted_at'])) usable.push(t);
  }
  if (usable.length === 0) {
    return {
      ok: true,
      total: 0,
      message: 'No log tables found in _analytics yet — Logflare may not have received events.',
      events: [],
    };
  }

  const events: Array<Record<string, unknown>> = [];
  const perTable = limit * 2;
  for (const t of usable) {
    const conds: string[] = [];
    const args: unknown[] = [];
    if (level) {
      conds.push(
        `LOWER(COALESCE(body->'metadata'->>'level', body->'metadata'->'parsed'->>'error_severity', body->>'level', 'info')) = $${args.length + 1}`,
      );
      args.push(level);
    }
    if (q) {
      conds.push(`(body->>'event_message') ILIKE $${args.length + 1}`);
      args.push(`%${q}%`);
    }
    if (after) {
      conds.push(`inserted_at >= $${args.length + 1}`);
      args.push(after);
    }
    if (before) {
      conds.push(`inserted_at <= $${args.length + 1}`);
      args.push(before);
    }
    const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
    const rows = await client.unsafe(
      `SELECT body, inserted_at FROM _analytics.${t} ${where} ORDER BY inserted_at DESC LIMIT ${perTable}`,
      args,
    );
    for (const row of rows) {
      const body = (row.body ?? {}) as Record<string, unknown>;
      events.push({
        source: t,
        source_label: guessSource(body),
        timestamp: body.timestamp ?? row.inserted_at,
        level: extractLevel(body),
        message: extractMessage(body),
        metadata: body.metadata ?? null,
      });
    }
  }

  // Sort by parsed timestamp (fallback 0 for unparseable/missing values)
  events.sort(
    (a, b) =>
      (Date.parse(String(b.timestamp)) || 0) - (Date.parse(String(a.timestamp)) || 0),
  );
  return { ok: true, total: events.length, events: events.slice(0, limit) };
}

async function handleSources() {
  const client = db();
  const tables = (await logTables(client)).filter((t) => t.length > 0);
  const sources = [];
  for (const t of tables) {
    if (!(await hasColumns(client, t, ['body', 'inserted_at']))) continue;
    const row = await client.unsafe(
      `SELECT COUNT(*) AS n, MAX(inserted_at) AS last FROM _analytics.${t}`,
    );
    sources.push({
      table: t,
      rows: Number(row[0]?.n ?? 0),
      last_event_at: row[0]?.last ?? null,
    });
  }
  sources.sort((a, b) => b.rows - a.rows);
  return { ok: true, total_tables: sources.length, sources };
}

async function handleHealth() {
  const checks: Array<{ service: string; url: string }> = [
    { service: 'studio', url: 'http://studio:3000/api/platform/profile' },
    { service: 'kong', url: 'http://kong:8000/' },
    { service: 'auth', url: 'http://auth:9999/health' },
    { service: 'rest', url: 'http://rest:3000/' },
    { service: 'realtime', url: 'http://realtime-dev.supabase-realtime:4000/api/tenants/realtime-dev/health' },
    { service: 'meta', url: 'http://meta:8080/health' },
    { service: 'functions', url: 'http://functions:9000/' },
    { service: 'analytics', url: 'http://analytics:4000/health' },
    { service: 'vector', url: 'http://vector:9001/health' },
  ];
  const results: Record<string, unknown> = {};
  await Promise.all(checks.map(async ({ service, url }) => {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(3000) });
      results[service] = { ok: res.ok, status: res.status };
    } catch (e) {
      results[service] = { ok: false, error: String((e as Error).message ?? e) };
    }
  }));
  // Database health via a direct query (no HTTP endpoint)
  try {
    const row = await db().unsafe('SELECT 1 AS ok, version() AS version');
    results.db = { ok: true, status: 200, version: row[0]?.version ?? null };
  } catch (e) {
    results.db = { ok: false, error: String((e as Error).message ?? e) };
  }
  return { ok: true, checked_at: new Date().toISOString(), services: results };
}

async function handleSystem() {
  const [health, sources] = await Promise.all([handleHealth(), handleSources()]);
  let dbInfo: Record<string, unknown> = {};
  try {
    const row = await db().unsafe(
      `SELECT version() AS version, pg_postmaster_start_time() AS started_at,
              pg_size_pretty(pg_database_size(current_database())) AS db_size,
              (SELECT COUNT(*) FROM pg_stat_activity) AS connections`,
    );
    dbInfo = row[0] ?? {};
  } catch (e) {
    dbInfo = { error: String((e as Error).message ?? e) };
  }
  return { ok: true, database: dbInfo, log_pipeline: sources, services: health };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Kong strips /api/logs and forwards to /logs/..., so tolerate both.
  const path = url.pathname.replace(/^\/logs/, '').replace(/\/+$/, '') || '/';
  try {
    if (path === '/') return json(await handleEvents(url));
    if (path === '/sources') return json(await handleSources());
    if (path === '/health') return json(await handleHealth());
    if (path === '/system') return json(await handleSystem());
    return json(
      {
        error: 'Unknown endpoint',
        endpoints: ['/api/logs', '/api/logs/sources', '/api/logs/health', '/api/logs/system'],
      },
      404,
    );
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e) }, 500);
  }
});
