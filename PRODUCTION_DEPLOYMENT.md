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

**Certificate renewal (fully automatic, no action needed):**
Caddy checks its certs roughly every 10 minutes and renews once ~30 days remain before expiry (`renewal_window_ratio 0.3333` in `Caddyfile`). If you've completed [step 9](#9-harden-against-direct-ip-access-cloudflare-only-firewall), this keeps working indefinitely because Cloudflare forwards the renewal's HTTP-01 challenge to your origin from its own (allowlisted) IP ranges — see [9c](#9c-lock-the-firewall-to-cloudflares-ip-ranges-only) for why. Spot-check anytime:
```bash
docker compose logs caddy --since 24h | grep -i renew
openssl s_client -connect your-domain.com:443 -servername your-domain.com </dev/null 2>/dev/null | openssl x509 -noout -dates
```

## 9. Harden against direct-IP access (Cloudflare-only firewall)

By default, `80`/`443` are open to the whole internet (`0.0.0.0/0`), so your site is reachable both via your domain **and** via the server's raw public IP. This section locks that down so only Cloudflare can reach your origin. **Do this only after step 7 (Verify) passes** — the very first certificate must be issued before you flip Cloudflare's proxy on, otherwise you'll hit a chicken-and-egg SSL failure (see [step 9c](#9c-why-the-order-matters-first-cert-vs-renewal) below).

### 9a. Move DNS to Cloudflare (gray-cloud first)

1. Add your domain to Cloudflare, update nameservers at your registrar.
2. Create/confirm the `A` record → your server's public IP, with the cloud icon **gray (DNS-only)** for now.
3. Cloudflare Dashboard → SSL/TLS → Overview → set mode to **Flexible** for now.
4. Confirm propagation: `dig +short your-domain.com` returns your server's real IP.
5. Deploy normally (step 5 above) and confirm step 7's `curl` checks pass — this issues the **first** Let's Encrypt certificate while DNS still points directly at your origin, avoiding any Cloudflare-related complications.

### 9b. Turn on Cloudflare proxying

1. Cloudflare Dashboard → DNS → click the DNS record's cloud icon → turns **orange (Proxied)**.
2. Confirm: `dig +short your-domain.com` now returns a Cloudflare IP, not your server's.
3. SSL/TLS → Overview → switch mode to **Full (strict)** (safe now — your origin already holds a valid cert from 9a).
4. Redeploy with Cloudflare-proxied mode so nginx trusts `CF-Connecting-IP` from Cloudflare's ranges:
   ```bash
   ./deploy.sh --cloudflare-proxied your-domain.com
   ```
   (This makes nginx attribute the correct real client IP for logging/rate-limiting — it is **not** by itself an access-control mechanism; the actual blocking happens in step 9c below.)
5. Sanity check both still work before locking the firewall down:
   ```bash
   curl -I https://your-domain.com     # via Cloudflare — should work
   curl -I http://<server-public-ip>   # direct IP — still open at this point, expected
   ```

### 9c. Lock the firewall to Cloudflare's IP ranges only

On the server:
```bash
sudo CLOUDFLARE_ONLY_WEB=true \
     AWS_SECURITY_GROUP_ID="sg-xxxxxxxxxxxx" \
     ./scripts/prod-bootstrap.sh
```
This (see [PROD-BOOTSTRAP.md](./PROD-BOOTSTRAP.md) for full details):
- Restricts the host firewall (`ufw`, Ubuntu/Debian) to allow `80`/`443` only from Cloudflare's published IP ranges, instead of `0.0.0.0/0`.
- If `AWS_SECURITY_GROUP_ID` is set (required on Amazon Linux, optional extra layer on Ubuntu/Debian), also rewrites that Security Group's `80`/`443` ingress rules to Cloudflare-only.
- Installs a weekly cron job that re-fetches Cloudflare's ranges and re-applies both, so the allowlist never silently drifts out of date.
- **Never touches port 22/SSH** — your SSH access is unaffected regardless of this setting.

Verify:
```bash
curl -I http://<server-public-ip>   # should now time out / connection refused
curl -I https://your-domain.com     # should still work fine, via Cloudflare
```

### Why the order matters (first cert vs. renewal)

- **First-time issuance** needs your origin reachable directly (gray-cloud, open firewall) — Let's Encrypt's validator resolves your domain via public DNS and connects with *its own* IP, which isn't in Cloudflare's ranges. If the firewall is already Cloudflare-only at this point, issuance fails outright.
- **Renewal**, once orange-cloud is on, works automatically forever after: Let's Encrypt's validator resolves your domain to Cloudflare's IP (not your origin's), Cloudflare receives the challenge request and forwards it to your origin from **its own IP range** — which is exactly what the firewall allowlists. Nothing needs to bypass Cloudflare or reach a "hidden" origin from the outside.
- **Golden rule:** always bootstrap a fresh server in the order above — first cert with proxy off/firewall open, *then* flip proxy on, *then* lock the firewall down. Never do it in the reverse order.

## Reference: which file holds what

| File | Purpose | Committed to git? | Edited by |
|---|---|---|---|
| `.env.local` | Real secrets: `MONGODB_URI`, `AUTH_SECRET`, `NEXT_PUBLIC_SITE_URL` | No (gitignored) | You, by hand |
| `secrets/admin-users.json` | Admin login roster (bcrypt hashes only) | No (gitignored) | `npm run admin:create` |
| `secrets/cloudflare_tunnel_token` | Cloudflare Tunnel token (only if using `--tunnel`) | No (gitignored) | `npm run tunnel:token` |
| `.env` | `DOMAIN`, `NEXT_PUBLIC_SITE_URL`, `CADDYFILE` — Docker Compose's own variable substitution | No (gitignored) | `deploy.sh` (don't edit by hand) |

## Troubleshooting

See the [Troubleshooting section in DEPLOYMENT.md](./DEPLOYMENT.md#troubleshooting) for common issues (stale OG metadata, default-content fallback when MongoDB is unreachable, login failures from misconfigured `ADMIN_USERS_FILE`, etc.), and [RUNNING.md](./RUNNING.md#checking-status--logs) for log commands per service.
