#!/usr/bin/env bash
###############################################################################
# Production bootstrap: common hardening + Node.js + Docker + GitHub repo sync
#
# Modular & idempotent. Designed for AWS EC2 (Amazon Linux 2/2023, Ubuntu/
# Debian). Run manually via SSH or AWS SSM Run Command — do NOT wire this to
# a shell logout hook in production.
#
# Toggle which modules run via environment variables (all default to true
# except REPO sync, which requires REPO_URL to be set):
#   INSTALL_COMMON_HARDENING=true
#   INSTALL_NODE=true
#   INSTALL_DOCKER=true
#   SYNC_REPO=true            (only runs if REPO_URL is set)
#
# Example — install everything:
#   sudo REPO_URL="git@github.com:org/app.git" ./prod-bootstrap.sh
#
# Example — only Docker, skip everything else:
#   sudo INSTALL_NODE=false SYNC_REPO=false ./prod-bootstrap.sh
###############################################################################
set -Eeuo pipefail

LOG_FILE="/var/log/prod-bootstrap.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "[ERROR] Failed at line $LINENO. See $LOG_FILE"; exit 1' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash $0"
  exit 1
fi

###############################################################################
# Configuration (override any of these via environment variables)
###############################################################################
DRY_RUN="${DRY_RUN:-false}"

# Module toggles
INSTALL_COMMON_HARDENING="${INSTALL_COMMON_HARDENING:-true}"
INSTALL_NODE="${INSTALL_NODE:-true}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
SYNC_REPO="${SYNC_REPO:-true}"

# Common / security settings
APP_USER="${APP_USER:-portfolio}"
SSH_PORT="${SSH_PORT:-22}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-yes}"

# Node.js settings
NODE_MAJOR="${NODE_MAJOR:-24}"  # e.g. 24 for Node.js 24.x

# Docker settings
DOCKER_COMPOSE_PLUGIN="${DOCKER_COMPOSE_PLUGIN:-true}"
CONFIGURE_DOCKER_DAEMON="${CONFIGURE_DOCKER_DAEMON:-true}"   # log rotation + live-restore
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"

# GitHub repo sync settings
GIT_BASE_URL="${GIT_BASE_URL:-https://github.com}"                       # e.g. https://github.com or
GITHUB_USERNAME="${GITHUB_USERNAME:-rohit-sahu}"  # e.g. org or your GitHub username
REPO_NAME="${REPO_NAME:-deploy-script}"                       # e.g. org/app or just app (if org is same as GITHUB_USERNAME)
REPO_URL="${GIT_BASE_URL}/${GITHUB_USERNAME}/${REPO_NAME}"                       # e.g. git@github.com:org/app.git or https://github.com/org/app.git
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DEST="${REPO_DEST:-/opt/${APP_USER}}"  # where to clone the repo on the host
REPO_DEPLOY_KEY="${REPO_DEPLOY_KEY:-/home/ubuntu/.ssh/id_ed25519}"          # path to an SSH deploy key file, optional

echo "[INFO] Starting production bootstrap at $(date -u)"
echo "[INFO] DRY_RUN=${DRY_RUN} | HARDENING=${INSTALL_COMMON_HARDENING} | NODE=${INSTALL_NODE} | DOCKER=${INSTALL_DOCKER} | SYNC_REPO=${SYNC_REPO}"

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# Writes $2 as the contents of file $1, respecting DRY_RUN (unlike a raw
# `echo ... > file` redirect, which would write unconditionally).
write_file() {
  local dest="$1"
  local content="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] would write to ${dest}:"
    echo "${content}"
  else
    echo "${content}" > "$dest"
  fi
}

###############################################################################
# OS detection (shared by all modules)
###############################################################################
detect_os() {
  echo "==> [system] Identifying host operating system"

  if [[ -f /etc/os-release ]]; then
    # Parse specific lines directly (not sourcing the file) to avoid executing
    # arbitrary shell code and to prevent polluting the global shell namespace
    # with every field in the file (NAME, PRETTY_NAME, VERSION_CODENAME, etc.).
    OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    OS_VERSION=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

    OS_ID="${OS_ID:-unknown}"
    OS_VERSION="${OS_VERSION:-unknown}"
  else
    echo "[ERROR] Mandatory /etc/os-release file not found. Cannot determine distribution."
    exit 1
  fi

  echo "[INFO] Detected OS: $OS_ID $OS_VERSION"
}

###############################################################################
# MODULE: common_setup — base packages + system update (always runs)
###############################################################################
module_common_setup() {
  echo "==> [common_setup] Updating system and installing base packages"
  case "$OS_ID" in
    amzn)
      if [[ "$OS_VERSION" == "2" ]]; then
        run yum update -y
        run yum install -y curl git unzip tar shadow-utils ca-certificates
      else
        run dnf update -y
        run dnf install -y curl git unzip tar shadow-utils ca-certificates
      fi
      ;;
    ubuntu|debian)
      run apt-get update -y
      DEBIAN_FRONTEND=noninteractive run apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
      run apt-get install -y curl git unzip tar ca-certificates gnupg lsb-release
      ;;
    *)
      echo "[ERROR] Unsupported OS: $OS_ID $OS_VERSION"
      exit 1
      ;;
  esac
}

module_create_app_user() {
  echo "==> [common_setup] Ensuring app user exists: $APP_USER"
  if ! id "$APP_USER" >/dev/null 2>&1; then
    run useradd --system --create-home --shell /bin/bash "$APP_USER"
    run passwd -l "$APP_USER" >/dev/null 2>&1 || true
    echo "[INFO] Created system user: $APP_USER"
  else
    echo "[INFO] User already exists: $APP_USER. Enforcing safe configuration."
    run usermod --shell /bin/bash "$APP_USER"
  fi
}

###############################################################################
# MODULE: common_hardening — SSH, firewall, fail2ban, sysctl, auto-updates
###############################################################################
module_secure_ssh() {
  echo "==> [hardening] Securing SSH"
  local sshd_config="/etc/ssh/sshd_config"
  local backup="${sshd_config}.bak.$(date +%s)"

  run cp "$sshd_config" "$backup"

  if [[ "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
    if ! grep -q "AuthorizedKeysFile" "$sshd_config"; then
      echo "[WARN] AuthorizedKeysFile not confirmed; skipping password-auth disable for safety."
    else
      run sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" "$sshd_config"
    fi
  fi

  run sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$sshd_config"
  run sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$sshd_config"
  run sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' "$sshd_config"
  run sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/' "$sshd_config"

  if grep -q '^#\?Port ' "$sshd_config"; then
    run sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" "$sshd_config"
  else
    run bash -c "echo 'Port ${SSH_PORT}' >> '${sshd_config}'"
  fi

  # If ufw is already active (e.g. re-running this script after changing
  # SSH_PORT), pre-allow the new port before restarting sshd. Otherwise
  # there's a window where sshd is listening on the new port but ufw (still
  # holding only the old port's allow rule from a previous run) would block
  # new connections until module_firewall runs afterward.
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "[INFO] ufw is active — pre-allowing new SSH port ${SSH_PORT}/tcp before restart."
    run ufw allow "${SSH_PORT}/tcp"
  fi

  if sshd -t; then
    echo "[INFO] sshd_config syntax OK. Restarting sshd."
    run systemctl restart sshd 2>/dev/null || run systemctl restart ssh
  else
    echo "[ERROR] sshd_config invalid. Restoring backup and aborting SSH changes."
    run cp "$backup" "$sshd_config"
    return 1
  fi
}

module_firewall() {
  echo "==> [hardening] Configuring firewall"
  case "$OS_ID" in
    ubuntu|debian)
      # 1. Install UFW if not present, allow SSH, HTTP, HTTPS, and enable it.
      run apt-get install -y ufw
      # 2. Reset UFW to default (blocks all inbound, allows outbound)
      run ufw --force reset
      run ufw default deny incoming
      run ufw default allow outgoing
      # 3. ALWAYS allow SSH first so you don't lock yourself out
      run ufw allow "${SSH_PORT}/tcp"
      # 4. Allow HTTP and HTTPS for web traffic
      run ufw allow 80/tcp
      run ufw allow 443/tcp
      # 5. Enable UFW (force yes to avoid interactive prompt)
      run ufw --force enable
      ;;
    amzn)
      echo "[INFO] Skipping host firewall on Amazon Linux. Use EC2 Security Groups/NACLs instead."
      ;;
  esac
}

module_fail2ban() {
  echo "==> [hardening] Enabling fail2ban"
  case "$OS_ID" in
    ubuntu|debian)
      run apt-get update -y
      run apt-get install -y fail2ban
      ;;
    amzn)
      if [[ "$OS_VERSION" == "2" ]]; then
        echo "--> Enabling EPEL repository for Amazon Linux 2"
        run amazon-linux-extras install epel -y
        run yum install -y fail2ban
      else
        run dnf install -y fail2ban
      fi
      ;;
    *)
      echo "[WARN] Unsupported OS_ID: $OS_ID. Skipping fail2ban."
      return 0
      ;;
  esac

  echo "--> Injecting default local SSH jail configuration"
  local jail_conf
  jail_conf="$(cat <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF
)"
  write_file /etc/fail2ban/jail.local "$jail_conf"

  run systemctl enable fail2ban
  run systemctl restart fail2ban
}

module_sysctl_hardening() {
  echo "==> [hardening] Applying kernel/network hardening"
  local sysctl_conf
  sysctl_conf="$(cat <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
kernel.randomize_va_space = 2

# --- Recommended Security Additions ---
# Ignore source-routed packets (prevents traffic routing manipulation)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignore secure ICMP redirects (prevents rogue router impersonation)
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Ignore all ICMP echoes/broadcasts to avoid network discovery/mapping
net.ipv4.icmp_echo_ignore_broadcasts = 1

# --- IPv6 Hardening (Highly recommended if IPv6 is enabled in your VPC) ---
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF
)"
  write_file /etc/sysctl.d/99-production-hardening.conf "$sysctl_conf"
  run sysctl --system
}

module_auto_updates() {
  echo "==> [hardening] Enabling automatic security updates"
  case "$OS_ID" in
    ubuntu|debian)
      run apt-get install -y unattended-upgrades
      run dpkg-reconfigure -f noninteractive unattended-upgrades
      ;;
    amzn)
      echo "[INFO] Consider AWS Systems Manager Patch Manager for Amazon Linux patching."
      ;;
  esac
}

run_common_hardening() {
  module_secure_ssh
  module_firewall
  module_fail2ban
  module_sysctl_hardening
  module_auto_updates
}

###############################################################################
# MODULE: node — Node.js + pm2
###############################################################################
run_install_node() {
  echo "==> [node] Installing Node.js ${NODE_MAJOR}.x"
  if command -v node >/dev/null 2>&1; then
    echo "[INFO] Node already installed: $(node -v). Skipping install."
  else
    case "$OS_ID" in
      amzn)
        curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | run bash -
        if [[ "$OS_VERSION" == "2" ]]; then run yum install -y nodejs; else run dnf install -y nodejs; fi
        ;;
      ubuntu|debian)
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | run bash -
        run apt-get install -y nodejs
        ;;
      *)
        echo "--> [Warning] Unsupported OS_ID: $OS_ID. Skipping Node.js installation."
        return 0
        ;;
    esac
  fi
  # Global installations may need root privileges depending on your execution context
  run npm install -g pm2
  # Output details safely for logging verification
  echo "--> Verification details:"
  node -v || true
  npm -v || true
  pm2 -v || true
}

###############################################################################
# MODULE: docker — Docker Engine + Compose plugin
###############################################################################

# Removes distro-provided Docker/Podman/containerd/runc packages that conflict
# with Docker's official docker-ce packages — but ONLY if any are actually
# installed. Safe/idempotent: does nothing on a clean instance.
purge_conflicting_docker_packages() {
  echo "==> [docker] Checking for conflicting container packages"
  case "$OS_ID" in
    ubuntu|debian)
      local conflicting_pkgs=("docker.io" "docker-doc" "docker-compose" "docker-compose-v2" "podman-docker" "containerd" "runc")
      local found_pkgs=()
      local pkg
      for pkg in "${conflicting_pkgs[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
          found_pkgs+=("$pkg")
        fi
      done
      if [[ ${#found_pkgs[@]} -eq 0 ]]; then
        echo "[INFO] No conflicting Debian/Ubuntu container packages found."
      else
        echo "[WARN] Found conflicting Debian packages: ${found_pkgs[*]}. Purging..."
        run apt-get purge -y "${found_pkgs[@]}"
        run apt-get autoremove -y
      fi
      ;;
    amzn)
      local conflicting_rpm_pkgs=("docker" "docker-client" "docker-client-latest" "docker-common" "docker-latest" "docker-latest-logrotate" "docker-logrotate" "docker-engine" "podman" "buildah")
      local found_rpm_pkgs=()
      local rpm_pkg
      for rpm_pkg in "${conflicting_rpm_pkgs[@]}"; do
        if rpm -q "$rpm_pkg" >/dev/null 2>&1; then
          found_rpm_pkgs+=("$rpm_pkg")
        fi
      done
      if [[ ${#found_rpm_pkgs[@]} -eq 0 ]]; then
        echo "[INFO] No conflicting Amazon Linux container packages found."
      else
        echo "[WARN] Found conflicting RPM packages: ${found_rpm_pkgs[*]}. Removing..."
        if [[ "$OS_VERSION" == "2" ]]; then
          run yum remove -y "${found_rpm_pkgs[@]}"
        else
          run dnf remove -y "${found_rpm_pkgs[@]}"
        fi
      fi
      ;;
    *)
      echo "[WARN] Unsupported OS_ID: $OS_ID. Skipping docker purge check."
      return 0
      ;;
  esac
}

# Returns success (0) if this system's apt/gpg toolchain supports ASCII-
# armored (.asc) keys directly in `signed-by=`, avoiding the need for
# `gpg --dearmor`. Modern apt (>= 2.4, e.g. Ubuntu 22.04+/Debian 12+)
# supports this; older systems (Ubuntu 20.04, Debian 11 and earlier) need a
# binary keyring. Detecting via the actual apt version (rather than a
# hardcoded codename list) keeps this working on future releases too.
apt_supports_asc_signed_by() {
  local apt_version major minor
  apt_version="$(apt-get --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$apt_version" ]]; then
    # Version couldn't be determined — fall back to the safer/older method.
    return 1
  fi
  # Compare major/minor as separate integers rather than a single float —
  # awk (and any float-based comparison) would misparse e.g. "2.10" as the
  # number 2.1, incorrectly treating it as older than 2.4.
  major="${apt_version%%.*}"
  minor="${apt_version#*.}"
  (( major > 2 || (major == 2 && minor >= 4) ))
}

# Configures /etc/docker/daemon.json with production-sensible defaults:
#   - log rotation (json-file driver, capped size/files) — prevents container
#     logs from silently filling up the disk over time.
#   - live-restore — keeps containers running if the Docker daemon itself is
#     restarted/upgraded, avoiding unnecessary app downtime.
# Safe to re-run: validates JSON before applying, backs up any existing
# config, and rolls back automatically if Docker fails to restart with the
# new config.
configure_docker_daemon() {
  echo "==> [docker] Configuring Docker daemon (log rotation, live-restore)"

  local daemon_json="/etc/docker/daemon.json"
  local backup="${daemon_json}.bak.$(date +%s)"
  local tmp_json
  tmp_json="$(mktemp)"

  run mkdir -p /etc/docker

  cat > "$tmp_json" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  },
  "live-restore": true
}
EOF

  # Validate JSON syntax before touching the real file.
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import json; json.load(open('${tmp_json}'))" >/dev/null 2>&1; then
      echo "[ERROR] Generated daemon.json is invalid JSON. Skipping Docker daemon config."
      rm -f "$tmp_json"
      return 1
    fi
  fi

  if [[ -f "$daemon_json" ]]; then
    echo "[INFO] Backing up existing daemon.json to $backup"
    run cp "$daemon_json" "$backup"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] would write the following to $daemon_json:"
    cat "$tmp_json"
    rm -f "$tmp_json"
    return 0
  fi

  cp "$tmp_json" "$daemon_json"
  rm -f "$tmp_json"

  run systemctl daemon-reload
  run systemctl enable docker

  if systemctl restart docker; then
    echo "[INFO] Docker daemon restarted successfully with new config."
  else
    echo "[ERROR] Docker failed to restart with new daemon.json. Restoring previous config."
    if [[ -f "$backup" ]]; then
      cp "$backup" "$daemon_json"
    else
      rm -f "$daemon_json"
    fi
    systemctl restart docker || true
    return 1
  fi
}

# Amazon Linux 2's `amazon-linux-extras install docker` has no
# docker-compose-plugin package in its repos, unlike every other OS branch
# here (which installs docker-compose-plugin via apt/dnf). Without this,
# `docker compose` silently doesn't exist on AL2, breaking anything (e.g.
# deploy.sh) that relies on it. Install the official plugin binary straight
# from Docker's GitHub releases instead. Idempotent: skips if already present.
install_compose_plugin_al2() {
  local plugin_dir="/usr/libexec/docker/cli-plugins"
  local plugin_path="${plugin_dir}/docker-compose"

  if [[ -x "$plugin_path" ]] || command -v docker-compose >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "[INFO] docker compose plugin already present. Skipping."
    return 0
  fi

  echo "==> [docker] Installing docker-compose-plugin binary for Amazon Linux 2"
  local arch compose_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) compose_arch="x86_64" ;;
    aarch64|arm64) compose_arch="aarch64" ;;
    *)
      echo "[WARN] Unsupported architecture '$arch' for docker-compose-plugin binary. Skipping."
      return 1
      ;;
  esac

  local compose_version="v2.29.7"
  local url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${compose_arch}"

  run mkdir -p "$plugin_dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] would download $url to $plugin_path and chmod +x"
    return 0
  fi
  curl -fsSL "$url" -o "$plugin_path"
  chmod +x "$plugin_path"
}

run_install_docker() {
  echo "==> [docker] Installing Docker Engine"
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker already installed: $(docker --version). Skipping install."
  else
    case "$OS_ID" in
      amzn)
        if [[ "$OS_VERSION" == "2" ]]; then
          # Amazon Linux 2 ships Docker via amazon-linux-extras
          run amazon-linux-extras install -y docker
        else
          # Amazon Linux 2023 / RHEL-family: use Docker's official repo
          run dnf install -y dnf-plugins-core
          run dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
          run dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
        ;;
      ubuntu|debian)
        purge_conflicting_docker_packages
        run install -m 0755 -d /etc/apt/keyrings

        local arch
        arch="$(dpkg --print-architecture)"
        local codename
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

        if apt_supports_asc_signed_by; then
          echo "[INFO] apt >= 2.4 detected — using ASCII-armored key (docker.asc)."
          curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | run tee /etc/apt/keyrings/docker.asc >/dev/null
          run chmod a+r /etc/apt/keyrings/docker.asc
          write_file /etc/apt/sources.list.d/docker.list \
            "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${codename} stable"
        else
          echo "[INFO] apt < 2.4 (older toolchain) detected — using dearmored binary key (docker.gpg)."
          curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | run gpg --dearmor -o /etc/apt/keyrings/docker.gpg
          run chmod a+r /etc/apt/keyrings/docker.gpg
          write_file /etc/apt/sources.list.d/docker.list \
            "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${codename} stable"
        fi

        run apt-get update -y
        run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    esac
  fi

  if [[ "$OS_ID" == "amzn" && "$OS_VERSION" == "2" && "$DOCKER_COMPOSE_PLUGIN" == "true" ]]; then
    install_compose_plugin_al2
  fi

  run systemctl enable --now docker

  if [[ "$CONFIGURE_DOCKER_DAEMON" == "true" ]]; then
    configure_docker_daemon
  else
    echo "[INFO] Skipping Docker daemon configuration (CONFIGURE_DOCKER_DAEMON=false)"
  fi

  # Let the app user run docker without sudo. Also proceed under DRY_RUN even
  # though the user may not really exist yet (its creation was only echoed by
  # module_create_app_user), so the dry-run preview still shows this step.
  if id "$APP_USER" >/dev/null 2>&1 || [[ "$DRY_RUN" == "true" ]]; then
    run usermod -aG docker "$APP_USER"
    echo "[INFO] Added $APP_USER to the docker group (re-login required for it to take effect)."
  fi

  docker --version || true
  if [[ "$DOCKER_COMPOSE_PLUGIN" == "true" ]]; then
    docker compose version || true
  fi
}

###############################################################################
# MODULE: repo_sync — clone or update a GitHub repository
###############################################################################
run_sync_repo() {
  if [[ -z "$REPO_URL" ]]; then
    echo "[WARN] SYNC_REPO=true but REPO_URL is not set. Skipping repo sync."
    return 0
  fi

  echo "==> [repo_sync] Syncing ${REPO_URL} (branch: ${REPO_BRANCH}) into ${REPO_DEST}"

  # Optional: use a dedicated deploy key instead of the default SSH agent/keys.
  local git_ssh_command=""
  if [[ -n "$REPO_DEPLOY_KEY" ]]; then
    if [[ ! -f "$REPO_DEPLOY_KEY" ]]; then
      echo "[ERROR] REPO_DEPLOY_KEY set to '$REPO_DEPLOY_KEY' but file not found."
      return 1
    fi
    run chmod 600 "$REPO_DEPLOY_KEY"
    git_ssh_command="ssh -i ${REPO_DEPLOY_KEY} -o StrictHostKeyChecking=accept-new"
  fi

  run mkdir -p "$(dirname "$REPO_DEST")"

  if [[ -d "${REPO_DEST}/.git" ]]; then
    echo "[INFO] Repo already cloned. Fetching latest changes."
    if [[ -n "$git_ssh_command" ]]; then
      GIT_SSH_COMMAND="$git_ssh_command" run git -C "$REPO_DEST" fetch origin "$REPO_BRANCH"
    else
      run git -C "$REPO_DEST" fetch origin "$REPO_BRANCH"
    fi
    run git -C "$REPO_DEST" checkout "$REPO_BRANCH"
    run git -C "$REPO_DEST" reset --hard "origin/${REPO_BRANCH}"
  else
    echo "[INFO] Cloning repo for the first time."
    if [[ -n "$git_ssh_command" ]]; then
      GIT_SSH_COMMAND="$git_ssh_command" run git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DEST"
    else
      run git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DEST"
    fi
  fi

  # Same DRY_RUN accommodation as above: proceed even if the user doesn't
  # really exist yet under a dry run, so this step is still previewed.
  if id "$APP_USER" >/dev/null 2>&1 || [[ "$DRY_RUN" == "true" ]]; then
    run chown -R "${APP_USER}:${APP_USER}" "$REPO_DEST"
  fi

  echo "[INFO] Repo synced at: $REPO_DEST"
  git -C "$REPO_DEST" log -1 --oneline || true
}

###############################################################################
# MAIN — orchestrates all modules based on toggles
###############################################################################
main() {
  detect_os
  module_common_setup
  module_create_app_user

  if [[ "$INSTALL_COMMON_HARDENING" == "true" ]]; then
    run_common_hardening
  else
    echo "[INFO] Skipping common_hardening module (INSTALL_COMMON_HARDENING=false)"
  fi

  if [[ "$INSTALL_NODE" == "true" ]]; then
    run_install_node
  else
    echo "[INFO] Skipping node module (INSTALL_NODE=false)"
  fi

  if [[ "$INSTALL_DOCKER" == "true" ]]; then
    run_install_docker
  else
    echo "[INFO] Skipping docker module (INSTALL_DOCKER=false)"
  fi

  if [[ "$SYNC_REPO" == "true" ]]; then
    run_sync_repo
  else
    echo "[INFO] Skipping repo_sync module (SYNC_REPO=false)"
  fi

  echo "[INFO] Bootstrap completed successfully at $(date -u)"
  echo "[INFO] App user: $APP_USER"
  echo "[INFO] Node version: $(node -v 2>/dev/null || echo 'not installed')"
  echo "[INFO] Docker version: $(docker --version 2>/dev/null || echo 'not installed')"
  echo "[INFO] Repo path: ${REPO_DEST} (synced: ${SYNC_REPO})"
  echo "[INFO] Full log: $LOG_FILE"
}

main
