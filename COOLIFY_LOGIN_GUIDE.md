# Coolify Login After GitHub Actions Restart

## How It Works

When your GitHub Actions workflow restarts every ~6 hours:

1. **Supabase + Coolify containers are recreated** on a fresh VM
2. **State is restored from GitHub Actions cache:**
   - `supabase-state.tar.gz` (Supabase DB + functions + pgsodium key)
   - `coolify_backup.dump` (Coolify's own DB with users, projects, configs)
   - `volumes/coolify/source/.env` (APP_KEY and other secrets)
3. **APP_KEY must be stable** across sessions or encrypted data becomes unreadable

## Your Login Options

### Option 1: Login with Your Existing Account

If you registered an account in a previous session:

1. Go to `http://localhost:8082` (or your public Coolify URL)
2. Enter your email and password
3. If login fails, see troubleshooting below

**Why it might fail:**
- `coolify_backup.dump` wasn't properly restored
- `volumes/coolify/source/.env` was regenerated (new APP_KEY)
- Registration is disabled and you're not the root user

### Option 2: Login as Root User

The root user is created automatically:

- **Email**: Check the workflow logs for `ROOT_USER_EMAIL` (default: `coolify@<your-domain>`)
- **Password**: Set via `COOLIFY_PASSWORD` GitHub secret, or auto-generated

The workflow will display:
```
🔑 login: coolify@yourdomain.com / password in the run summary
```

### Option 3: Register a New Account

If open registration is enabled (it should be after each restart):

1. Go to the Coolify login page
2. Click "Register" or "Sign Up"
3. Create a new account

## Troubleshooting

### Run the Diagnostic Script

When the workflow is running, you can check the state:

```bash
cd supabase
bash utils/coolify-diagnose.sh
```

### Check Workflow Logs

Look for these lines in the "🐳 Coolify — start + health check" step:

```
✅ Coolify DB restored
👤 existing users (N) — admin seeding skipped
✅ N user(s) with passwords ready for login
🔑 Root user login: email (use COOLIFY_PASSWORD secret)
```

If you see:
- `ℹ️ No coolify_backup.dump — fresh Coolify database` → Your data wasn't persisted
- `⚠️ No users with passwords found` → Login will fail, use registration
- `⚠️ Coolify DB restore had errors` → Check the full restore log

### Verify APP_KEY Stability

The APP_KEY should be the same across sessions. Check the workflow summary:

```
| **APP_KEY** | base64:abc123... (stable across sessions if persisted) |
```

If the APP_KEY changes every session, your encrypted data (SSH keys, project configs) won't be readable, but **passwords should still work** (they're bcrypt-hashed, not APP_KEY-encrypted).

## Common Issues & Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| Can't login with existing account | DB restore failed or users table empty | Check if `coolify_backup.dump` exists and restored successfully |
| Registration is disabled | `is_registration_enabled = false` in DB | Should be re-enabled automatically; check logs for "open registration enabled" |
| Root user login fails | `COOLIFY_PASSWORD` doesn't meet policy | Password must be 8+ chars with upper, lower, digit, symbol |
| Projects not showing | APP_KEY changed | Projects are stored in DB; should persist if DB restored correctly |

## Prevention

To ensure your data persists:

1. **Check GitHub Actions cache**: Go to your repo → Settings → Actions → Cache
2. **Verify secrets are set**: `COOLIFY_PASSWORD` in repo secrets
3. **Watch the workflow logs**: The "🐳 Coolify — start" step should show successful restore

## Quick Fix for Immediate Login

If you're stuck right now:

1. Wait for the next workflow run to complete
2. Check the "Coolify is LIVE" section in the run summary
3. Use the credentials shown there
4. If registration is open, create a new account

If login still fails after verifying the above, the issue is likely in the DB restore process, and we should investigate the `coolify_backup.dump` restoration.
