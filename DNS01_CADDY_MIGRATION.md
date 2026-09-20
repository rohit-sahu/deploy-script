# Migrating Caddy from HTTP-01 to DNS-01 (Cloudflare) — Setup Guide

**Status:** Not yet implemented — this is a step-by-step plan for future
execution. Nothing described here has been applied to this repo yet.

## Why do this

Today, Caddy obtains/renews its Let's Encrypt certificate using the **HTTP-01**
challenge:

1. Let's Encrypt makes an HTTP request to `http://<DOMAIN>/.well-known/acme-challenge/<token>`.
2. That request hits `nginx` (port 80), which proxies it to the `caddy`
   companion container, which answers the challenge.
3. This requires port 80 to be open to the internet (AWS Security Group +
   host firewall) at all times — not just during initial issuance, but
   **every ~60 days when Caddy auto-renews**.

This has caused two real production issues already:
- Cloudflare's proxy ("orange cloud") intercepting the challenge before it
  reaches the origin (`403` from a Cloudflare IP).
- `nginx` not forwarding the real `Host` header to Caddy, breaking
  domain-keyed site-block matching (`400 Invalid host in redirect target`).

Switching to **DNS-01** removes port 80 from the certificate lifecycle
entirely:
- Caddy proves domain ownership by creating a temporary `TXT` record via the
  Cloudflare API instead of answering an HTTP request.
- Works transparently even with Cloudflare's proxy enabled.
- Port 80 can then be closed/firewalled if desired (or kept open only for a
  plain HTTP → HTTPS redirect, which is optional and low-risk).

## Prerequisites

- A Cloudflare account managing the DNS zone for your domain (already the
  case here, per earlier diagnosis of the `403` issue).
- Ability to create a scoped Cloudflare API Token (not the legacy Global API
  Key — never use that).
- Docker Buildx available (already set up in this repo for multi-arch
  builds — see `scripts/lib/build-deploy.sh`).

## Architecture change summary

| | Before (HTTP-01) | After (DNS-01) |
|---|---|---|
| Challenge type | HTTP-01 | DNS-01 |
| Port 80 required for renewal | Yes | No |
| Caddy image | Stock `caddy:2-alpine` | Custom build with `caddy-dns/cloudflare` plugin |
| nginx ACME proxy block | Required | Removed |
| New secret | — | Cloudflare API Token |
| Cloudflare proxy (orange cloud) compatible | No (must disable during issuance) | Yes |

---

## Step-by-step implementation plan

### Step 1 — Create a scoped Cloudflare API Token

1. Go to <https://dash.cloudflare.com/profile/api-tokens>.
2. Click **Create Token** → use the **"Edit zone DNS"** template.
3. Under **Zone Resources**, restrict it to **Specific zone → your domain
   only** (never "All zones").
4. Permissions needed: `Zone.DNS: Edit` (the template already sets this).
5. Create the token and copy it immediately (shown only once).

> Security note: this token can only edit DNS records for the one zone you
> scoped it to — it cannot touch billing, other zones, or account settings.
> Treat it exactly like a password.

### Step 2 — Store the token as a file-based secret

This repo already uses file-based Docker secrets for sensitive values (see
`secrets/cloudflare_tunnel_token`, `secrets/admin-users.json`). Follow the
same convention:

```bash
mkdir -p secrets
# Paste the token when prompted, or echo it directly (avoid shell history):
umask 077
cat > secrets/cloudflare_api_token
# (paste token, then press Ctrl+D)
chmod 600 secrets/cloudflare_api_token
```

Add a `secrets/cloudflare_api_token.example` placeholder file (matching the
pattern of the other `.example` secrets already in this repo) so new
environments know the file is expected, without committing the real value.

**Do not commit `secrets/cloudflare_api_token` itself** — confirm
`.gitignore` already excludes `secrets/*` except the `.example` files (check
existing `.gitignore` before proceeding; the repo's other real secrets are
already excluded this way).

### Step 3 — Add a custom Caddy build (`Dockerfile.caddy`)

Caddy's plugins are compiled in at build time (Go modules), not loaded
dynamically like nginx modules. The stock `caddy:2-alpine` image does not
include any DNS provider plugin, so a custom build is required to add
`caddy-dns/cloudflare`.

Create `Dockerfile.caddy` in the repo root:

```dockerfile
# Build stage: compiles a custom Caddy binary with the Cloudflare DNS plugin
# statically linked in (required for DNS-01 challenges — Caddy plugins are
# compile-time only, not dynamically loadable).
FROM caddy:2-builder-alpine AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

# Final stage: same slim base image this repo already uses, just with the
# custom-built binary swapped in. No other behavior changes.
FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

### Step 4 — Add an entrypoint wrapper to load the secret into an env var

Caddyfile placeholders (`{$VAR}`) read from **process environment
variables**, not files — unlike `cloudflared`, which natively supports a
`TUNNEL_TOKEN_FILE` convention, Caddy has no built-in "read secret from file"
support. A tiny wrapper script bridges this, following the same pattern
already used for `nginx` (`nginx/docker-entrypoint.sh`).

Create `caddy/docker-entrypoint.sh`:

```sh
#!/bin/sh
set -eu

# Caddyfile placeholders read from process env vars, not files -- bridge the
# file-based secret (consistent with this repo's other secrets) into an env
# var Caddy can actually read.
if [ -f /run/secrets/cloudflare_api_token ]; then
  CF_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
  export CF_API_TOKEN
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
```

Make it executable: `chmod +x caddy/docker-entrypoint.sh`.

### Step 5 — Update the `Caddyfile`

```caddyfile
{
	admin off
}

# Cert-only mode: this site block exists solely so Caddy requests/renews a
# real ACME certificate for $DOMAIN. Uses DNS-01 (Cloudflare API) instead of
# HTTP-01 -- no port 80 exposure needed for issuance or renewal, and this
# works even with Cloudflare's proxy ("orange cloud") enabled on the record.
# nginx reads the resulting cert/key straight off the caddy_data volume and
# handles all actual TLS termination and traffic.
{$DOMAIN} {
	tls {
		dns cloudflare {$CF_API_TOKEN}
	}
	respond "ok"
}
```

Notes on what changed vs. the current file:
- Removed `http_port 80` / `https_port 8443` — Caddy no longer needs to bind
  to any HTTP port for cert issuance in this cert-only companion role.
- Added the `tls { dns cloudflare ... }` directive, which switches the ACME
  challenge type from HTTP-01 to DNS-01.

`Caddyfile.local` (self-signed, `tls internal`, no ACME) is **unaffected** —
leave it exactly as-is; local testing never touches Let's Encrypt or
Cloudflare.

### Step 6 — Update `docker-compose.yml`

**`caddy` service** — replace the stock image with the custom build, wire in
the new secret, and drop the port 80 `expose`:

```yaml
caddy:
  build:
    context: .
    dockerfile: Dockerfile.caddy
  restart: unless-stopped
  entrypoint: ["/bin/sh", "/entrypoint.sh"]
  environment:
    DOMAIN: ${DOMAIN:?set DOMAIN to your production hostname, e.g. your-domain.com}
  volumes:
    - ${CADDYFILE:-./Caddyfile}:/etc/caddy/Caddyfile:ro
    - ./caddy/docker-entrypoint.sh:/entrypoint.sh:ro
    - caddy_data:/data
    - caddy_config:/config
  secrets:
    - cloudflare_api_token
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
  deploy:
    resources:
      limits:
        cpus: "0.5"
        memory: 256M
```

Key changes from the current block:
- `image: caddy:2-alpine` → `build: {context: ., dockerfile: Dockerfile.caddy}`
- Removed `expose: ["80"]` (no longer listens on any port at all — DNS-01
  needs no inbound traffic whatsoever).
- Added `entrypoint` pointing at the new wrapper script + its volume mount.
- Added `secrets: [cloudflare_api_token]`.

**`secrets:` top-level block** — add the new secret alongside the existing
two:

```yaml
secrets:
  cloudflare_tunnel_token:
    file: ./secrets/cloudflare_tunnel_token
  admin_users:
    file: ${ADMIN_USERS_FILE:-./secrets/admin-users.json}
  cloudflare_api_token:
    file: ./secrets/cloudflare_api_token
```

**`nginx` service** — no changes needed to ports (still needs 80 for the
plain-HTTP→HTTPS redirect and its healthcheck, both unrelated to ACME) unless
you also want to fully close port 80 (see Step 8 below, optional).

### Step 7 — Update `nginx/app.conf.template`

Remove the now-dead ACME challenge proxy block (the fix applied earlier —
`proxy_set_header Host $host;` — becomes moot since Caddy no longer answers
HTTP-01 challenges at all):

```nginx
server {
	listen 80;
	server_name ${DOMAIN};

	# Container healthcheck target; must not redirect (avoids following to
	# HTTPS and failing TLS verification against a not-yet-trusted cert).
	location = /healthz {
		default_type text/plain;
		return 200 "ok";
	}

	# Block all other plain HTTP traffic; force HTTPS.
	location / {
		return 301 https://$host$request_uri;
	}
}
```

(Just delete the `location /.well-known/acme-challenge/ { ... }` block —
everything else in this file stays the same.)

### Step 8 — (Optional) Close port 80 entirely

Once Step 7 is live and verified, port 80 no longer serves any ACME purpose.
You can choose to:
- **Keep it** for the plain HTTP → HTTPS redirect (best for user experience —
  visitors typing `http://yourdomain.com` still get redirected instead of a
  connection failure). Low risk, minimal attack surface (just a redirect).
- **Close it** in your AWS Security Group / `ufw` if you don't care about
  handling plain-HTTP visitors and want the absolute minimum exposed surface.
  If you do this, also remove `ports: ["80:80"]` from the `nginx` service
  (keep `expose: ["80"]` internally only if something else still needs it —
  otherwise remove entirely).

### Step 9 — Build and test locally

```bash
# Build the custom Caddy image
docker compose build caddy

# Bring up the full stack with the real DOMAIN (requires the Cloudflare
# token secret to exist at secrets/cloudflare_api_token from Step 2)
DOMAIN=yourdomain.com docker compose up -d caddy

# Watch Caddy's logs for successful DNS-01 issuance
docker compose logs -f caddy
```

Look for log lines indicating `caddy-dns/cloudflare` was used to create/clean
up a `_acme-challenge` TXT record, followed by a successful certificate
obtained message. No port 80 traffic should be involved at all.

### Step 10 — Deploy to production

Follow the same deployment flow already used for other changes in this repo
(`deploy.sh`), since `caddy` is now also a `build:`-based service:

```bash
./deploy.sh --pull    # or your usual production deploy path
```

Ensure `secrets/cloudflare_api_token` exists on the production host (EC2)
with the same `600` permissions as the other secrets before starting the
stack, and that `prod-bootstrap.sh` also documents/provisions it if it
provisions the others.

### Step 11 — Rollback plan

If DNS-01 issuance fails in production (e.g. token misconfigured):
1. Revert `docker-compose.yml`/`Caddyfile` changes (`git checkout` the
   previous versions).
2. Restore `nginx/app.conf.template`'s ACME challenge block.
3. Re-open port 80 in the Security Group if it was closed.
4. Restart the stack — this reverts cleanly to the current, already-working
   HTTP-01 flow. No certificate data is lost (`caddy_data` volume already
   holds valid Let's Encrypt certs which remain valid until their existing
   expiry regardless of which challenge type issued them).

---

## Verification checklist (after implementation)

- [ ] `docker compose config` parses cleanly with no schema errors.
- [ ] `docker compose build caddy` succeeds (custom image builds with the
      Cloudflare plugin compiled in).
- [ ] `docker compose logs caddy` shows a successful DNS-01 challenge and
      certificate issuance (or renewal) with **no** HTTP-01 log lines.
- [ ] `nginx` still serves HTTPS correctly using the cert Caddy obtained
      (`curl -v https://yourdomain.com` — cert issuer should be Let's
      Encrypt, not self-signed).
- [ ] If port 80 was closed: confirm plain `http://yourdomain.com` requests
      fail/timeout as expected (or redirect, if kept open for that purpose).
- [ ] Confirm `secrets/cloudflare_api_token` is **not** tracked by git
      (`git status` / `git check-ignore -v secrets/cloudflare_api_token`).

## Security notes

- Use a **scoped** API Token (Zone:DNS:Edit, one zone only) — never the
  legacy Global API Key, which grants full account access.
- The token file should be `chmod 600`, owned by the same host user as the
  other secrets (see `prod-bootstrap.sh`'s `APP_USER_UID` pinning work — the
  `caddy` container may need the same `user:` override treatment as
  `cloudflared` did, if it can't otherwise read the secret at its default
  container uid).
- Rotate the token periodically via the Cloudflare dashboard; no code
  changes needed on rotation, just replace the file contents.
