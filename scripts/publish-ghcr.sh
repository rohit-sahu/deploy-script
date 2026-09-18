#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "=== GitHub Container Registry (GHCR) Publisher with ARGs ==="
echo ""

# Prompt for user inputs. Each falls back to an already-exported environment
# variable of the same name (e.g. set by CI) when left blank, and finally to
# a hardcoded default where one makes sense — so this script works both
# interactively and non-interactively without editing it.
read -p "Enter your GitHub Username${GITHUB_USERNAME:+ [$GITHUB_USERNAME]}: " INPUT_USERNAME
GITHUB_USERNAME="${INPUT_USERNAME:-${GITHUB_USERNAME:-}}"
read -s -p "Enter your GitHub Personal Access Token (PAT)${GITHUB_TOKEN:+ [using \$GITHUB_TOKEN from environment]}: " INPUT_TOKEN
echo ""
GITHUB_TOKEN="${INPUT_TOKEN:-${GITHUB_TOKEN:-}}"
read -p "Enter your GitHub Repository Name (optional, leave blank for 2-segment path)${REPO_NAME:+ [$REPO_NAME]}: " INPUT_REPO_NAME
REPO_NAME="${INPUT_REPO_NAME:-${REPO_NAME:-}}"
read -p "Enter your Docker Image Name (e.g., my-app)${IMAGE_NAME:+ [$IMAGE_NAME]}: " INPUT_IMAGE_NAME
IMAGE_NAME="${INPUT_IMAGE_NAME:-${IMAGE_NAME:-}}"
read -p "Enter your Image Tag [${IMAGE_TAG:-latest}]: " INPUT_IMAGE_TAG
IMAGE_TAG="${INPUT_IMAGE_TAG:-${IMAGE_TAG:-latest}}"
read -p "Enter path to the folder containing the Dockerfile [${DOCKER_PATH:-.}]: " INPUT_DOCKER_PATH
DOCKER_PATH="${INPUT_DOCKER_PATH:-${DOCKER_PATH:-.}}"

# Prompt for optional build arguments
read -p "Enter build arguments separated by space (e.g., VERSION=1.2.3 API_KEY=xyz)${BUILD_ARGS_INPUT:+ [$BUILD_ARGS_INPUT]} or leave blank: " INPUT_BUILD_ARGS
BUILD_ARGS_INPUT="${INPUT_BUILD_ARGS:-${BUILD_ARGS_INPUT:-}}"

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