#!/usr/bin/env bash
# Generic GHCR publisher — builds an image directly from a Dockerfile via
# `docker build`/`docker push` (no docker-compose required). Use this when
# you want raw Dockerfile-based builds for any project. If you specifically
# want this portfolio's docker-compose-based build (which wires in
# NEXT_PUBLIC_SITE_URL/APP_DIR build args), use ./publish-ghcr.sh instead.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Generic GHCR publisher (docker build + docker push, no docker-compose
required). Every setting below can come from three input sources, tried in
this order (first match wins):

  1. CLI flag        e.g. --username myuser
  2. Environment var  e.g. export GITHUB_USERNAME=myuser
     or .env file      same KEY=VALUE, read from --env-file/\$ENV_FILE_PATH
                       (default: .env.local, silently skipped if missing)
  3. Interactive prompt (only asked when stdin is a real terminal — never
     hangs in CI/non-interactive runs)
  4. Hardcoded default, or a hard error if the setting has no safe default

Options (CLI flag | env var / .env key | default):
  --username U          | GITHUB_USERNAME     | (none — required)
  --token PAT           | GITHUB_TOKEN        | (none — required)
  --repo REPO           | REPO_NAME           | (blank — optional, see below)
  --image-name NAME     | IMAGE_NAME          | (none — required)
  --tag TAG             | IMAGE_TAG           | latest
  --path PATH           | DOCKER_PATH         | .
  --build-args "K=V .." | BUILD_ARGS_INPUT    | (blank — optional)
  --env-file PATH       | ENV_FILE_PATH       | .env.local
  -h, --help            Show this help and exit

REPO_NAME is optional: leave it blank for a 2-segment image path
(ghcr.io/USERNAME/IMAGE_NAME:TAG) instead of 3-segment
(ghcr.io/USERNAME/REPO_NAME/IMAGE_NAME:TAG).

Examples:
  $0 --username myuser --image-name my-app --tag v1.2.0
  GITHUB_USERNAME=myuser GITHUB_TOKEN=ghp_xxx IMAGE_NAME=my-app $0   # no prompts
  $0 --env-file .env.prod

Security note: prefer passing GITHUB_TOKEN via a real environment variable
(or CI secret) rather than storing it in a file. If you do put it in
--env-file, keep that file out of version control (.env* is gitignored here).
EOF
}

USERNAME_ARG=""
TOKEN_ARG=""
REPO_ARG=""
IMAGE_NAME_ARG=""
IMAGE_TAG_ARG=""
DOCKER_PATH_ARG=""
BUILD_ARGS_ARG=""
ENV_FILE_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--username) USERNAME_ARG="${2:-}"; shift 2 ;;
		--username=*) USERNAME_ARG="${1#*=}"; shift ;;
		--token) TOKEN_ARG="${2:-}"; shift 2 ;;
		--token=*) TOKEN_ARG="${1#*=}"; shift ;;
		--repo) REPO_ARG="${2:-}"; shift 2 ;;
		--repo=*) REPO_ARG="${1#*=}"; shift ;;
		--image-name) IMAGE_NAME_ARG="${2:-}"; shift 2 ;;
		--image-name=*) IMAGE_NAME_ARG="${1#*=}"; shift ;;
		--tag) IMAGE_TAG_ARG="${2:-}"; shift 2 ;;
		--tag=*) IMAGE_TAG_ARG="${1#*=}"; shift ;;
		--path) DOCKER_PATH_ARG="${2:-}"; shift 2 ;;
		--path=*) DOCKER_PATH_ARG="${1#*=}"; shift ;;
		--build-args) BUILD_ARGS_ARG="${2:-}"; shift 2 ;;
		--build-args=*) BUILD_ARGS_ARG="${1#*=}"; shift ;;
		--env-file) ENV_FILE_ARG="${2:-}"; shift 2 ;;
		--env-file=*) ENV_FILE_ARG="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

# Optional dotenv-style file (.env.local/.env.prod/etc.) used as a fallback
# source, below real environment variables but above interactive prompts.
# Never overrides a CLI flag or an already-exported env var. Missing file is
# not an error — it's simply skipped.
ENV_FILE_PATH="${ENV_FILE_ARG:-${ENV_FILE_PATH:-.env.local}}"
env_file_var() {
	local key="$1"
	[ -f "$ENV_FILE_PATH" ] && grep -E "^${key}=" "$ENV_FILE_PATH" | tail -n1 | cut -d= -f2- || true
}

echo "=== GitHub Container Registry (GHCR) Publisher with ARGs ==="
[ -f "$ENV_FILE_PATH" ] && echo "==> Using settings file (fallback only): $ENV_FILE_PATH"
echo ""

# Each setting resolves as: CLI flag -> environment variable -> .env file ->
# interactive prompt (only in a real terminal) -> hardcoded default/error.
# This lets the script run fully non-interactively (CI) when flags/env vars
# are supplied, while still guiding a human through any gaps when run by hand.
GITHUB_USERNAME="${USERNAME_ARG:-${GITHUB_USERNAME:-$(env_file_var GITHUB_USERNAME)}}"
if [ -z "$GITHUB_USERNAME" ] && [ -t 0 ]; then
	read -p "Enter your GitHub Username: " GITHUB_USERNAME
fi
if [ -z "$GITHUB_USERNAME" ]; then
	echo "GitHub username is required (pass --username, set GITHUB_USERNAME, add it to $ENV_FILE_PATH, or run interactively)." >&2
	exit 1
fi

GITHUB_TOKEN="${TOKEN_ARG:-${GITHUB_TOKEN:-$(env_file_var GITHUB_TOKEN)}}"
if [ -z "$GITHUB_TOKEN" ] && [ -t 0 ]; then
	read -s -p "Enter your GitHub Personal Access Token (PAT): " GITHUB_TOKEN
	echo ""
fi
if [ -z "$GITHUB_TOKEN" ]; then
	echo "A PAT is required (pass --token, set GITHUB_TOKEN, add it to $ENV_FILE_PATH, or run interactively)." >&2
	exit 1
fi

REPO_NAME="${REPO_ARG:-${REPO_NAME:-$(env_file_var REPO_NAME)}}"
if [ -z "$REPO_NAME" ] && [ -t 0 ]; then
	read -p "Enter your GitHub Repository Name (optional, leave blank for 2-segment path): " REPO_NAME
fi

IMAGE_NAME="${IMAGE_NAME_ARG:-${IMAGE_NAME:-$(env_file_var IMAGE_NAME)}}"
if [ -z "$IMAGE_NAME" ] && [ -t 0 ]; then
	read -p "Enter your Docker Image Name (e.g., my-app): " IMAGE_NAME
fi
if [ -z "$IMAGE_NAME" ]; then
	echo "Image name is required (pass --image-name, set IMAGE_NAME, add it to $ENV_FILE_PATH, or run interactively)." >&2
	exit 1
fi

IMAGE_TAG="${IMAGE_TAG_ARG:-${IMAGE_TAG:-$(env_file_var IMAGE_TAG)}}"
if [ -z "$IMAGE_TAG" ] && [ -t 0 ]; then
	read -p "Enter your Image Tag [latest]: " IMAGE_TAG
fi
IMAGE_TAG="${IMAGE_TAG:-latest}"

DOCKER_PATH="${DOCKER_PATH_ARG:-${DOCKER_PATH:-$(env_file_var DOCKER_PATH)}}"
if [ -z "$DOCKER_PATH" ] && [ -t 0 ]; then
	read -p "Enter path to the folder containing the Dockerfile [.]: " DOCKER_PATH
fi
DOCKER_PATH="${DOCKER_PATH:-.}"

# Prompt for optional build arguments
BUILD_ARGS_INPUT="${BUILD_ARGS_ARG:-${BUILD_ARGS_INPUT:-$(env_file_var BUILD_ARGS_INPUT)}}"
if [ -z "$BUILD_ARGS_INPUT" ] && [ -t 0 ]; then
	read -p "Enter build arguments separated by space (e.g., VERSION=1.2.3 API_KEY=xyz) or leave blank: " BUILD_ARGS_INPUT
fi

# Construct build arguments flags dynamically
BUILD_ARGS_CMD=""
if [ -n "$BUILD_ARGS_INPUT" ]; then
    for arg in $BUILD_ARGS_INPUT; do
        BUILD_ARGS_CMD="$BUILD_ARGS_CMD --build-arg $arg"
    done
fi

# Construct the full image name (falls back to 2-segment path if REPO_NAME is blank)
if [ -n "$REPO_NAME" ]; then
    FULL_IMAGE="ghcr.io/$GITHUB_USERNAME/$REPO_NAME/$IMAGE_NAME:$IMAGE_TAG"
else
    FULL_IMAGE="ghcr.io/$GITHUB_USERNAME/$IMAGE_NAME:$IMAGE_TAG"
fi

echo ""
echo "Logging in to GitHub Container Registry..."
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin

echo ""
echo "Building Docker image: $FULL_IMAGE..."
# Note: Unquoted $BUILD_ARGS_CMD allows multiple flags to pass correctly
docker build $BUILD_ARGS_CMD -t "$FULL_IMAGE" "$DOCKER_PATH"

echo ""
echo "Pushing Docker image to GHCR..."
docker push "$FULL_IMAGE"

# Keep ":latest" pointing at the newest push while still preserving this
# specific tag for rollback — skipped if the user already chose "latest".
if [ "$IMAGE_TAG" != "latest" ]; then
    LATEST_IMAGE="${FULL_IMAGE%:*}:latest"
    echo ""
    echo "Tagging and pushing ${LATEST_IMAGE}..."
    docker tag "$FULL_IMAGE" "$LATEST_IMAGE"
    docker push "$LATEST_IMAGE"
fi

echo ""
echo "Successfully published: $FULL_IMAGE"
if [ "$IMAGE_TAG" != "latest" ]; then
    echo "Also published: ${FULL_IMAGE%:*}:latest"
fi

# How it handles Build Arguments:If you type VERSION=2.0 ENV=production when prompted,
# the script converts them into --build-arg VERSION=2.0 --build-arg ENV=production