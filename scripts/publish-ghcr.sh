#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "=== GitHub Container Registry (GHCR) Publisher with ARGs ==="
echo ""

# Prompt for user inputs
read -p "Enter your GitHub Username: " GITHUB_USERNAME
read -s -p "Enter your GitHub Personal Access Token (PAT): " GITHUB_TOKEN
echo ""
read -p "Enter your GitHub Repository Name: " REPO_NAME
read -p "Enter your Docker Image Name (e.g., my-app): " IMAGE_NAME
read -p "Enter your Image Tag (default: latest): " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-latest}
read -p "Enter path to the folder containing the Dockerfile (default: current directory '.'): " DOCKER_PATH
DOCKER_PATH=${DOCKER_PATH:-.}

# Prompt for optional build arguments
read -p "Enter build arguments separated by space (e.g., VERSION=1.2.3 API_KEY=xyz) or leave blank: " BUILD_ARGS_INPUT

# Construct build arguments flags dynamically
BUILD_ARGS_CMD=""
if [ -n "$BUILD_ARGS_INPUT" ]; then
    for arg in $BUILD_ARGS_INPUT; do
        BUILD_ARGS_CMD="$BUILD_ARGS_CMD --build-arg $arg"
    done
fi

# Construct the full image name
FULL_IMAGE="ghcr.io/$GITHUB_USERNAME/$REPO_NAME/$IMAGE_NAME:$IMAGE_TAG"

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

echo ""
echo "Successfully published: $FULL_IMAGE"

# How it handles Build Arguments:If you type VERSION=2.0 ENV=production when prompted,
# the script converts them into --build-arg VERSION=2.0 --build-arg ENV=production