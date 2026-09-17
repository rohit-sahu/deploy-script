#!/usr/bin/env bash
# One-command production deploy: builds and starts nginx + Caddy (ACME) + the
# app, waits for containers to become healthy, then waits for the HTTPS
# certificate to be issued. Safe to re-run; settings persist in .env.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=".env"
HEALTH_TIMEOUT=180
CERT_TIMEOUT=180

usage() {
	cat <<EOF
Usage: $0 [--local] [--tunnel | --quick-tunnel] [--pull] <domain> [next-public-site-url]

Production (real ACME certificate, requires public DNS + open 80/443):
  $0 your-domain.com
  $0 your-domain.com https://your-domain.com

Local testing (self-signed cert via Caddy's internal CA, no DNS/internet needed):
  $0 --local
  $0 --local myapp.localhost

Cloudflare named tunnel (--tunnel): your own hostname, configured in the
Cloudflare dashboard. Prompts to create secrets/cloudflare_tunnel_token via
'npm run tunnel:token' if it doesn't exist yet and this is an interactive
terminal (see secrets/cloudflare_tunnel_token.example and RUNNING.md).
  $0 --tunnel your-domain.com
  $0 --local --tunnel

Cloudflare quick tunnel (--quick-tunnel): no token/dashboard setup needed,
prints a random https://<random>.trycloudflare.com URL in
'docker compose logs cloudflared-quick'. Not for production.
  $0 --local --quick-tunnel
  $0 your-domain.com --quick-tunnel

--tunnel and --quick-tunnel are mutually exclusive. Neither flag = no
Cloudflare Tunnel (just nginx + Caddy).

Pull a pre-built image instead of building locally (--pull): requires IMAGE
to be set to a registry reference (e.g. an ECR image), and that image to
already be pushed and pullable from this host.
  IMAGE=<account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest \\
    $0 --pull your-domain.com

Re-run with no arguments once ${ENV_FILE} already has a DOMAIN to redeploy.

Also prompts to create the first /admin login (via 'npm run admin:create')
if secrets/admin-users.json has none yet and this is an interactive terminal.
EOF
}

# True (exit 0) iff FILE parses as JSON containing a non-empty array.
json_array_nonempty() {
	[ -f "$1" ] && node -e '
		try {
			const arr = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
			process.exit(Array.isArray(arr) && arr.length > 0 ? 0 : 1);
		} catch { process.exit(1); }
	' "$1" 2>/dev/null
}

get_env_var() {
	[ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

set_env_var() {
	touch "$ENV_FILE"
	if grep -qE "^$1=" "$ENV_FILE"; then
		sed -i.bak -E "s|^$1=.*|$1=$2|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
	else
		printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
	fi
}

# Check for Node.js and npm, which are required for some setup tasks
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required but not found. Install Node.js first: https://nodejs.org/en/download/" >&2
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required but not found. Install npm first: https://www.npmjs.com/get-npm" >&2
  exit 1
fi
# Install Node.js dependencies if package.json exists
if [ -f "package.json" ]; then
  echo "Installing Node.js dependencies..."
  npm install
fi

LOCAL=0
TUNNEL=0
QUICK_TUNNEL=0
PULL=0
args=()
for arg in "$@"; do
	case "$arg" in
		--local) LOCAL=1 ;;
		--tunnel) TUNNEL=1 ;;
		--quick-tunnel) QUICK_TUNNEL=1 ;;
		--pull) PULL=1 ;;
		-h|--help) usage; exit 0 ;;
		# Any other -*/--* flag is unrecognized — fail fast instead of
		# silently treating it as the domain (which would deploy for real
		# with a nonsense DOMAIN, e.g. `deploy.sh --help` used to do).
		-*) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
		*) args+=("$arg") ;;
	esac
done
if [ "${#args[@]}" -gt 0 ]; then
	set -- "${args[@]}"
else
	set --
fi

DOMAIN_ARG="${1:-}"
DOMAIN="${DOMAIN_ARG:-$(get_env_var DOMAIN)}"
SITE_URL="${2:-$(get_env_var NEXT_PUBLIC_SITE_URL)}"

if [ "$LOCAL" -eq 1 ]; then
	# Always localhost (or an explicit arg) here, never a domain left over in
	# .env from a previous production run — otherwise --local with no domain
	# silently redeploys the real domain with a self-signed cert instead.
	DOMAIN="${DOMAIN_ARG:-localhost}"
	CADDYFILE="./Caddyfile.local"
	LOCAL_CERT_MODE=1
elif [ -n "$DOMAIN_ARG" ]; then
	# explicit domain passed -> production mode
	CADDYFILE="./Caddyfile"
	LOCAL_CERT_MODE=0
else
	# bare redeploy -> keep whichever mode was used last time
	CADDYFILE="$(get_env_var CADDYFILE)"
	CADDYFILE="${CADDYFILE:-./Caddyfile}"
	LOCAL_CERT_MODE=0
	[ "$CADDYFILE" = "./Caddyfile.local" ] && LOCAL_CERT_MODE=1
fi
export LOCAL_CERT_MODE

if [ -z "$DOMAIN" ]; then
	usage
	exit 1
fi
SITE_URL="${SITE_URL:-https://$DOMAIN}"
export CADDYFILE

if [ "$TUNNEL" -eq 1 ] && [ "$QUICK_TUNNEL" -eq 1 ]; then
	echo "Use either --tunnel or --quick-tunnel, not both." >&2
	exit 1
fi

CLOUDFLARE_TOKEN_FILE="secrets/cloudflare_tunnel_token"
if [ "$QUICK_TUNNEL" -eq 1 ]; then
	export COMPOSE_PROFILES=cloudflare-quick
elif [ "$TUNNEL" -eq 1 ]; then
	if [ ! -s "$CLOUDFLARE_TOKEN_FILE" ] && [ -t 0 ]; then
		echo "==> --tunnel requires $CLOUDFLARE_TOKEN_FILE; creating it now:"
		npm run --silent tunnel:token
	fi
	if [ ! -s "$CLOUDFLARE_TOKEN_FILE" ]; then
		echo "--tunnel requires $CLOUDFLARE_TOKEN_FILE (copy secrets/cloudflare_tunnel_token.example, fill in your token, chmod 600 it, or run: npm run tunnel:token)." >&2
		exit 1
	fi
	export COMPOSE_PROFILES=cloudflare
	perm="$(stat -f '%OLp' "$CLOUDFLARE_TOKEN_FILE" 2>/dev/null || stat -c '%a' "$CLOUDFLARE_TOKEN_FILE" 2>/dev/null || echo '')"
	if [ -n "$perm" ] && [ "$perm" != "600" ]; then
		echo "WARNING: $CLOUDFLARE_TOKEN_FILE has permissions $perm; recommend: chmod 600 $CLOUDFLARE_TOKEN_FILE" >&2
	fi
fi

ADMIN_USERS_FILE="secrets/admin-users.json"
if ! json_array_nonempty "$ADMIN_USERS_FILE"; then
	if [ -t 0 ]; then
		echo "==> No /admin login configured yet ($ADMIN_USERS_FILE); creating one now:"
		npm run --silent admin:create
	fi
	if ! json_array_nonempty "$ADMIN_USERS_FILE"; then
		echo "WARNING: $ADMIN_USERS_FILE has no admin users yet; /admin will be unreachable until you run: npm run admin:create" >&2
	fi
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "Docker is required but not found. Install Docker Desktop/Engine first: https://docs.docker.com/get-docker/" >&2
	exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
	echo "The 'docker compose' plugin is required but not found." >&2
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	echo "Docker daemon is not running. Start Docker and re-run this script." >&2
	exit 1
fi

if [ "$PULL" -eq 1 ] && [ -z "${IMAGE:-}" ]; then
	echo "--pull requires IMAGE to be set to a registry reference, e.g.:" >&2
	echo "  IMAGE=<account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest $0 --pull $DOMAIN" >&2
	exit 1
fi

set_env_var DOMAIN "$DOMAIN"
set_env_var NEXT_PUBLIC_SITE_URL "$SITE_URL"
set_env_var CADDYFILE "$CADDYFILE"
echo "==> Domain: $DOMAIN"
echo "==> Site URL: $SITE_URL"
if [ "$LOCAL" -eq 1 ]; then
	echo "==> Mode: LOCAL TESTING (self-signed certificate, browsers/curl will warn)"
fi
if [ "${COMPOSE_PROFILES:-}" = "cloudflare" ]; then
	echo "==> Cloudflare Tunnel: enabled ($CLOUDFLARE_TOKEN_FILE found)"
elif [ "${COMPOSE_PROFILES:-}" = "cloudflare-quick" ]; then
	echo "==> Cloudflare Tunnel: quick tunnel enabled (ephemeral, no auth)"
fi

if [ "$PULL" -eq 1 ]; then
	echo "==> Pulling image: ${IMAGE}..."
	docker compose pull web
else
	echo "==> Building images..."
	docker compose build
fi

echo "==> Starting stack..."
docker compose up -d

wait_healthy() {
	local service="$1" deadline elapsed=0
	deadline=$HEALTH_TIMEOUT
	echo -n "==> Waiting for '$service' to be healthy"
	while [ "$elapsed" -lt "$deadline" ]; do
		status="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q "$service")" 2>/dev/null || echo unknown)"
		if [ "$status" = "healthy" ]; then
			echo " OK"
			return 0
		fi
		echo -n "."
		sleep 3
		elapsed=$((elapsed + 3))
	done
	echo " TIMEOUT"
	echo "See: docker compose logs $service" >&2
	return 1
}

wait_healthy web
wait_healthy nginx
if [ "${COMPOSE_PROFILES:-}" = "cloudflare" ]; then
	wait_healthy cloudflared
elif [ "${COMPOSE_PROFILES:-}" = "cloudflare-quick" ]; then
	wait_healthy cloudflared-quick
	echo "==> Quick tunnel URL: docker compose logs cloudflared-quick | grep trycloudflare.com"
fi

echo -n "==> Waiting for HTTPS certificate to be issued"
elapsed=0
# A Cloudflare Tunnel hostname is usually a CNAME to Cloudflare, not this
# server's IP, so Caddy's HTTP-01 ACME challenge often can't succeed at all
# — that's fine, since Cloudflare's own edge already terminates HTTPS for
# tunnel traffic (see RUNNING.md). Don't hard-fail the whole deploy on that;
# just wait briefly in case DNS *also* points here for direct access.
cert_wait_timeout="$CERT_TIMEOUT"
tunnel_active=0
if [ "$TUNNEL" -eq 1 ] || [ "$QUICK_TUNNEL" -eq 1 ]; then
	tunnel_active=1
	cert_wait_timeout=30
fi
while [ "$elapsed" -lt "$cert_wait_timeout" ]; do
	if docker compose exec -T nginx test -f /etc/nginx/conf.d/https.conf >/dev/null 2>&1; then
		echo " OK"
		echo "==> HTTPS is live: https://$DOMAIN"
		if [ "$LOCAL" -eq 1 ]; then
			echo "==> Self-signed cert: browsers will warn; test with: curl -k https://$DOMAIN"
		fi
		exit 0
	fi
	echo -n "."
	sleep 3
	elapsed=$((elapsed + 3))
done

if [ "$tunnel_active" -eq 1 ]; then
	echo " skipped"
	echo "==> nginx/Caddy don't have a direct cert for $DOMAIN yet — expected if its DNS only points at the Cloudflare Tunnel rather than this server's IP."
	echo "==> This does not affect the tunnel: Cloudflare terminates HTTPS at its edge and forwards to this tunnel's configured Service (should be http://web:3000)."
	echo "==> Site should already be live at: https://$DOMAIN"
	echo "==> If you also expect direct (non-tunnel) HTTPS access to work, check: docker compose logs caddy"
	exit 0
fi

echo " TIMEOUT"
echo "Certificate not issued yet. Check: docker compose logs caddy" >&2
exit 1
