# 🚀 Supabase Self-Hosted on GitHub Actions

**Run Supabase (all features except Storage) on free GitHub Actions runners with a permanent URL via Cloudflare Tunnel.**

```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────┐
│  Your App / Browser  │ ──▶ │  Cloudflare Tunnel   │ ──▶ │  GitHub Actions  │
│  (anywhere)          │     │  perm URL (static)   │     │  Runner          │
│                      │ ◀── │                      │ ◀── │  ├── Kong:8000   │
│                      │     │                      │     │  ├── Postgres    │
│                      │     │                      │     │  ├── Auth        │
│                      │     │                      │     │  ├── Realtime    │
│                      │     │                      │     │  └── Studio      │
└──────────────────────┘     └──────────────────────┘     └──────────────────┘
         ↕                                                        ↕
  Permanent domain                                     Cache-d SQL dump
  (never changes)                                      persists between runs
```

## ✨ Features

| Feature | Status |
|---|---|
| **PostgreSQL database** | ✅ Full Supabase Postgres |
| **PostgREST API** | ✅ Auto-generated REST API |
| **Auth (GoTrue)** | ✅ Login, signup, JWT, OAuth |
| **Realtime subscriptions** | ✅ WebSocket-based live queries |
| **Supabase Studio** | ✅ Dashboard UI (port 8000) |
| **Edge Functions** | ✅ Deno-based edge functions |
| **Object Storage** | ❌ Removed (as requested) |
| **Permanent URL** | ✅ Cloudflare Tunnel (static domain) |
| **Data persistence** | ✅ Cached between GitHub Actions runs |

## ⏱️ How It Works

1. **Workflow triggers** — manually or every 6 hours via cron
2. **Restores database** from GitHub Actions cache (your data survives)
3. **Starts Supabase** Docker Compose (without Storage)
4. **Connects Cloudflare Tunnel** — your permanent URL goes live
5. **Runs for ~5h45m** — access Studio, API, Auth, Realtime (maximizes the full 6-hour GitHub limit)
6. **Graceful shutdown** — backs up database, saves to cache
7. **Repeat** — next run picks up where you left off

> **Downtime:** ~15 minutes between runs (scheduled every 6 hours, runs for 5h45m)

---

## 📋 Setup Guide

### Step 1: Fork / Clone This Repo

```bash
git clone <your-repo-url>
cd supabase-selfhosted
```

### Step 2: Get a Domain on Cloudflare

You need a domain managed by Cloudflare (free):
- Buy one (e.g., `yourdomain.com`) or use an existing one
- Add it to Cloudflare's free plan

### Step 3: Create a Cloudflare Tunnel

1. Go to **Cloudflare Dashboard → Zero Trust → Networks → Tunnels**
2. Click **"Create a tunnel"** → Choose **"Cloudflared"**
3. Name it (e.g., `supabase-tunnel`)
4. Copy the **tunnel token** (long string starting with `eyJh...`)
5. Under **"Public Hostname"**, add:
   - **Subdomain**: `supabase` (or whatever you want)
   - **Domain**: your domain (e.g., `yourdomain.com`)
   - **Type**: `HTTP`
   - **URL**: `localhost:8000`
6. Save the tunnel

Your permanent URL will be: **`https://supabase.yourdomain.com`**

### Step 4: Generate Secrets

Run these commands locally to generate secure values:

```bash
# Postgres password
openssl rand -hex 32
# → Copy this for POSTGRES_PASSWORD

# JWT secret (32+ chars)
openssl rand -base64 32
# → Copy this for JWT_SECRET

# Dashboard password
# → Pick something secure for DASHBOARD_PASSWORD
```

### Step 5: Add GitHub Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `CF_TUNNEL_TOKEN` | The tunnel token from Step 3 |
| `CF_TUNNEL_DOMAIN` | Your URL: `supabase.yourdomain.com` (no https://) |
| `POSTGRES_PASSWORD` | Output from `openssl rand -hex 32` |
| `JWT_SECRET` | Output from `openssl rand -base64 32` |
| `DASHBOARD_PASSWORD` | Your secure dashboard password |

### Step 6: Push & Run

```bash
git add .
git commit -m "Add Supabase self-hosted workflow"
git push
```

Then go to **Actions → Supabase Self-Hosted → Run workflow** (or wait for the scheduled trigger).

### Step 7: Access Your Supabase

| What | URL |
|---|---|
| **Supabase Studio** | `https://supabase.yourdomain.com` |
| **Login** | Username: `supabase` / Password: your `DASHBOARD_PASSWORD` |
| **REST API** | `https://supabase.yourdomain.com/rest/v1/` |
| **Auth** | `https://supabase.yourdomain.com/auth/v1/` |
| **Realtime** | `wss://supabase.yourdomain.com/realtime/v1/` |
| **ANON KEY** | Visible in Studio settings or from workflow logs |

---

## 🛠️ Customization

### Change the schedule

Edit `.github/workflows/supabase-host.yml` and modify the cron:

```yaml
schedule:
  - cron: '0 */4 * * *'   # Every 4 hours
  - cron: '0 */6 * * *'   # Every 6 hours
```

### Run longer (maxing out the 6-hour limit)

Already configured for max utilization. The settings are:

```yaml
timeout-minutes: 355   # 5h55m — 5 min buffer under 360 min hard limit
# In the keep-alive step:
DURATION=20700  # 5h45m — leaves time for setup (~5 min) + shutdown (~5 min)
```

### Add Storage back

Remove the **"Remove Storage services"** step from the workflow.

### Add OAuth providers

Set environment variables in the workflow (e.g., `GOTRUE_EXTERNAL_GOOGLE_ENABLED`, `GOOGLE_CLIENT_ID`).

---

## 🧠 Architecture Notes

### Why not use VPS?

This setup is **free** (GitHub Actions + Cloudflare free tier). The trade-off:
- ✅ **Zero cost** to run
- ✅ **Auto-scaling** runners
- ✅ **Full 6-hour window utilized** (5h45m uptime + 15m gap between runs)
- ❌ **~15 minutes downtime** between 6-hour runs
- ❌ **Ephemeral** — cache could be evicted if not used for 7+ days

### How data persists

```
Run 1: Start fresh DB → Use Supabase → pg_dump → Save to cache
  ↓
Run 2: Restore from cache → Use Supabase → pg_dump → Save to cache
  ↓
Run 3: Restore from cache → Use Supabase → pg_dump → Save to cache
  ...
```

### Cache limitations

- GitHub Actions cache has **10GB limit** per repo
- Cache is **evicted** after 7 days of inactivity
- If cache is lost, you start fresh (schema is auto-created by Supabase SQL init scripts)

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| Tunnel not connecting | Verify `CF_TUNNEL_TOKEN` is correct in GitHub Secrets |
| Can't access URL | Check Cloudflare Tunnel dashboard → tunnel status |
| Database not persisting | Check if cache was evicted (run workflow twice) |
| Workflow not running on schedule | GitHub may delay schedule events during high load |
| "No space left on device" | GitHub runner has ~14GB free — clean up old Docker images |
| Port already in use | Runner resets between runs, should be fresh |

---

## 📚 Resources

- [Supabase Self-Hosting Docs](https://supabase.com/docs/guides/self-hosting/docker)
- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [GitHub Actions Cache](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/caching-dependencies-to-speed-up-workflows)
- [Supabase GitHub](https://github.com/supabase/supabase)
