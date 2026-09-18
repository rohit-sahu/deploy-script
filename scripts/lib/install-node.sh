#!/usr/bin/env bash
# Installs Node.js (needed only to run scripts/node/create-admin.mjs and
# scripts/node/create-cloudflare-tunnel-token.mjs on the host — the app itself
# runs from the pulled Docker image, not from Node on this machine).
# Idempotent — safe to re-run. Supports Amazon Linux 2/2023 and Ubuntu/Debian.
set -euo pipefail

NODE_MAJOR="${NODE_MAJOR:-20}"

install_node() {
	if command -v node >/dev/null 2>&1; then
		local major
		major="$(node -e 'console.log(process.versions.node.split(".")[0])')"
		if [ "$major" -ge "$NODE_MAJOR" ]; then
			echo "==> Node $(node --version) already installed, skipping."
			return 0
		fi
	fi

	if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
		echo "Need root or sudo to install Node." >&2
		return 1
	fi
	local as_root=""
	[ "$(id -u)" -ne 0 ] && as_root="sudo"

	if [ -f /etc/os-release ]; then
		. /etc/os-release
	else
		echo "Cannot detect OS (/etc/os-release missing)." >&2
		return 1
	fi

	case "${ID:-}" in
		amzn)
			echo "==> Installing Node ${NODE_MAJOR} via dnf (Amazon Linux)..."
			$as_root dnf install -y "nodejs${NODE_MAJOR}" 2>/dev/null || $as_root dnf install -y nodejs
			;;
		ubuntu|debian)
			echo "==> Installing Node ${NODE_MAJOR} via NodeSource (${ID})..."
			curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | $as_root bash -
			$as_root apt-get install -y nodejs
			;;
		*)
			echo "Unsupported OS: ${ID:-unknown}. Install Node ${NODE_MAJOR}+ manually." >&2
			return 1
			;;
	esac

	echo "==> Node installed: $(node --version)"
}

# Allow sourcing (for provision-ec2.sh) or direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	install_node
fi
