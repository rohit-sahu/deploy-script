# Production Deployment

A single, linear checklist to take this app from a fresh VPS + domain to a live, HTTPS site with a working MongoDB-backed `/admin`. For reference material (all run scenarios, Cloudflare Tunnel details, alternative hosts like Vercel), see [RUNNING.md](./RUNNING.md) and [DEPLOYMENT.md](./DEPLOYMENT.md) — this file is the condensed, do-this-in-order version specifically for the Docker + your-own-domain path.

## 0. Prerequisites

- A server (VPS) with Docker Desktop/Engine + the `docker compose` plugin installed and running
- A domain name, with its DNS `A`/`AAAA` record pointed at the server's public IP
- Ports `80` and `443` open to the internet on that server (skip if using a Cloudflare Tunnel — see [step 6](#6-optional-cloudflare-tunnel--no-open-ports))
- A MongoDB connection string (a free [MongoDB Atlas](https://www.mongodb.com/cloud/atlas) cluster works fine — no manual database/collection setup needed, it's created automatically on first use)

## 1. Get the code onto the server

```bash
git clone <your-repo-url> portfolio
cd portfolio
```

## 2. Create `.env.local` (real secrets — never committed)

```bash
cp .env.example .env.local
```

Edit `.env.local` and fill in:

```
NEXT_PUBLIC_SITE_URL=https://your-domain.com
MONGODB_URI=mongodb+srv://<user>:<password>@<cluster-host>/?appName=<app-name>
MONGODB_DB=portfolio
AUTH_SECRET=
```

Generate `AUTH_SECRET` and paste the value in (rename `BETTER_AUTH_SECRET` → `AUTH_SECRET`, since that's what this app's Auth.js config reads):

```bash
npx auth secret
```

`.env.local` is gitignored — it must be created directly on the server (or copied over securely with `scp`/`rsync`), never pushed via git.

## 3. Create the admin login

Admin accounts are **not** an env var — they're a bcrypt-hashed JSON roster at `secrets/admin-users.json` (gitignored):

```bash
npm run admin:create
```

Follow the prompts (email, password, confirmation). Re-run this anytime to add another admin or rotate a password — no rebuild/restart needed, the file is read live.

## 4. (Optional) Cloudflare Tunnel token

Only needed if you plan to use `--tunnel` in step 5 (see [step 6](#6-optional-cloudflare-tunnel--no-open-ports) for when to use this). Skip straight to step 5 otherwise.

```bash
npm run tunnel:token
```

## 5. Deploy

```bash
./deploy.sh your-domain.com
```

This single command:
1. Checks Docker is installed and running
2. Prompts to create `secrets/admin-users.json` / `secrets/cloudflare_tunnel_token` if either is still missing (interactive only — non-interactive runs just warn)
3. Saves `DOMAIN` and `NEXT_PUBLIC_SITE_URL` to `.env` (Docker Compose's own config file, separate from `.env.local` — see [reference table](#reference-which-file-holds-what) below)
4. Builds the images (`docker compose build`)
5. Starts the stack: `nginx` (reverse proxy) + `caddy` (issues the Let's Encrypt certificate) + `web` (this app)
6. Waits for `web` and `nginx` to report healthy
7. Waits for the HTTPS certificate to be issued
8. Prints `https://your-domain.com` once it's live

Step 4 builds on the server by default. For pulling a pre-built image instead (Docker Hub, GHCR, ECR, etc.) via `IMAGE=... ./deploy.sh --pull your-domain.com`, see [IMAGE_DEPLOYMENT_OPTIONS.md](./IMAGE_DEPLOYMENT_OPTIONS.md).

No other manual steps are required. Re-running `deploy.sh` (with or without arguments, once `.env` exists) redeploys with the same settings.

## 6. (Optional) Cloudflare Tunnel — no open ports

Skip this entirely if you opened `80`/`443` in step 0 — it's an alternative, not an addition.

**Named tunnel** (your own hostname, requires the token from step 4):
```bash
./deploy.sh --tunnel your-domain.com
```
In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/), set the tunnel's Public Hostname → Service to `http://web:3000`.

**Quick tunnel** (zero setup, random throwaway URL, not for real production use):
```bash
./deploy.sh your-domain.com --quick-tunnel
docker compose logs cloudflared-quick | grep trycloudflare.com
```

## 7. Verify

```bash
curl -I https://your-domain.com                     # 200 OK
curl -I https://your-domain.com/robots.txt           # 200 OK
curl -I https://your-domain.com/sitemap.xml          # 200 OK
curl -I https://your-domain.com/opengraph-image      # 200 OK, image/png
```

Then manually:
- [ ] Site loads correctly, security headers present (`X-Frame-Options`, etc. — visible via `curl -I`)
- [ ] `/admin/login` reachable, and you can sign in with the account from step 3
- [ ] Editing a section in `/admin` and saving reflects on the public site immediately (no redeploy needed)
- [ ] Profile photo (if using a Google Drive link) renders correctly — see [RUNNING.md](./RUNNING.md) for the required link format
- [ ] Open Graph image renders correctly when sharing the link (test with a social media debugger)

## 8. Ongoing operations

```bash
docker compose ps                         # status
docker compose logs -f web                # app logs
docker compose logs -f caddy              # certificate issuance/renewal
docker compose logs -f nginx              # reverse proxy
npm run admin:create                      # add/update an admin login (no restart needed)
docker compose down                       # stop (certs persist in the caddy_data volume)
```

**Deploying updates:**
```bash
git pull
./deploy.sh                               # redeploys using the domain saved in .env
```

## Reference: which file holds what

| File | Purpose | Committed to git? | Edited by |
|---|---|---|---|
| `.env.local` | Real secrets: `MONGODB_URI`, `AUTH_SECRET`, `NEXT_PUBLIC_SITE_URL` | No (gitignored) | You, by hand |
| `secrets/admin-users.json` | Admin login roster (bcrypt hashes only) | No (gitignored) | `npm run admin:create` |
| `secrets/cloudflare_tunnel_token` | Cloudflare Tunnel token (only if using `--tunnel`) | No (gitignored) | `npm run tunnel:token` |
| `.env` | `DOMAIN`, `NEXT_PUBLIC_SITE_URL`, `CADDYFILE` — Docker Compose's own variable substitution | No (gitignored) | `deploy.sh` (don't edit by hand) |

## Troubleshooting

See the [Troubleshooting section in DEPLOYMENT.md](./DEPLOYMENT.md#troubleshooting) for common issues (stale OG metadata, default-content fallback when MongoDB is unreachable, login failures from misconfigured `ADMIN_USERS_FILE`, etc.), and [RUNNING.md](./RUNNING.md#checking-status--logs) for log commands per service.
