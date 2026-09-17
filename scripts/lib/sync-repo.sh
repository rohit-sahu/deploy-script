#!/usr/bin/env bash
# Clones this repo to TARGET_DIR on a fresh host, or pulls latest if it
# already exists there. One job only — no Docker/secrets/compose logic here.
set -euo pipefail

REPO_URL="${REPO_URL:-}"
TARGET_DIR="${TARGET_DIR:-$HOME/portfolio-6}"
REPO_REF="${REPO_REF:-main}"

sync_repo() {
	if [ -d "$TARGET_DIR/.git" ]; then
		echo "==> $TARGET_DIR already a git checkout, pulling latest ${REPO_REF}..."
		git -C "$TARGET_DIR" fetch origin "$REPO_REF"
		git -C "$TARGET_DIR" checkout "$REPO_REF"
		git -C "$TARGET_DIR" pull --ff-only origin "$REPO_REF"
	else
		if [ -z "$REPO_URL" ]; then
			echo "REPO_URL is required to clone into $TARGET_DIR (it doesn't exist yet)." >&2
			return 1
		fi
		echo "==> Cloning $REPO_URL (${REPO_REF}) into $TARGET_DIR..."
		git clone --branch "$REPO_REF" --single-branch "$REPO_URL" "$TARGET_DIR"
	fi
	echo "==> Repo ready at $TARGET_DIR"
}

# Allow sourcing (for provision-ec2.sh) or direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	sync_repo
fi
