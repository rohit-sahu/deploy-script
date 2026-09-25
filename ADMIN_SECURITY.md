# Admin Login Security & Cloudflare IP Automation — Reference

Full picture of the `/admin` login-security stack (rate limiting, 2FA, IP
allowlist), the nginx IP-forwarding fixes, the conditional Cloudflare-proxied
nginx mode, and the Cloudflare IP-range auto-updater — what each file does,
how to use it, and how a request flows end-to-end. Cross-references
[`RUNNING.md`](./RUNNING.md) (day-to-day usage) and
[`DEPLOYMENT.md`](./DEPLOYMENT.md) (manual/non-Docker nginx equivalents).

---

## 1. Admin login security (rate limiting + 2FA + IP allowlist)

### New/updated files & their job

| File | Purpose |
|---|---|
| `scripts/node/lib/totp.mjs` | Hand-rolled RFC 6238 TOTP (6-digit, 30s, SHA-1 — Google Authenticator/Authy compatible) + AES-256-GCM encrypt/decrypt for the secret at rest. Pure Node crypto, no deps. |
| `scripts/node/create-admin.mjs` | CLI: `npm run admin:create`. Now also asks "Enable 2FA?" per admin — generates a secret, renders a scannable **QR code directly in the terminal** (via `qrcode-terminal`) plus the raw secret/otpauth URI as a manual-entry fallback, confirms with a live code, then stores it **encrypted** via `ADMIN_SECRETS_KEY`. |
| `scripts/node/create-env.mjs` | CLI: `npm run env:create`. Now auto-generates `ADMIN_SECRETS_KEY` (like `AUTH_SECRET`) and prompts for `ADMIN_IP_ALLOWLIST` / `ADMIN_TOTP_ISSUER`. |
| `.env.example`, `secrets/admin-users.json.example` | Documented the 3 new fields/vars. |
| `docker-compose.yml` | Comments clarify these env vars flow into the `web` container. |
| `qrcode-terminal` (new dependency) | Zero-dependency-of-its-own npm package used only by `create-admin.mjs` to render the ASCII-art QR code. The only new npm dependency added by this whole feature — deliberately **not** emailing the 2FA secret/QR (see below), since that would let a compromised email account also compromise 2FA. |

The actual auth logic (rate limiter, TOTP verification, IP-allowlist
middleware) lives in the **portfolio app repo** (`src/auth.ts`,
`src/lib/rate-limit.ts`, `src/lib/totp.ts`, `src/lib/ip-allowlist.ts`,
`src/proxy.ts`) — this repo only owns the CLI enrollment tooling and the
env/secrets scaffolding around it, since it has its own independent copy of
`create-admin.mjs`/`create-env.mjs`/`secrets/`.

### Usage

```bash
npm run env:create          # sets up ADMIN_SECRETS_KEY / ADMIN_IP_ALLOWLIST / ADMIN_TOTP_ISSUER in .env.local or .env.prod
npm run admin:create        # add/update an admin; optionally enroll 2FA
```

Rate limiting is **always on** (no setup needed) — 5 failed attempts / 15 min
lockout, tracked in MongoDB, fails open if MongoDB is briefly unreachable.

### Flow at login

1. Request hits `/admin/login` → edge middleware (`src/proxy.ts` in the
   **portfolio** app repo) checks `ADMIN_IP_ALLOWLIST` first — blocks with
   403 if the IP isn't allowed.
2. User submits email+password → `authorize()` checks rate limit (email +
   IP keys) → verifies bcrypt hash.
3. If the account has `totpSecret` set, login **pauses**, the form
   re-renders asking for the 6-digit code (email/password preserved in
   React state so they survive the round-trip).
4. User submits the code → decrypted via `ADMIN_SECRETS_KEY` → verified
   (±30s window) → session created.

---

## 2. nginx IP-forwarding fix (spoofing bug)

`nginx/https.conf.template` — changed
`X-Forwarded-For $proxy_add_x_forwarded_for` → `X-Forwarded-For $remote_addr`.

No usage change — this is automatic. `$proxy_add_x_forwarded_for` *appends*
to whatever `X-Forwarded-For` the client already sent, which let an
attacker prepend a fake IP and have it trusted (since the app reads the
left-most entry) — defeating the allowlist/rate limiting. `$remote_addr`
always reflects the actual TCP peer, which nginx (as the first hop) can't
be lied to about.

---

## 3. Cloudflare-proxied nginx mode (conditional config)

### New/updated files

| File | Purpose |
|---|---|
| `nginx/https.cloudflare.conf.template` | Alternate nginx config — uses `ngx_http_realip_module` to trust `CF-Connecting-IP` instead of `$remote_addr`. |
| `nginx/cloudflare-ips.conf` | Cloudflare's IP ranges as `set_real_ip_from` lines — restricts which upstream is trusted to set that header. |
| `nginx/docker-entrypoint.sh` | Picks between the two templates based on the `CLOUDFLARE_PROXIED` env var at container start. |
| `deploy.sh` | New `--cloudflare-proxied` / `--no-cloudflare-proxied` flags, persisted in `.env` like `DOMAIN`. |
| `docker-compose.yml` | Mounts both templates + `cloudflare-ips.conf`; passes `CLOUDFLARE_PROXIED` through. |

### Usage

```bash
./deploy.sh --cloudflare-proxied your-domain.com     # only if Cloudflare orange-cloud DNS points directly at this nginx
./deploy.sh --no-cloudflare-proxied your-domain.com  # switch back
./deploy.sh your-domain.com                          # bare re-run remembers whichever was set last
```

**You must also firewall 80/443 to Cloudflare's ranges yourself** — the flag
alone doesn't do that (host-level step, this script can't automate it).

Not needed for `--tunnel`/`--quick-tunnel` — `cloudflared` bypasses nginx
entirely, and Cloudflare's edge already sets `CF-Connecting-IP` on that path
regardless of this flag.

### Flow

- `CLOUDFLARE_PROXIED=0` (default): nginx is the first hop → `$remote_addr`
  = real visitor IP → set as `X-Forwarded-For`.
- `CLOUDFLARE_PROXIED=1`: Cloudflare is the first hop → nginx's
  `real_ip_module` (trusting only Cloudflare's IPs) rewrites `$remote_addr`
  from the `CF-Connecting-IP` header → then forwarded the same way.
- Either way, the app (`src/lib/client-ip.ts` in the portfolio repo) checks
  `CF-Connecting-IP` first, then `X-Forwarded-For`, then `X-Real-IP` — so it
  resolves correctly regardless of which ingress path/mode was actually used.

---

## 4. Cloudflare IP-range auto-updater

### New file

`scripts/node/update-cloudflare-ips.mjs` — bundled into `dist/` via
`scripts/node/build.mjs`, exposed as an npm script. Zero new dependencies
(Node's built-in `https`/`fs` only).

### Usage

```bash
npm run cloudflare-ips:update            # fetch latest ranges, rewrite cloudflare-ips.conf if changed, reload nginx
npm run cloudflare-ips:update -- --check # exit 1 if stale, don't write (for cron/monitoring)
```

Automate via crontab:

```cron
0 3 * * 0 cd /path/to/deploy-script && npm run cloudflare-ips:update >> /var/log/cloudflare-ips-update.log 2>&1
```

### Flow

1. Fetches `https://www.cloudflare.com/ips-v4`/`-v6`.
2. Rebuilds `nginx/cloudflare-ips.conf`, ignoring its own date-stamp comment
   when diffing (so a same-day re-run, or genuinely unchanged ranges, never
   falsely reports "changed").
3. If content actually differs → writes the file → reloads nginx via
   `docker compose exec nginx nginx -s reload` (only if nginx is currently
   running; otherwise the new file is simply picked up on next start).
4. Feeds into `https.cloudflare.conf.template`'s `include`, which only
   matters when `CLOUDFLARE_PROXIED=1`.

---

## End-to-end picture

```
Internet → [nginx (443) OR cloudflared (Tunnel)] → web:3000 (Next.js, /admin*)
                     ↑
   IP-trust resolved here (real_ip module + Cloudflare ranges, or Cloudflare's own edge)
                     ↓
   CF-Connecting-IP / X-Forwarded-For → app's getClientIp()
                     ↓
   /admin/* edge middleware: IP allowlist check
                     ↓
   Login: rate limit (Mongo) → bcrypt → optional TOTP (AES-256-GCM decrypted) → session
```

Cloudflare's IP list feeding the `real_ip` trust step is kept fresh by the
updater script above, either manually or via cron.
