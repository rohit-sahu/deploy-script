# Production Deployment Guide

Step-by-step instructions to take this portfolio from local development to a live, production URL. Pick **one** of the three deployment paths in [Step 3](#step-3--deploy) depending on where you're hosting.

---

## Step 0 — Prerequisites

- Node.js `>= 20` (see `engines.node` in `package.json`)
- A domain name you control (e.g. `rohitkumar.dev`) — optional but recommended for OG/SEO metadata
- Git repository pushed to GitHub/GitLab (required for Vercel; recommended for everything else)
- Docker (only if using [Option B — Docker](#option-b--docker-any-vps--node-host--kubernetes))

---

## Step 1 — Configure environment variables

1. Copy the example env file:
   ```bash
   cp .env.example .env.local
   ```
2. Edit `.env.local` and set your real production domain, MongoDB connection, and auth secret:
   ```bash
   NEXT_PUBLIC_SITE_URL=https://your-domain.com
   MONGODB_URI=mongodb+srv://<user>:<password>@<cluster-host>/?appName=<app-name>
   MONGODB_DB=portfolio
   AUTH_SECRET=            # generate with: npx auth secret
   ```
   `NEXT_PUBLIC_SITE_URL` is used to generate absolute URLs for Open Graph/Twitter card images, `sitemap.xml`, `robots.txt`, and canonical links. If you skip it, it falls back to `https://rohitkumar.skytech.in`, which is almost certainly not your domain.
3. Create at least one `/admin` login (stored as a bcrypt hash in `secrets/admin-users.json`, git-ignored — not an env var):
   ```bash
   npm run admin:create
   ```

| Variable | Purpose | Default |
|---|---|---|
| `NEXT_PUBLIC_SITE_URL` | Canonical production URL used in metadata/SEO | `https://rohitkumar.skytech.in` |
| `MONGODB_URI` | Connection string for the resume content database | — required |
| `MONGODB_DB` | Database name | `portfolio` |
| `AUTH_SECRET` | Auth.js session signing secret | — required |
| `ADMIN_USERS_FILE` | Override path to the admin roster JSON file | `secrets/admin-users.json` |

> `.env.local` and `secrets/admin-users.json` are git-ignored. Never commit real secrets — only `.env.example`/`secrets/admin-users.json.example` (templates with no real values) are tracked in git.
>
> **Vercel caveat:** the admin roster is a local file (`secrets/admin-users.json`), which works for Docker/plain-Node (Option B/C below) but has no equivalent on Vercel's serverless filesystem. Deploying `/admin` to Vercel needs a different admin-storage approach (e.g. moving the roster into MongoDB alongside the resume content) — out of scope for the Vercel path as currently built. The public site itself deploys to Vercel fine either way.

---

## Step 2 — Run the pre-deploy checklist

Run these locally (or in CI) before every deploy. All three must pass cleanly:

```bash
npm ci                 # clean install from package-lock.json
npm run lint           # ESLint — no errors
npm run type-check     # tsc --noEmit — no type errors
npm run build          # production build (also re-runs type-checking)
```

`npm run build` output should show the public routes static (`○`) and the admin/auth routes dynamic (`ƒ`) — that's expected, since they read the live session/database on each request:

```
Route (app)
┌ ○ /
├ ○ /_not-found
├ ƒ /admin
├ ○ /admin/login
├ ƒ /api/auth/[...nextauth]
├ ○ /manifest.webmanifest
├ ○ /opengraph-image
├ ○ /robots.txt
└ ○ /sitemap.xml
```

If any step fails, fix it before deploying — don't deploy a build that fails locally.

---

## Step 3 — Deploy

Choose the option that matches your hosting target.

### Option A — Vercel (recommended, easiest)

> The public site (all sections except `/admin`) deploys to Vercel without changes. `/admin` login also works — Auth.js + MongoDB have no filesystem dependency — **except** the admin roster (`secrets/admin-users.json`) is a local file with no Vercel equivalent; you'd need to move it into MongoDB first (not implemented). Skip `/admin` on Vercel until then, or use the Docker path in Option B for the full feature set.

1. Push your repository to GitHub (or GitLab/Bitbucket).
2. Go to [vercel.com/new](https://vercel.com/new) and import the repository.
3. Vercel auto-detects Next.js — leave build settings as default (`npm run build`, output `.next`).
4. Under **Project Settings → Environment Variables**, add:
   - `NEXT_PUBLIC_SITE_URL` = `https://your-domain.com`
   - `MONGODB_URI` = your connection string
   - `MONGODB_DB` = `portfolio`
   - `AUTH_SECRET` = output of `npx auth secret`
5. Click **Deploy**. Vercel builds, deploys to its global CDN, and provisions HTTPS automatically.
6. (Optional) Go to **Project Settings → Domains** and add your custom domain, then update your DNS records as instructed.
7. Every subsequent `git push` to your main branch auto-deploys; pull requests get preview URLs automatically.

### Option B — Docker (any VPS / Node host / Kubernetes)

The project already includes a multi-stage `Dockerfile` producing a minimal, self-contained server (via `output: "standalone"` in `next.config.ts`), plus a fully-automated `docker compose` stack (nginx + Caddy + the app, optional Cloudflare Tunnel) — see **[RUNNING.md](./RUNNING.md)** for the one-command `./deploy.sh your-domain.com` path, which is the recommended way to run this project in Docker.

To run the bare image manually instead (e.g. behind your own existing reverse proxy/orchestrator):

1. Build the image:
   ```bash
   docker build -t rohit-portfolio .
   ```
2. Create at least one admin login first (writes to `secrets/admin-users.json` — mounted into the container as a Docker secret by `docker-compose.yml`; if running the bare image yourself, mount/copy it in some other way):
   ```bash
   npm run admin:create
   ```
3. Run it locally first to smoke-test:
   ```bash
   docker run --rm -p 3000:3000 \
     -e NEXT_PUBLIC_SITE_URL=https://your-domain.com \
     -e MONGODB_URI=your-connection-string \
     -e MONGODB_DB=portfolio \
     -e AUTH_SECRET=output-of-npx-auth-secret \
     rohit-portfolio
   ```
4. Verify it responds:
   ```bash
   curl -I http://localhost:3000
   ```
5. Push the image to a registry your server/cluster can pull from:
   ```bash
   docker tag rohit-portfolio your-registry/rohit-portfolio:latest
   docker push your-registry/rohit-portfolio:latest
   ```
6. On your server (or via your Kubernetes/ECS/Cloud Run manifest), run the container with the same env vars, mount the admin roster file, and map port `3000` behind your load balancer / ingress.
7. Put a reverse proxy (Nginx, Caddy, your cloud LB) in front for TLS termination and your custom domain — see [Step 4](#step-4--tls--reverse-proxy-non-vercel-only).

### Option C — Plain Node server (VPS without Docker)

1. On the server, clone the repo and install dependencies:
   ```bash
   git clone <your-repo-url> portfolio
   cd portfolio
   npm ci
   ```
2. Set up `.env.local` and create an admin login (see [Step 1](#step-1--configure-environment-variables)):
   ```bash
   cp .env.example .env.local   # fill in MONGODB_URI, AUTH_SECRET, NEXT_PUBLIC_SITE_URL
   npm run admin:create
   ```
3. Build:
   ```bash
   npm run build
   ```
4. Start the production server (use a process manager so it survives reboots/crashes — see below):
   ```bash
   npm run start -- -p 3000
   ```
5. **Keep it running** with a process manager, e.g. [PM2](https://pm2.keymetrics.io/):
   ```bash
   npm install -g pm2
   pm2 start "npm run start -- -p 3000" --name portfolio
   pm2 save
   pm2 startup   # follow the printed instructions to enable boot persistence
   ```
6. Put this behind a reverse proxy for TLS — see [Step 4](#step-4--tls--reverse-proxy-non-vercel-only).

---

## Step 4 — TLS / reverse proxy (non-Vercel only)

Vercel handles TLS automatically — skip this step if using Option A.

For Options B/C, terminate HTTPS at a reverse proxy in front of Node/Docker (which serves plain HTTP on port 3000).

**Example Nginx config:**
```nginx
server {
    listen 80;
    server_name your-domain.com www.your-domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com www.your-domain.com;

    ssl_certificate     /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

Get a free TLS certificate with [Certbot](https://certbot.eff.org/):
```bash
sudo certbot --nginx -d your-domain.com -d www.your-domain.com
```

---

## Step 5 — Point DNS at your server

- **Vercel**: add the `A`/`CNAME` records Vercel shows you under Project Settings → Domains.
- **VPS (Docker/Node)**: create an `A` record pointing your domain to your server's public IP.

DNS propagation can take a few minutes to a few hours.

---

## Step 6 — Post-deploy verification

Once live, verify each of the following on the real production URL:

```bash
curl -I https://your-domain.com                    # 200 OK
curl -I https://your-domain.com/robots.txt          # 200 OK
curl -I https://your-domain.com/sitemap.xml         # 200 OK
curl -I https://your-domain.com/manifest.webmanifest # 200 OK
curl -I https://your-domain.com/opengraph-image     # 200 OK, image/png
```

Also check manually:
- [ ] Security headers present (`X-Frame-Options`, `X-Content-Type-Options`, etc. — visible via `curl -I`)
- [ ] Site loads correctly on both desktop and a real mobile device (not just emulation)
- [ ] Dark/light mode toggle and all 5 color themes work and persist on reload
- [ ] Resume download button serves `Rohit_Resume.pdf` correctly
- [ ] Open Graph image renders correctly when sharing the link (test with a social media debugger, e.g. Facebook's [Sharing Debugger](https://developers.facebook.com/tools/debug/) or Twitter Card Validator)
- [ ] No console errors in browser dev tools
- [ ] `/admin/login` reachable and you can sign in with an account from `secrets/admin-users.json`
- [ ] Editing a section in `/admin` and saving reflects on the public site immediately (no redeploy needed)

---

## Step 7 — Ongoing updates

- **Vercel**: just `git push` — it auto-builds and deploys.
- **Docker**: rebuild the image, push to your registry, redeploy the container (`docker pull && docker restart`, or trigger your orchestrator's rolling update).
- **Plain Node**: `git pull && npm ci && npm run build && pm2 restart portfolio`.

Always re-run the [Step 2 checklist](#step-2--run-the-pre-deploy-checklist) before deploying updates.

---

## Troubleshooting

- **Blank/unstyled page on mobile during local development** — this is expected when opening the *dev server* (`npm run dev`) from a phone via your computer's LAN IP; Next.js blocks cross-origin dev asset requests by default. This is fixed for local testing via `allowedDevOrigins` in `next.config.ts`, and does **not** affect production builds at all.
- **OG image / metadata showing the wrong domain** — double check `NEXT_PUBLIC_SITE_URL` is set correctly in your hosting provider's environment variables (not just in a local `.env.local`, which isn't deployed).
- **`next start` fails with "Cannot find module '.next/standalone/server.js'"** — you built with `output: "standalone"` but ran `npm run start` from a normal build. Either build without a separate standalone extraction step (the `Dockerfile` handles this correctly), or run `node .next/standalone/server.js` directly after copying `public/` and `.next/static` into `.next/standalone/`.
- **Site loads but shows placeholder/default resume content** — `MONGODB_URI` is missing, unreachable, or the database hasn't been written to yet. The app deliberately falls back to `defaultResumeData` in `src/data/resume.ts` rather than erroring, logging `Failed to load resume data from MongoDB, falling back to defaults` server-side. Fix `MONGODB_URI` and redeploy, or just save something from `/admin` once it's reachable.
- **"Invalid email or password" at `/admin/login` despite correct credentials** — check `ADMIN_USERS_FILE` isn't set to an empty string in your env (it should be unset, or point at a real path); also confirm `secrets/admin-users.json` actually contains that email (`npm run admin:create` upserts by email, case-insensitive).
