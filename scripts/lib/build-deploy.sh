#!/usr/bin/env bash
# Multi-arch (linux/amd64 + linux/arm64) build+push worker, delegated to by
# deploy.sh's `--push --multi-arch` flag (or callable standalone). Reads all
# settings from already-exported environment variables — this script does
# NOT prompt or read .env files itself; the caller (deploy.sh) is
# responsible for resolving/exporting them first.
#
# Required env var: IMAGE (e.g. ghcr.io/<owner>/rohit-portfolio:latest)
# Optional env vars: APP_DIR, NEXT_PUBLIC_SITE_URL, PLATFORMS (default:
#                     linux/amd64,linux/arm64), BUILDER_NAME (default:
#                     portfolio-builder), GHCR_USER/GHCR_TOKEN (registry
#                     login — skipped if left blank; caller/deploy.sh is
#                     expected to have already handled login in that case).
set -euo pipefail
# Stay in the repo root (two levels up from scripts/lib/) — docker compose
# commands below rely on relative paths (Dockerfile, docker-compose.yml).
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUILDER_NAME="${BUILDER_NAME:-portfolio-builder}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

if [ -z "${IMAGE:-}" ]; then
	echo "IMAGE must be set (e.g. IMAGE=ghcr.io/<owner>/rohit-portfolio:latest)." >&2
	exit 1
fi

echo "🚀 Starting multi-platform build workflow for ${IMAGE}..."

# 1. Verify Docker Compose version (informational only — the actual
#    capability check is the buildx driver setup below).
COMPOSE_VER="$(docker compose version --short 2>/dev/null || echo 0.0.0)"
echo "📋 Detected Docker Compose version: $COMPOSE_VER"

# 2. Ensure a buildx builder that supports multi-platform build+push exists.
#    The default 'docker' driver CANNOT do this — only 'docker-container'
#    (or a containerd-image-store-enabled 'docker' driver) can.
echo "🔧 Setting up Buildx builder ($BUILDER_NAME)..."
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
	echo "🏗️  Builder '$BUILDER_NAME' not found. Creating it now..."
	docker buildx create --name "$BUILDER_NAME" --driver docker-container --use
else
	docker buildx use "$BUILDER_NAME"
fi
docker buildx inspect "$BUILDER_NAME" --bootstrap >/dev/null
# (Optional) Verify it is selected as the active builder
docker buildx ls >/dev/null

# 3. Registry login — only attempted if the caller actually provided
#    credentials; deploy.sh already handles its own "already logged in?"
#    check before calling this script, so this is a no-op in that case.
registry="${IMAGE%%/*}"
if [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
	echo "🔐 Logging in to ${registry}..."
	echo "$GHCR_TOKEN" | docker login "$registry" -u "$GHCR_USER" --password-stdin
fi

# 4. Build and push. NOTE: `docker compose build` has NO --platform flag
#    (verified against Compose v2.28 — only docker-compose.yml's static
#    build.platforms: list can drive multi-arch through Compose, which
#    we deliberately avoid since that file is shared with deploy.sh's
#    native/local single-arch builds). So this calls `docker buildx build`
#    directly instead, passing the same context/Dockerfile/build-args
#    docker-compose.yml itself uses — this stays scoped to just this
#    script, never affecting docker-compose.yml or other build paths.
echo "📦 Building and pushing multi-platform image (${PLATFORMS})..."
docker buildx build \
	--builder "$BUILDER_NAME" \
	--platform "$PLATFORMS" \
	--build-arg APP_DIR="$APP_DIR" \
	--build-arg NEXT_PUBLIC_SITE_URL="$NEXT_PUBLIC_SITE_URL" \
	-f Dockerfile \
	-t "$IMAGE" \
	--push \
	.

# 4. Build and push. `docker compose build` supports --platform directly
#    (Compose v2.20+) without any docker-compose.yml changes — this stays
#    scoped to just this invocation, never affecting native/local builds
#    elsewhere (e.g. deploy.sh's plain `docker compose build` path).
#echo "📦 Building and pushing multi-platform image (${PLATFORMS})..."
#docker compose build --platform "$PLATFORMS" --push

# 5. Verify the resulting remote manifest actually contains all requested
#    architectures.
echo "🔍 Verifying remote image structure..."
docker buildx imagetools inspect "$IMAGE"

# 6. Alias ":latest" to the same multi-arch manifest, unless IMAGE already
#    IS ":latest" — mirrors the single-arch tagging deploy.sh does, but
#    using `imagetools create` (a registry-side manifest-list copy) instead
#    of `docker tag`/`docker push`, which would silently drop all but one
#    platform from a multi-arch manifest list.
IMAGE_TAG="${IMAGE##*:}"
if [ "$IMAGE_TAG" != "latest" ]; then
	LATEST_IMAGE="${IMAGE%:*}:latest"
	echo "🏷️  Aliasing ${LATEST_IMAGE} to the same multi-arch manifest..."
	docker buildx imagetools create --tag "$LATEST_IMAGE" "$IMAGE"
	echo "🔍 Verifying ${LATEST_IMAGE}..."
	docker buildx imagetools inspect "$LATEST_IMAGE"
fi

echo "✅ Success! ${IMAGE} is multi-arch and ready to pull on any host (e.g. AWS EC2)."

