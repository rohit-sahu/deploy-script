#!/usr/bin/env bash
# Installs Docker Engine + the compose plugin on a fresh EC2 instance.
# Idempotent — safe to re-run, skips steps that are already done.
# Supports Amazon Linux 2/2023 (dnf/yum) and Ubuntu/Debian (apt).
set -euo pipefail

install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		echo "==> Docker + compose plugin already installed, skipping."
		return 0
	fi

	if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
		echo "Need root or sudo to install Docker." >&2
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
			echo "==> Installing Docker via dnf/yum (Amazon Linux)..."
			$as_root dnf install -y docker 2>/dev/null || $as_root yum install -y docker
			$as_root systemctl enable --now docker
			# Amazon Linux's docker package doesn't ship the compose plugin —
			# install it as a CLI plugin instead of the standalone binary.
			local plugin_dir="/usr/libexec/docker/cli-plugins"
			$as_root mkdir -p "$plugin_dir"
			$as_root curl -fsSL \
				"https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
				-o "$plugin_dir/docker-compose"
			$as_root chmod +x "$plugin_dir/docker-compose"
			;;
		ubuntu|debian)
			echo "==> Installing Docker via apt (${ID})..."
			$as_root apt-get update -y
			$as_root apt-get install -y ca-certificates curl
			$as_root install -m 0755 -d /etc/apt/keyrings
			$as_root curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
			$as_root chmod a+r /etc/apt/keyrings/docker.asc
			echo \
				"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
				| $as_root tee /etc/apt/sources.list.d/docker.list > /dev/null
			$as_root apt-get update -y
			$as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
			$as_root systemctl enable --now docker
			;;
		*)
			echo "Unsupported OS: ${ID:-unknown}. Install Docker + the compose plugin manually." >&2
			return 1
			;;
	esac

	if [ -n "$as_root" ] && ! id -nG "$USER" | grep -qw docker; then
		$as_root usermod -aG docker "$USER"
		echo "==> Added $USER to the docker group — log out/in (or run 'newgrp docker') for it to take effect."
	fi

	echo "==> Docker installed: $(docker --version)"
	echo "==> Compose plugin installed: $(docker compose version)"
}

# Allow sourcing (for provision-ec2.sh) or direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	install_docker
fi
