# Committed migrations

SQL files in this folder are applied **on top of the restored database** at the
start of every session (in filename order), tracked in
`public._schema_migrations` so each file runs only once.

## Why this exists

- Fresh databases get the `volumes/db/*.sql` init scripts at first boot.
- **Restored** databases get their schema from the state backup instead — so any
  change you make after the backup was taken would be lost on the next session.
- Committed migrations here close that gap: they apply every session, in order,
  exactly once, and the tracking table is carried by the state backup itself.

## Usage

```bash
# 1. Create a new migration (number prefixes keep the order)
echo "ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;" > supabase/migrations/002-avatar-url.sql

# 2. Commit + push — it applies automatically on the next session
```

- Prefix with a number for ordering: `001-…`, `002-…`, …
- Failed files are **not** marked applied — they retry next session until they
  succeed, so fix the SQL and re-commit.
- Destructive statements run too — that's the point of versioned migrations, but
  review before committing.

## Included example

- `001-custom-access-token-hook.sql` — pass-through `public.custom_access_token_hook`
  (Supabase Auth hook). Enabled by default config only when
  `ENABLE_CUSTOM_ACCESS_TOKEN_HOOK=true` is set. Add your claims logic to the
  function body.
