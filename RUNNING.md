# Running the Application

The public site reads its content from MongoDB (editable at `/admin`), so every scenario below — local dev included — needs a MongoDB connection and at least one admin login configured first.

For production, this is a fully automated deploy: nginx (reverse proxy) + Caddy (ACME/TLS) + the Next.js app, all via Docker Compose. Optionally, a Cloudflare Tunnel for exposing the app with zero open inbound ports.

## Quick reference

**Local development** (no Docker):
```bash
npm run env:create -- local  # writes .env.local (MongoDB URI/DB, auto-generates AUTH_SECRET)
npm run admin:create         # create your first /admin login
npm run dev                  # http://localhost:3000
```

**Docker, without tunnel** (nginx + Caddy only):
```bash
./deploy.sh your-domain.com   # production, real Let's Encrypt cert
./deploy.sh --local           # local test, self-signed cert
```

**Docker, with named tunnel** (your own hostname, requires `secrets/cloudflare_tunnel_token` — see [below](#named-tunnel-your-own-hostname----tunnel)):
```bash
./deploy.sh --tunnel your-domain.com
./deploy.sh --local --tunnel   # test the tunnel wiring locally
```

**Docker, with quick tunnel** (random `*.trycloudflare.com` URL, no setup — see [below](#quick-tunnel-no-dashboardtoken-random-url----quick-tunnel)):
```bash
./deploy.sh --local --quick-tunnel
./deploy.sh your-domain.com --quick-tunnel
```

`--tunnel` and `--quick-tunnel` are mutually exclusive; `--local` combines with either. Re-running `deploy.sh` with no arguments redeploys using whatever was saved in `.env` last time. `deploy.sh` will interactively prompt to create a missing admin login or Cloudflare token when needed (see below) — no manual steps required on a fresh checkout.

## Environment & secrets (required for every scenario)

These three things are needed whether you run via `npm run dev` or Docker:

### 1. MongoDB connection + Auth secret (one command)

`npm run env:create` writes `.env.local` (local dev) or `.env.prod` (production, copied to the server — see [Deploy to production](#deploy-to-production)) interactively: it prompts for the MongoDB connection and public site URL, and auto-generates `AUTH_SECRET` via `npx auth secret` (the `auth` CLI is a devDependency, so this works offline after `npm install` too — falls back to an equally-valid locally generated secret if `npx` can't run at all).

```bash
npm run env:create -- local   # writes .env.local, used by `npm run dev` and docker-compose's env_file
npm run env:create -- prod    # writes .env.prod, copy this one to the server (never git)
npm run env:create            # omit the target and it prompts you for local/prod
```

Each prompt shows the current value (from an existing file) as its default — press Enter to keep it. Safe to re-run any time to update `MONGODB_URI`/`MONGODB_DB`/`NEXT_PUBLIC_SITE_URL`: an existing `AUTH_SECRET` is always preserved (rotating it would invalidate every logged-in admin session; delete the `AUTH_SECRET=` line from the file first if you deliberately want a new one generated).

Get a MongoDB connection string from a free [MongoDB Atlas](https://www.mongodb.com/cloud/atlas) cluster (no manual database/collection creation needed — it's created automatically on first use).

Never put real credentials in `.env.example` — it's committed to git. Real values only go in `.env.local`/`.env.prod` (both git-ignored, mode `600`).

Prefer to edit by hand instead? Copy `.env.example` and fill it in yourself — `npx auth secret` still works standalone, just rename its `BETTER_AUTH_SECRET` output to `AUTH_SECRET`:

```bash
cp .env.example .env.local
npx auth secret   # copy the printed value into .env.local as AUTH_SECRET=...
```

### 2. At least one admin login

Admin accounts live in `secrets/admin-users.json` (git-ignored — a JSON array of `{ email, passwordHash }`, never plaintext passwords), not in an env var:

```bash
npm run admin:create
```
Follow the prompts (email, password, confirmation). Re-run it anytime to add another admin or change a password — it upserts by email and takes effect immediately, no restart needed (both `npm run dev` and the Docker container read the file live).

## Local development

Once the three prerequisites above are done:

```bash
npm run dev
```
- Public site: http://localhost:3000
- Admin: http://localhost:3000/admin/login

`ADMIN_USERS_FILE` can be left unset in `.env.local` — it defaults to `secrets/admin-users.json` relative to the project root.

## Prerequisites (Docker scenarios)

- Docker Desktop/Engine installed and running
- `.env.local` with `MONGODB_URI`, `MONGODB_DB`, and `AUTH_SECRET` set (see above) — `docker-compose.yml` loads it via `env_file` on **whichever host runs `docker compose`** (so on a remote server, that host needs its own `.env.local` too — see [Deploy to production](#deploy-to-production) for how `.env.prod` fits in)
- For production: a domain's DNS `A`/`AAAA` record pointing at this server's public IP, with ports `80`/`443` open to the internet

## Test locally first

No domain, DNS, or open ports needed — Caddy issues a self-signed certificate from its internal CA instead of a real one:

```bash
./deploy.sh --local
```

This starts the same stack on `https://localhost`. Browsers/curl will flag the certificate as untrusted (expected for a self-signed cert) — accept the browser warning, or:

```bash
curl -k https://localhost/
```

Use `./deploy.sh --local myapp.localhost` to test under a specific hostname. Run `docker compose down` when done, then move on to a real production deploy below.

## Deploy to production

```bash
./deploy.sh your-domain.com
```

That single command:
1. Checks Docker is installed and running
2. Prompts to create `secrets/admin-users.json` (via `npm run admin:create`) if it's empty, and `secrets/cloudflare_tunnel_token` (via `npm run tunnel:token`) if `--tunnel` was passed and it's missing — skipped non-interactively, with a warning instead
3. Saves `DOMAIN` (and `NEXT_PUBLIC_SITE_URL`) to `.env`
4. Builds the images (`docker compose build`)
5. Starts the stack (`docker compose up -d`)
6. Waits for the `web` and `nginx` containers to report healthy
7. Waits for Caddy to issue the Let's Encrypt certificate and for nginx to enable HTTPS
8. Prints `https://your-domain.com` once it's live

`.env.local` (with `MONGODB_URI`/`AUTH_SECRET`) must already exist **on the server** before running this — `docker-compose.yml` only ever reads a file literally named `.env.local` via `env_file`, on whatever host runs `docker compose`. The recommended flow, keeping production secrets out of your local dev `.env.local`:

```bash
npm run env:create -- prod          # writes .env.prod locally (prompts for MongoDB URI, DB, site URL; auto-generates AUTH_SECRET)
scp .env.prod user@server:/path/to/portfolio/.env.local   # transfer + rename in one step
ssh user@server 'cd /path/to/portfolio && ./deploy.sh your-domain.com'
```

`scp`/`rsync` only, never git — `.env.prod`/`.env.local` are both git-ignored. Re-running `deploy.sh` (with or without arguments, once `.env` exists) redeploys with the same settings.

Optional: override the public site URL used in metadata (defaults to `https://<domain>`):

```bash
./deploy.sh your-domain.com https://your-domain.com
```

## Optional: Cloudflare Tunnel

Exposes the app through Cloudflare with no inbound ports open on this host at all (`nginx`'s `80`/`443` can stay closed to the internet). The tunnel connection is outbound-only and mutually authenticated; the token is passed via a Docker secret file, never an environment variable. Both tunnel modes are opt-in via flags — neither runs unless you pass one.

### Named tunnel (your own hostname) — `--tunnel`

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/): Networks -> Tunnels -> Create a tunnel -> Docker, and copy the token value (not the whole install command).
2. Save it locally (git-ignored, never committed) — either run `./deploy.sh --tunnel your-domain.com` and let it prompt you, or set it up yourself first:
   ```bash
   npm run tunnel:token
   ```
3. In the same dashboard, under the tunnel's **Public Hostname** tab, set the Service to `http://web:3000` (routes straight to the app container over the private Docker network).
4. Run with `--tunnel`:
   ```bash
   ./deploy.sh --tunnel your-domain.com
   ./deploy.sh --local --tunnel   # to test the wiring locally first
   ```
   `--tunnel` fails fast with a clear error if `secrets/cloudflare_tunnel_token` still doesn't exist after the prompt (e.g. running non-interactively).

There's no public URL printed in `cloudflared`'s logs — it's whatever hostname you set in step 3.

### Quick tunnel (no dashboard/token, random URL) — `--quick-tunnel`

For ad-hoc testing without setting anything up in Cloudflare:

```bash
./deploy.sh --local --quick-tunnel
./deploy.sh your-domain.com --quick-tunnel
```

This starts `cloudflared-quick` instead, which prints a random `https://<random>.trycloudflare.com` URL — find it with:

```bash
docker compose logs cloudflared-quick | grep trycloudflare.com
```

No auth, no persistence, URL changes every restart — fine for a quick demo, not for production. `--tunnel` and `--quick-tunnel` are mutually exclusive.

## Managing admin logins

Add, update, or rotate an admin's password at any time — works identically for local dev and Docker (the file is bind-mounted live, no rebuild/restart needed):

```bash
npm run admin:create
```

To remove an admin, edit `secrets/admin-users.json` directly and delete their entry.

## Building the CLI scripts (admin:create / env:create / tunnel:token)

`scripts/build.mjs` (esbuild) bundles + minifies `create-admin.mjs`, `create-env.mjs`, and `create-cloudflare-tunnel-token.mjs` — plus `bcryptjs` and `scripts/lib/prompt.mjs` — into self-contained files under `dist/`. Only Node built-ins (`node:fs`, etc.) stay external, so the built files need no `node_modules` at runtime.

**Production build** (minified, no sourcemaps, cleans `dist/` first):
```bash
npm run build
```
```
dist/create-admin.mjs
dist/create-env.mjs
dist/create-cloudflare-tunnel-token.mjs
```
Run them directly, without `node_modules`:
```bash
node dist/create-admin.mjs
node dist/create-env.mjs -- local
node dist/create-cloudflare-tunnel-token.mjs
```

**Dev build** (unminified, sourcemaps, rebuilds automatically on every save):
```bash
npm run build:dev
```
Leave it running in a terminal while editing `scripts/*.mjs` — output stays readable for debugging. Stop with `Ctrl+C`.

`dist/` is git-ignored — it's a build artifact, not source. There's no need to run `npm run build` for everyday `npm run admin:create` / `npm run env:create` / `npm run tunnel:token` usage; those already run straight from source via `node scripts/...`. Building is only useful when you want to ship/execute these scripts on a machine without `node_modules` installed.

## Checking status / logs

```bash
docker compose ps
docker compose logs -f caddy              # certificate issuance/renewal
docker compose logs -f nginx              # reverse proxy
docker compose logs -f web                # app
docker compose logs -f cloudflared        # named tunnel (if enabled)
docker compose logs -f cloudflared-quick  # quick tunnel (if enabled)
```

## Stopping

```bash
docker compose down
```

Certificates persist in the `caddy_data` volume, so stopping/starting the stack again does not require re-issuing them.

