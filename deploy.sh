#!/usr/bin/env bash
# One-command production deploy: builds and starts nginx + Caddy (ACME) + the
# app, waits for containers to become healthy, then waits for the HTTPS
# certificate to be issued. Safe to re-run; settings persist in .env.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./scripts/lib/deploy-env.sh
source ./scripts/lib/deploy-env.sh

ENV_FILE=".env"
HEALTH_TIMEOUT=180
CERT_TIMEOUT=180

usage() {
	cat <<EOF
Usage: $0 [OPTIONS] <domain> [next-public-site-url]

Every setting below can come from FIVE input sources, tried in this order
(first match wins):
  1. CLI flag / positional arg     e.g. $0 your-domain.com
  2. Raw already-exported env var  e.g. export NEXT_PUBLIC_SITE_URL=...
                                    (or NEXT_PUBLIC_SITE_URL=... $0 ...)
  3. This script's own state file  ${ENV_FILE} (auto-written after every run,
                                    so a bare re-run remembers DOMAIN etc.)
  4. Fallback settings file        --env-file/\$ENV_FILE_PATH (default:
                                    .env.local, e.g. NEXT_PUBLIC_SITE_URL
                                    already defined there for local dev)
  5. Interactive prompt (only asked when stdin is a real terminal — never
     hangs in CI/non-interactive runs), then a hardcoded default, or a hard
     error if the setting has no safe default (DOMAIN, IMAGE for --pull)

Options (CLI flag | source key | default):
  <domain> (positional)        | DOMAIN (in ${ENV_FILE})       | (none — required unless --local)
  [next-public-site-url] (pos.)| NEXT_PUBLIC_SITE_URL           | https://<domain>
  --app-dir DIR                 | APP_DIR (in ${ENV_FILE})       | /app
  --local                      | (boolean flag)                | off
  --tunnel                     | (boolean flag)                | off
  --quick-tunnel                | (boolean flag)                | off
  --pull                        | (boolean flag)                | off
  --push                        | (boolean flag)                | off
  (with --pull/--push) IMAGE via | IMAGE (in ${ENV_FILE})        | (none — required)
  --multi-arch / --no-multi-arch (with --push) | MULTI_ARCH (in ${ENV_FILE}) | off (prompted if interactive)
  --platforms LIST (with --push --multi-arch) | PLATFORMS (in ${ENV_FILE}) | linux/amd64,linux/arm64
  --ghcr-user USER (with --push, optional) | GHCR_USER          | (none — see below)
  --ghcr-token TOKEN (with --push, optional) | GHCR_TOKEN       | (none — see below)
  --env-file PATH               | ENV_FILE_PATH                 | .env.local
  --no-up                        | (n/a, boolean flag)           | off
  -h, --help                     Show this help and exit

--app-dir sets the container-internal working directory (forwarded to
docker-compose.yml's APP_DIR build arg, and to the resume-cache volume/
image-cache tmpfs mount paths). Applies whether you build locally or --pull
a pre-built image: only set this if the image you're pulling was itself
built with a non-default APP_DIR — otherwise leave it unset (defaults to
/app). Remembered in ${ENV_FILE} like DOMAIN/IMAGE, so a bare re-run keeps
using whatever value you set the first time.

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

Build locally, push the result to a registry, then run it here too (--push):
requires IMAGE to be set. Useful when this same server should both serve the
site and keep a registry copy (for backup / reuse on other servers). Registry
login is handled automatically, in this order:
  1. Already logged in? (existing 'docker login'/credential helper entry for
     that registry) -> skip login entirely, just push.
  2. Otherwise, GHCR_USER/GHCR_TOKEN from --ghcr-user/--ghcr-token, an env
     var, or --env-file/.env.local -> log in with those.
  3. Otherwise, if this is a real terminal, prompt for a username/token
     (leave username blank to skip login and try pushing anyway).
  4. Otherwise (non-interactive, nothing provided) -> skip login and attempt
     the push as-is; docker will report a clear auth error if one was needed.
  IMAGE=ghcr.io/<owner>/rohit-portfolio:latest $0 --push your-domain.com
  $0 --push your-domain.com --ghcr-user myuser --ghcr-token ghp_xxx

Build a multi-arch (linux/amd64 + linux/arm64) image and push it as a single
manifest (--multi-arch, only meaningful with --push): delegates to
scripts/lib/build-deploy.sh, which builds via buildx/docker-container driver
so any host (this one or a different-arch one, e.g. amd64 EC2) can pull the
right native image with no "platform does not match" warning. Since a
multi-arch image can't be loaded into the local Docker engine directly, this
script pulls the tag back down afterward (Docker auto-selects this host's
matching layer from the manifest) before starting the stack — skipped
entirely with --no-up.
  IMAGE=ghcr.io/<owner>/rohit-portfolio:latest $0 --push --multi-arch
  $0 --push --no-multi-arch   # force native single-arch push instead

Customize which platforms --multi-arch builds for via --platforms (comma-
separated, forwarded as-is to buildx/build-deploy.sh's PLATFORMS). Defaults
to linux/amd64,linux/arm64 if unset -- add more (e.g. linux/arm/v7) or
narrow it down without editing any script:
  $0 --push --multi-arch --platforms linux/amd64,linux/arm64,linux/arm/v7

--pull and --push are mutually exclusive. Neither flag = build and run
locally only, no registry involved.

Re-run with no arguments once ${ENV_FILE} already has a DOMAIN to redeploy.

Also prompts to create the first /admin login (via 'npm run admin:create')
if secrets/admin-users.json has none yet and this is an interactive terminal.

--no-up skips the final 'docker compose up -d' (and the health/cert-check
waits) after building/pulling/pushing — useful when you only want the image
prepared and will start the stack yourself later.
EOF
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
# Build the CLI scripts (dist/*.mjs) if package.json exists. 'npm run build'
# already runs its own 'npm install' first and removes node_modules at the
# end (see package.json) — the resulting dist/*.mjs bundles are
# self-contained (no node_modules needed at runtime). This step is required
# before any of the npm run env:create/admin:create/tunnel:token calls below,
# since dist/ is gitignored and doesn't exist on a fresh clone.
if [ -f "package.json" ]; then
  echo "Installing Node.js dependencies.. and Building CLI scripts (dist/*.mjs)..."
  npm run build
fi

LOCAL=0
TUNNEL=0
QUICK_TUNNEL=0
PULL=0
PUSH=0
NO_UP=0
ENV_FILE_ARG=""
GHCR_USER_ARG=""
GHCR_TOKEN_ARG=""
APP_DIR_ARG=""
MULTI_ARCH_ARG=""
PLATFORMS_ARG=""
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		--local) LOCAL=1; shift ;;
		--tunnel) TUNNEL=1; shift ;;
		--quick-tunnel) QUICK_TUNNEL=1; shift ;;
		--pull) PULL=1; shift ;;
		--push) PUSH=1; shift ;;
		--multi-arch) MULTI_ARCH_ARG="1"; shift ;;
		--multi-arch=*) MULTI_ARCH_ARG="${1#*=}"; shift ;;
		--no-multi-arch) MULTI_ARCH_ARG="0"; shift ;;
		--platforms) PLATFORMS_ARG="${2:-}"; shift 2 ;;
		--platforms=*) PLATFORMS_ARG="${1#*=}"; shift ;;
		--no-up) NO_UP=1; shift ;;
		--env-file) ENV_FILE_ARG="${2:-}"; shift 2 ;;
		--env-file=*) ENV_FILE_ARG="${1#*=}"; shift ;;
		--ghcr-user) GHCR_USER_ARG="${2:-}"; shift 2 ;;
		--ghcr-user=*) GHCR_USER_ARG="${1#*=}"; shift ;;
		--ghcr-token) GHCR_TOKEN_ARG="${2:-}"; shift 2 ;;
		--ghcr-token=*) GHCR_TOKEN_ARG="${1#*=}"; shift ;;
		--app-dir) APP_DIR_ARG="${2:-}"; shift 2 ;;
		--app-dir=*) APP_DIR_ARG="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		# Any other -*/--* flag is unrecognized — fail fast instead of
		# silently treating it as the domain (which would deploy for real
		# with a nonsense DOMAIN, e.g. `deploy.sh --help` used to do).
		-*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
		*) args+=("$1"); shift ;;
	esac
done
if [ "${#args[@]}" -gt 0 ]; then
	set -- "${args[@]}"
else
	set --
fi

# Optional dotenv-style file (.env.local/.env.prod/etc.) used as an EXTRA
# fallback source (tier 4) — see usage() above for the full 5-tier chain.
# Never overrides a CLI flag/positional arg, an already-exported env var, or
# a value already in this script's own state file ($ENV_FILE). Missing file
# is not an error — it's simply skipped.
export ENV_FILE_PATH="${ENV_FILE_ARG:-${ENV_FILE_PATH:-.env.local}}"
[ -f "$ENV_FILE_PATH" ] && echo "==> Using fallback settings file: $ENV_FILE_PATH"

DOMAIN_DEFAULT="localhost"
APP_DIR_DEFAULT="/opt/portfolio"

DOMAIN_ARG="${1:-}"
DOMAIN="$(resolve_setting "$DOMAIN_ARG" DOMAIN DOMAIN DOMAIN)"
NEXT_PUBLIC_SITE_URL="$(resolve_setting "${2:-}" NEXT_PUBLIC_SITE_URL NEXT_PUBLIC_SITE_URL NEXT_PUBLIC_SITE_URL)"

# Ask before creating or updating the env file that docker-compose's
# env_file (MONGODB_URI/AUTH_SECRET) will load — never silent, always asks,
# and only runs at all in an interactive terminal.
if [ -t 0 ]; then
	if [ ! -f "$ENV_FILE_PATH" ]; then
		read -p "==> $ENV_FILE_PATH not found. Create it now? [Y/n] " create_ans
		if [ -z "$create_ans" ] || [[ "$create_ans" =~ ^[Yy] ]]; then
		  target="local"
      [ "$(basename "$ENV_FILE_PATH")" = ".env.prod" ] && target="prod"
			npm run --silent env:create -- "$target"
		fi
	else
		read -p "==> $ENV_FILE_PATH already exists. Update it now? [y/N] " update_ans
		if [[ "$update_ans" =~ ^[Yy] ]]; then
		  target="local"
      [ "$(basename "$ENV_FILE_PATH")" = ".env.prod" ] && target="prod"
			npm run --silent env:create -- "$target"
		fi
	fi
else
  echo "WARNING: Non interactive terminal — docker-compose's env_file will be missing; run: npm run env:create" >&2
fi

if [ "$LOCAL" -eq 1 ]; then
	# Always localhost (or an explicit arg) here, never a domain left over in
	# .env from a previous production run — otherwise --local with no domain
	# silently redeploys the real domain with a self-signed cert instead.
	DOMAIN="${DOMAIN_ARG:-$DOMAIN_DEFAULT}"
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

if [ -z "$DOMAIN" ] && [ "$LOCAL" -ne 1 ] && [ -t 0 ]; then
	read -p "Domain (e.g. your-domain.com): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
	usage
	exit 1
fi
SITE_URL_DEFAULT="https://$DOMAIN"
if [ -z "$NEXT_PUBLIC_SITE_URL" ] && [ -t 0 ]; then
	read -p "NEXT_PUBLIC_SITE_URL [$SITE_URL_DEFAULT]: " NEXT_PUBLIC_SITE_URL
fi
export NEXT_PUBLIC_SITE_URL="${NEXT_PUBLIC_SITE_URL:-$SITE_URL_DEFAULT}"
export CADDYFILE
export DOMAIN

APP_DIR="$(resolve_setting "$APP_DIR_ARG" APP_DIR APP_DIR APP_DIR)"
if [ -z "$APP_DIR" ] && [ -t 0 ]; then
	read -p "APP_DIR [$APP_DIR_DEFAULT]: " APP_DIR
fi
export APP_DIR="${APP_DIR:-$APP_DIR_DEFAULT}"

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

if [ "$PULL" -eq 1 ] && [ "$PUSH" -eq 1 ]; then
	echo "Use either --pull or --push, not both." >&2
	exit 1
fi

if [ "$PULL" -eq 1 ] || [ "$PUSH" -eq 1 ]; then
	IMAGE="$(resolve_setting "${IMAGE:-}" IMAGE IMAGE IMAGE)"
	flag="--pull"; [ "$PUSH" -eq 1 ] && flag="--push"
	if [ -z "${IMAGE:-}" ] && [ -t 0 ]; then
		read -p "Registry image for $flag (e.g. ghcr.io/<owner>/rohit-portfolio:latest): " IMAGE
	fi
	if [ -z "${IMAGE:-}" ]; then
		echo "$flag requires IMAGE to be set to a registry reference, e.g.:" >&2
		echo "  IMAGE=<account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest $0 $flag $DOMAIN" >&2
		exit 1
	fi
	export IMAGE

	# Registry host is everything before the first "/" in the image ref
	# (e.g. "ghcr.io" out of "ghcr.io/<owner>/rohit-portfolio:latest").
	registry="${IMAGE%%/*}"
	# Optional convenience auto-login: CLI flag -> env var -> .env file ->
	# (only if NOT already logged in to this registry) interactive prompt
	# -> skip login silently. The subsequent pull/push will then fail with
	# its own clear auth error if login actually was required. Applies to
	# --pull too (not just --push): a private registry image needs auth to
	# be pulled just as much as to be pushed.
	GHCR_USER="${GHCR_USER_ARG:-${GHCR_USER:-$(env_file_var GHCR_USER)}}"
	GHCR_TOKEN="${GHCR_TOKEN_ARG:-${GHCR_TOKEN:-$(env_file_var GHCR_TOKEN)}}"

	# Best-effort check: does docker's config already have an auth entry
	# for this registry? (covers a prior `docker login`, a credential
	# helper, or CI runners that pre-authenticate.) Not 100% conclusive,
	# but enough to avoid nagging when login isn't actually needed.
	already_logged_in() {
		local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
		[ -f "$cfg" ] && grep -q "\"$1\"" "$cfg" 2>/dev/null
	}

	if { [ -z "${GHCR_USER:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; } && ! already_logged_in "$registry" && [ -t 0 ]; then
		echo "==> Not logged in to ${registry} yet."
		[ -z "${GHCR_USER:-}" ] && read -p "Registry username (leave blank to skip login): " GHCR_USER
		if [ -n "${GHCR_USER:-}" ] && [ -z "${GHCR_TOKEN:-}" ]; then
			read -s -p "Registry token/password: " GHCR_TOKEN
			echo ""
		fi
	fi

	if [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
		echo "==> Logging in to ${registry}..."
		echo "$GHCR_TOKEN" | docker login "$registry" -u "$GHCR_USER" --password-stdin
	fi

	# --multi-arch only applies to --push (a local-only build with no push is
  # inherently single-arch, so pulling doesn't ask about this at all).
  # Resolved through the same 5-tier chain as every other setting here.
  if [ "$PUSH" -eq 1 ]; then
    MULTI_ARCH="$(resolve_setting "$MULTI_ARCH_ARG" MULTI_ARCH MULTI_ARCH MULTI_ARCH)"
    if [ -z "$MULTI_ARCH" ] && [ -t 0 ]; then
      read -p "Build multi-arch (linux/amd64 + linux/arm64) image? [y/N] " ma_ans
      [[ "$ma_ans" =~ ^[Yy] ]] && MULTI_ARCH=1
    fi
    # Normalize any truthy spelling to a plain 0/1 before persisting, so
    # future reads via resolve_setting stay simple string comparisons.
    case "${MULTI_ARCH:-0}" in
      1|true|TRUE|yes|YES|y|Y) MULTI_ARCH=1 ;;
      *) MULTI_ARCH=0 ;;
    esac
    set_env_var MULTI_ARCH "$MULTI_ARCH"
    echo "==> Multi-arch build: $([ "$MULTI_ARCH" -eq 1 ] && echo "on" || echo "off (native only)")"

    # Which platforms to actually build for -- only meaningful when
    # MULTI_ARCH=1, but resolved/persisted here regardless so a later
    # --multi-arch-only re-run (with no --platforms) still remembers it.
    # Left unset (not exported) when off, so build-deploy.sh's own default
    # (linux/amd64,linux/arm64) applies untouched if ever invoked directly.
    if [ "$MULTI_ARCH" -eq 1 ]; then
      PLATFORMS="$(resolve_setting "$PLATFORMS_ARG" PLATFORMS PLATFORMS PLATFORMS)"
      PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
      set_env_var PLATFORMS "$PLATFORMS"
      echo "==> Platforms: $PLATFORMS"
    fi
  fi
fi

set_env_var DOMAIN "$DOMAIN"
set_env_var NEXT_PUBLIC_SITE_URL "$NEXT_PUBLIC_SITE_URL"
set_env_var CADDYFILE "$CADDYFILE"
set_env_var APP_DIR "$APP_DIR"
[ -n "${IMAGE:-}" ] && set_env_var IMAGE "$IMAGE"
echo "==> Domain: $DOMAIN"
echo "==> Site URL: $NEXT_PUBLIC_SITE_URL"
echo "==> App dir: $APP_DIR"
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
elif [ "$PUSH" -eq 1 ] && [ "${MULTI_ARCH:-0}" -eq 1 ]; then
	echo "==> Delegating to scripts/lib/build-deploy.sh for multi-arch build+push..."
	IMAGE="$IMAGE" \
	APP_DIR="$APP_DIR" \
	NEXT_PUBLIC_SITE_URL="$NEXT_PUBLIC_SITE_URL" \
	GHCR_USER="${GHCR_USER:-}" \
	GHCR_TOKEN="${GHCR_TOKEN:-}" \
	PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}" \
	./scripts/lib/build-deploy.sh

	# A multi-arch image built via buildx --push exists only in the
	# registry, never loaded into the local Docker engine (buildx can't
	# "docker load" more than one platform at once). Pull it back down so
	# 'docker compose up -d' below has a local image to actually run —
	# Docker will automatically select the layer matching this host's
	# native architecture from the manifest list.
	if [ "$NO_UP" -eq 0 ]; then
		echo "==> Pulling back native-arch layer to run locally..."
		docker compose pull web
	fi
else
	echo "==> Building images..."
	docker compose build

	if [ "$PUSH" -eq 1 ]; then
		echo "==> Pushing image: ${IMAGE}..."
		docker compose push web

		# Keep ":latest" pointing at the newest push while still preserving
		# this specific tag for rollback — skipped if IMAGE already is
		# tagged "latest".
		image_tag="${IMAGE##*:}"
		if [ "$image_tag" != "latest" ]; then
			latest_image="${IMAGE%:*}:latest"
			echo "==> Tagging and pushing ${latest_image}..."
			docker tag "$IMAGE" "$latest_image"
			docker push "$latest_image"
		fi
	fi
fi

if [ "$NO_UP" -eq 1 ]; then
	echo "==> --no-up set: skipping 'docker compose up -d' and health/cert checks. Image is ready; start the stack yourself when ready."
	exit 0
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
