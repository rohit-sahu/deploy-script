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
#
# Example — restrict 80/443 to Cloudflare's IP ranges only (system-level
# enforcement to match nginx's CLOUDFLARE_PROXIED mode -- see
# docker-compose.yml/RUNNING.md's "Cloudflare proxied DNS" section):
#   sudo CLOUDFLARE_ONLY_WEB=true \
#        AWS_SECURITY_GROUP_ID="sg-0123456789abcdef0" \
#        ./prod-bootstrap.sh
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
# Pinned to match the container image's hardcoded runtime UID (see the
# `nextjs` user in ./Dockerfile: `adduser --system --uid 1001 nextjs`), so
# files owned by this host user (e.g. secrets/admin-users.json) are directly
# readable by the container process without loosening file permissions.
# Change this only if the Dockerfile's baked-in UID also changes.
APP_USER_UID="${APP_USER_UID:-1001}"
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

# Cloudflare-only web access (defense-in-depth alongside nginx's
# CLOUDFLARE_PROXIED mode -- see docker-compose.yml/RUNNING.md). When
# enabled, restricts inbound 80/443 to Cloudflare's published IP ranges
# instead of 0.0.0.0/0, both at the host firewall (ufw, Ubuntu/Debian) and
# optionally the EC2 Security Group itself (any OS, via aws cli).
CLOUDFLARE_ONLY_WEB="${CLOUDFLARE_ONLY_WEB:-false}"
CLOUDFLARE_IPS_V4_URL="${CLOUDFLARE_IPS_V4_URL:-https://www.cloudflare.com/ips-v4}"
CLOUDFLARE_IPS_V6_URL="${CLOUDFLARE_IPS_V6_URL:-https://www.cloudflare.com/ips-v6}"
# Weekly cron job that re-fetches Cloudflare's ranges and re-applies them --
# they rarely change, but this avoids silent drift over months/years.
CLOUDFLARE_REFRESH_CRON="${CLOUDFLARE_REFRESH_CRON:-true}"
# Optional: if set (and aws cli usable -- instance IAM role or configured
# credentials), also lock down the EC2 Security Group's 80/443 rules to
# Cloudflare's ranges. Required on Amazon Linux (host firewall is skipped
# there in favor of Security Groups); optional extra layer on Ubuntu/Debian.
AWS_SECURITY_GROUP_ID="${AWS_SECURITY_GROUP_ID:-}"

echo "[INFO] Starting production bootstrap at $(date -u)"
echo "[INFO] DRY_RUN=${DRY_RUN} | HARDENING=${INSTALL_COMMON_HARDENING} | NODE=${INSTALL_NODE} | DOCKER=${INSTALL_DOCKER} | SYNC_REPO=${SYNC_REPO}"

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
    # Drain any piped stdin (e.g. `curl ... | run bash -`) so the upstream
    # writer doesn't get SIGPIPE/"Failed writing body" when we don't
    # actually consume it — that would fail the pipeline under `pipefail`
    # and abort the whole script even in a dry run.
    if [[ ! -t 0 ]]; then
      cat >/dev/null
    fi
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
        # --allowerasing: AL2023 AMIs ship "curl-minimal", which conflicts
        # with the full "curl" package; erase-and-replace resolves it.
        run dnf install -y --allowerasing curl git unzip tar shadow-utils ca-certificates
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
  echo "==> [common_setup] Ensuring app user exists: $APP_USER (uid ${APP_USER_UID})"
  if ! id "$APP_USER" >/dev/null 2>&1; then
    # Fail fast (with a clear message) instead of useradd silently picking a
    # different free uid if APP_USER_UID is already taken by someone else --
    # that would silently defeat the whole point of pinning it.
    local existing_owner
    existing_owner="$(getent passwd "$APP_USER_UID" 2>/dev/null | cut -d: -f1 || true)"
    if [[ "$DRY_RUN" != "true" && -n "$existing_owner" ]]; then
      echo "[ERROR] uid ${APP_USER_UID} is already assigned to user '${existing_owner}'. Set APP_USER_UID to a free uid and re-run." >&2
      return 1
    fi
    run useradd --system --uid "$APP_USER_UID" --create-home --shell /bin/bash "$APP_USER"
    run passwd -l "$APP_USER" >/dev/null 2>&1 || true
    echo "[INFO] Created system user: $APP_USER (uid ${APP_USER_UID})"
  else
    echo "[INFO] User already exists: $APP_USER. Enforcing safe configuration."
    run usermod --shell /bin/bash "$APP_USER"

    local current_uid
    current_uid="$(id -u "$APP_USER" 2>/dev/null || true)"
    if [[ -n "$current_uid" && "$current_uid" != "$APP_USER_UID" ]]; then
      echo "[WARN] $APP_USER has uid ${current_uid}, not the expected ${APP_USER_UID}."
      echo "[WARN] Container-mounted secrets (e.g. admin_users) may be unreadable by the app's in-container user until this matches."
      echo "[WARN] To fix (stops services relying on this uid first -- review before running):"
      echo "[WARN]   usermod -u ${APP_USER_UID} ${APP_USER} && groupmod -g ${APP_USER_UID} ${APP_USER} 2>/dev/null || true"
      echo "[WARN]   find / -xdev -user ${current_uid} -exec chown -h ${APP_USER_UID} {} \\; 2>/dev/null"
      echo "[WARN] Not applying this automatically -- it can affect files outside this script's control."
    fi
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

# Downloads Cloudflare's current published IPv4+IPv6 ranges, one CIDR per
# line. Read-only (never mutates anything), so it always runs for real even
# under DRY_RUN -- callers decide what to do with the result.
fetch_cloudflare_ranges() {
  local v4 v6
  v4="$(curl -fsSL "$CLOUDFLARE_IPS_V4_URL" 2>/dev/null || true)"
  v6="$(curl -fsSL "$CLOUDFLARE_IPS_V6_URL" 2>/dev/null || true)"
  if [[ -z "$v4" && -z "$v6" ]]; then
    echo "[ERROR] Could not fetch Cloudflare IP ranges from ${CLOUDFLARE_IPS_V4_URL}/${CLOUDFLARE_IPS_V6_URL}." >&2
    return 1
  fi
  printf '%s\n%s\n' "$v4" "$v6" | grep -E '^[0-9a-fA-F:.]+/[0-9]+$'
}

# Adds one 'ufw allow from <cidr> to any port 80,443 proto tcp' rule per
# Cloudflare range instead of a single 0.0.0.0/0 rule -- so only Cloudflare's
# edge (not the whole internet) can reach the web ports directly on this
# host. Falls back to allowing from anywhere (with a clear warning) if the
# ranges can't be fetched, so a transient network blip during bootstrap
# never leaves the site completely unreachable.
apply_cloudflare_ufw_rules() {
  local ranges
  if ! ranges="$(fetch_cloudflare_ranges)"; then
    echo "[WARN] Falling back to allowing 80/443 from anywhere (0.0.0.0/0) -- could not fetch Cloudflare ranges." >&2
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    return 0
  fi
  local cidr
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    run ufw allow from "$cidr" to any port 80,443 proto tcp
  done <<< "$ranges"
}

# Installs AWS CLI v2 (official installer -- works identically on
# Ubuntu/Debian/Amazon Linux, unlike distro packages which are often an
# outdated v1) when it's missing but needed. Best-effort: on failure, prints
# a warning and returns non-zero so the caller can skip Security Group
# management instead of aborting the whole bootstrap.
ensure_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] aws cli not found -- installing it (needed to manage Security Group ${AWS_SECURITY_GROUP_ID})."

  local arch
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
      echo "[WARN] Unsupported architecture for aws cli auto-install: $(uname -m). Install aws cli manually." >&2
      return 1
      ;;
  esac

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if ! run curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "${tmp_dir}/awscliv2.zip"; then
    echo "[WARN] Failed to download aws cli installer." >&2
    rm -rf "$tmp_dir"
    return 1
  fi
  run unzip -q -o "${tmp_dir}/awscliv2.zip" -d "$tmp_dir"
  run "${tmp_dir}/aws/install" --update
  rm -rf "$tmp_dir"

  if command -v aws >/dev/null 2>&1; then
    echo "[INFO] aws cli installed: $(aws --version 2>&1)"
    return 0
  fi
  echo "[WARN] aws cli installation appears to have failed." >&2
  return 1
}

# Optionally also locks down the EC2 Security Group itself to Cloudflare's
# ranges (works regardless of OS_ID -- required on Amazon Linux, where the
# host firewall step is skipped in favor of Security Groups/NACLs). Requires
# AWS_SECURITY_GROUP_ID to be set and the aws cli to be usable (instance IAM
# role, or credentials already configured) -- auto-installs the aws cli if
# missing; silently skipped (with a clear message) if that install fails,
# since this is optional/best-effort.
module_cloudflare_security_group() {
  if [[ -z "$AWS_SECURITY_GROUP_ID" ]]; then
    echo "[INFO] AWS_SECURITY_GROUP_ID not set -- skipping automatic EC2 Security Group management."
    echo "[INFO] Restrict 80/443 to Cloudflare's ranges manually in the AWS console/CLI (see RUNNING.md)."
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1 && ! ensure_aws_cli; then
    echo "[WARN] aws cli not available -- cannot manage Security Group ${AWS_SECURITY_GROUP_ID} automatically." >&2
    return 0
  fi

  local ranges
  if ! ranges="$(fetch_cloudflare_ranges)"; then
    echo "[WARN] Could not fetch Cloudflare ranges -- leaving Security Group ${AWS_SECURITY_GROUP_ID} unchanged." >&2
    return 0
  fi

  echo "==> [hardening] Restricting Security Group ${AWS_SECURITY_GROUP_ID}'s 80/443 rules to Cloudflare's IP ranges"

  # Remove any existing wide-open 0.0.0.0/0 / ::/0 rules for 80/443 first --
  # best-effort, ignore failures (e.g. the rule doesn't exist).
  local port
  for port in 80 443; do
    run aws ec2 revoke-security-group-ingress --group-id "$AWS_SECURITY_GROUP_ID" --protocol tcp --port "$port" --cidr 0.0.0.0/0 2>/dev/null || true
    run aws ec2 revoke-security-group-ingress --group-id "$AWS_SECURITY_GROUP_ID" --protocol tcp --port "$port" --cidr ::/0 2>/dev/null || true
  done

  local cidr
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    for port in 80 443; do
      if [[ "$cidr" == *:* ]]; then
        run aws ec2 authorize-security-group-ingress --group-id "$AWS_SECURITY_GROUP_ID" \
          --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},Ipv6Ranges=[{CidrIpv6=${cidr}}]" 2>/dev/null || true
      else
        run aws ec2 authorize-security-group-ingress --group-id "$AWS_SECURITY_GROUP_ID" --protocol tcp --port "$port" --cidr "$cidr" 2>/dev/null || true
      fi
    done
  done <<< "$ranges"

  echo "[INFO] Security Group ${AWS_SECURITY_GROUP_ID} now restricts 80/443 to Cloudflare's published ranges."
}

# Installs a weekly cron job that re-fetches Cloudflare's ranges and
# re-applies both the ufw rules (Ubuntu/Debian) and the Security Group rules
# (if AWS_SECURITY_GROUP_ID was set) -- self-contained (doesn't re-invoke
# this whole bootstrap script, which would also re-run apt upgrades/SSH
# restarts/etc. weekly). SSH_PORT/AWS_SECURITY_GROUP_ID are baked in at
# install time from this run's resolved values.
# Installs the cron/cronie package (and enables+starts its service) when
# `crontab` isn't already present -- both the Debian "cron" package and the
# RHEL-family "cronie" package provide /usr/bin/crontab, so checking for it
# works as a simple cross-distro proxy for "a cron daemon is installed."
ensure_cron_installed() {
  if command -v crontab >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] crontab not found -- installing a cron daemon."
  case "$OS_ID" in
    ubuntu|debian)
      run apt-get install -y cron
      run systemctl enable cron
      run systemctl restart cron
      ;;
    amzn)
      if [[ "$OS_VERSION" == "2" ]]; then
        run yum install -y cronie
      else
        run dnf install -y cronie
      fi
      run systemctl enable crond
      run systemctl restart crond
      ;;
    *)
      echo "[WARN] Unsupported OS_ID: $OS_ID. Install a cron daemon manually so the refresh job can run." >&2
      ;;
  esac
}

install_cloudflare_refresh_cron() {
  echo "==> [hardening] Installing weekly Cloudflare IP-range refresh cron job"
  ensure_cron_installed
  local script_path="/usr/local/bin/refresh-cloudflare-fw.sh"
  local has_ufw="false"
  command -v ufw >/dev/null 2>&1 && has_ufw="true"

  local refresh_script
  refresh_script="$(cat <<EOF
#!/usr/bin/env bash
# Auto-generated by prod-bootstrap.sh -- re-applies Cloudflare-only web
# access using the latest published IP ranges. Safe to re-run.
set -Eeuo pipefail
SSH_PORT="${SSH_PORT}"
AWS_SECURITY_GROUP_ID="${AWS_SECURITY_GROUP_ID}"
HAS_UFW="${has_ufw}"

ranges="\$( { curl -fsSL https://www.cloudflare.com/ips-v4; curl -fsSL https://www.cloudflare.com/ips-v6; } 2>/dev/null | grep -E '^[0-9a-fA-F:.]+/[0-9]+\$' )"
if [[ -z "\$ranges" ]]; then
  echo "[ERROR] Could not fetch Cloudflare IP ranges; leaving firewall unchanged." >&2
  exit 1
fi

if [[ "\$HAS_UFW" == "true" ]]; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "\${SSH_PORT}/tcp"
  while IFS= read -r cidr; do
    [[ -z "\$cidr" ]] && continue
    ufw allow from "\$cidr" to any port 80,443 proto tcp
  done <<< "\$ranges"
  ufw --force enable
  echo "[INFO] ufw Cloudflare-only rules refreshed at \$(date -u)"
fi

if [[ -n "\$AWS_SECURITY_GROUP_ID" ]] && command -v aws >/dev/null 2>&1; then
  for port in 80 443; do
    aws ec2 revoke-security-group-ingress --group-id "\$AWS_SECURITY_GROUP_ID" --protocol tcp --port "\$port" --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 revoke-security-group-ingress --group-id "\$AWS_SECURITY_GROUP_ID" --protocol tcp --port "\$port" --cidr ::/0 2>/dev/null || true
  done
  while IFS= read -r cidr; do
    [[ -z "\$cidr" ]] && continue
    for port in 80 443; do
      if [[ "\$cidr" == *:* ]]; then
        aws ec2 authorize-security-group-ingress --group-id "\$AWS_SECURITY_GROUP_ID" \\
          --ip-permissions "IpProtocol=tcp,FromPort=\${port},ToPort=\${port},Ipv6Ranges=[{CidrIpv6=\${cidr}}]" 2>/dev/null || true
      else
        aws ec2 authorize-security-group-ingress --group-id "\$AWS_SECURITY_GROUP_ID" --protocol tcp --port "\$port" --cidr "\$cidr" 2>/dev/null || true
      fi
    done
  done <<< "\$ranges"
  echo "[INFO] Security Group \$AWS_SECURITY_GROUP_ID Cloudflare-only rules refreshed at \$(date -u)"
fi

if [[ -x /usr/local/bin/docker-user-cloudflare-fw.sh ]]; then
  /usr/local/bin/docker-user-cloudflare-fw.sh || true
fi
EOF
)"
  write_file "$script_path" "$refresh_script"
  run chmod +x "$script_path"

  local cron_line="0 3 * * 0 root ${script_path} >> /var/log/cloudflare-fw-refresh.log 2>&1"
  write_file /etc/cron.d/cloudflare-fw-refresh "$cron_line"
  run chmod 644 /etc/cron.d/cloudflare-fw-refresh

  echo "[INFO] Weekly refresh installed: /etc/cron.d/cloudflare-fw-refresh (runs ${script_path})"
}

# Docker's *published* container ports (docker-compose `ports:`, e.g. nginx's
# 80/443) completely bypass ufw. Docker manages port publishing via its own
# iptables rules in the FORWARD chain (a "DOCKER-FORWARD" jump target that it
# inserts *before* ufw's own forward-chain rules are ever consulted) -- so
# `ufw status` can show perfectly correct Cloudflare-only rules while direct
# public-IP access to the app still works fine, because those rules are
# never actually reached for Docker-published ports. `DOCKER-USER` is a
# chain Docker creates specifically so admins can add their own filtering,
# and it runs *first* in the FORWARD chain (before DOCKER-FORWARD) -- so
# rules placed there DO take priority over Docker's own forwarding rules.
# This only matters on Ubuntu/Debian, where ufw is the host-level layer;
# Amazon Linux relies solely on the Security Group, which filters at the
# VPC/hypervisor level and is never bypassed by the guest's own iptables.
#
# Writes a small, self-contained, idempotent script that rebuilds only the
# DOCKER-USER rules it manages (tagged with a "cf-fw-managed" comment,
# leaving any other custom DOCKER-USER rules alone), runs it once immediately
# (best-effort -- gracefully skips if Docker/DOCKER-USER isn't ready yet),
# and installs a systemd unit so the rules are re-applied after every boot
# (Docker recreates an empty DOCKER-USER chain whenever docker.service
# (re)starts, wiping anything added here). The weekly Cloudflare refresh
# cron (install_cloudflare_refresh_cron) also re-invokes this same script,
# so IP-range updates and self-healing happen automatically.
module_docker_user_firewall() {
  echo "==> [hardening] Restricting Docker-published ports (80/443) to Cloudflare's ranges (DOCKER-USER chain)"

  local script_path="/usr/local/bin/docker-user-cloudflare-fw.sh"
  local docker_fw_script
  docker_fw_script="$(cat <<'EOF'
#!/usr/bin/env bash
# Auto-generated by prod-bootstrap.sh -- restricts Docker's published ports
# (80/443) to Cloudflare's IP ranges via the DOCKER-USER iptables chain.
# Safe to re-run: only rebuilds the rules this script manages (tagged with
# the "cf-fw-managed" comment), leaving any other DOCKER-USER rules intact.
set -Eeuo pipefail

log() { echo "[docker-user-cloudflare-fw] $*"; }

if ! command -v iptables >/dev/null 2>&1 || ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  log "DOCKER-USER chain not found (Docker not installed/running yet) -- skipping. Will retry via systemd unit / weekly cron."
  exit 0
fi

ranges="$( { curl -fsSL https://www.cloudflare.com/ips-v4; curl -fsSL https://www.cloudflare.com/ips-v6; } 2>/dev/null | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' )"
if [[ -z "$ranges" ]]; then
  log "Could not fetch Cloudflare IP ranges -- leaving existing DOCKER-USER rules unchanged."
  exit 1
fi

remove_tagged_rules() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || return 0
  local line
  while :; do
    line="$("$cmd" -L DOCKER-USER -n --line-numbers 2>/dev/null | grep 'cf-fw-managed' | tail -1 | awk '{print $1}')" || true
    [[ -z "$line" ]] && break
    "$cmd" -D DOCKER-USER "$line"
  done
}
remove_tagged_rules iptables
remove_tagged_rules ip6tables

# Order (each -I inserts at position 1, so build bottom-up conceptually):
# established/related first, then per-CIDR allow, then a final drop for
# 80/443, then a catch-all RETURN so all other forwarded traffic (container
# egress, non-80/443 published ports, etc.) is unaffected.
iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment cf-fw-managed -j RETURN
command -v ip6tables >/dev/null 2>&1 && ip6tables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment cf-fw-managed -j RETURN

while IFS= read -r cidr; do
  [[ -z "$cidr" ]] && continue
  if [[ "$cidr" == *:* ]]; then
    command -v ip6tables >/dev/null 2>&1 && ip6tables -I DOCKER-USER -p tcp -m multiport --dports 80,443 -s "$cidr" -m comment --comment cf-fw-managed -j RETURN
  else
    iptables -I DOCKER-USER -p tcp -m multiport --dports 80,443 -s "$cidr" -m comment --comment cf-fw-managed -j RETURN
  fi
done <<< "$ranges"

iptables -A DOCKER-USER -p tcp -m multiport --dports 80,443 -m comment --comment cf-fw-managed -j DROP
command -v ip6tables >/dev/null 2>&1 && ip6tables -A DOCKER-USER -p tcp -m multiport --dports 80,443 -m comment --comment cf-fw-managed -j DROP
iptables -A DOCKER-USER -m comment --comment cf-fw-managed -j RETURN
command -v ip6tables >/dev/null 2>&1 && ip6tables -A DOCKER-USER -m comment --comment cf-fw-managed -j RETURN

log "DOCKER-USER chain refreshed at $(date -u) -- ports 80/443 restricted to Cloudflare's ranges."
EOF
)"
  write_file "$script_path" "$docker_fw_script"
  run chmod +x "$script_path"

  # Apply immediately if Docker's DOCKER-USER chain already exists (typical
  # case: Docker was already installed before this run). If Docker hasn't
  # been installed yet in this same bootstrap run, this is a graceful no-op
  # (see the script's own DOCKER-USER-chain check) -- the systemd unit below
  # and the post-docker-install re-invocation in main() cover that case.
  run "$script_path" || echo "[WARN] Could not apply DOCKER-USER rules yet -- will retry via systemd unit / weekly cron." >&2

  local unit_path="/etc/systemd/system/docker-user-cloudflare-fw.service"
  local unit_content
  unit_content="$(cat <<EOF
[Unit]
Description=Restrict Docker-published ports (80/443) to Cloudflare IP ranges
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${script_path}

[Install]
WantedBy=multi-user.target
EOF
)"
  write_file "$unit_path" "$unit_content"
  run systemctl daemon-reload
  run systemctl enable docker-user-cloudflare-fw.service
  run systemctl start docker-user-cloudflare-fw.service || true

  echo "[INFO] DOCKER-USER Cloudflare restriction installed (script: ${script_path}, systemd unit: docker-user-cloudflare-fw.service -- re-applies after every reboot)."
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
      # 4. Allow HTTP and HTTPS for web traffic -- restricted to Cloudflare's
      #    ranges if CLOUDFLARE_ONLY_WEB=true (matches nginx's
      #    CLOUDFLARE_PROXIED mode -- see docker-compose.yml/RUNNING.md),
      #    otherwise open to everyone as before.
      if [[ "$CLOUDFLARE_ONLY_WEB" == "true" ]]; then
        echo "[INFO] CLOUDFLARE_ONLY_WEB=true -- restricting 80/443 to Cloudflare's published IP ranges instead of 0.0.0.0/0."
        apply_cloudflare_ufw_rules
      else
        run ufw allow 80/tcp
        run ufw allow 443/tcp
      fi
      # 5. Enable UFW (force yes to avoid interactive prompt)
      run ufw --force enable
      ;;
    amzn)
      echo "[INFO] Skipping host firewall on Amazon Linux. Use EC2 Security Groups/NACLs instead."
      if [[ "$CLOUDFLARE_ONLY_WEB" == "true" && -z "$AWS_SECURITY_GROUP_ID" ]]; then
        echo "[WARN] CLOUDFLARE_ONLY_WEB=true on Amazon Linux but AWS_SECURITY_GROUP_ID is not set -- nothing will actually be restricted. Set AWS_SECURITY_GROUP_ID, or restrict 80/443 to Cloudflare's ranges manually." >&2
      fi
      ;;
  esac

  if [[ "$CLOUDFLARE_ONLY_WEB" == "true" ]]; then
    module_cloudflare_security_group
    if [[ "$CLOUDFLARE_REFRESH_CRON" == "true" ]]; then
      install_cloudflare_refresh_cron
    fi
    # Docker bypasses ufw for published ports (see module_docker_user_firewall
    # docstring above) -- only relevant where ufw is actually the host-level
    # layer (Ubuntu/Debian). Amazon Linux relies solely on the Security Group,
    # which Docker's iptables rules can never bypass.
    case "$OS_ID" in
      ubuntu|debian) module_docker_user_firewall ;;
    esac
  fi
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

  # Root (running this whole script) doesn't own $REPO_DEST once it's chowned
  # to $APP_USER by a prior run — git refuses to operate on a repo owned by a
  # different user ("dubious ownership") unless explicitly marked safe. Pass
  # it inline per-invocation rather than mutating root's global .gitconfig.
  local git_safe_dir=(-c "safe.directory=${REPO_DEST}")

  if [[ -d "${REPO_DEST}/.git" ]]; then
    echo "[INFO] Repo already cloned. Fetching latest changes."
    if [[ -n "$git_ssh_command" ]]; then
      GIT_SSH_COMMAND="$git_ssh_command" run git "${git_safe_dir[@]}" -C "$REPO_DEST" fetch origin "$REPO_BRANCH"
    else
      run git "${git_safe_dir[@]}" -C "$REPO_DEST" fetch origin "$REPO_BRANCH"
    fi
    run git "${git_safe_dir[@]}" -C "$REPO_DEST" checkout "$REPO_BRANCH"
    run git "${git_safe_dir[@]}" -C "$REPO_DEST" reset --hard "origin/${REPO_BRANCH}"
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
  git "${git_safe_dir[@]}" -C "$REPO_DEST" log -1 --oneline || true
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

  # Re-apply the DOCKER-USER Cloudflare-only rules now that Docker is
  # guaranteed to be installed (if it wasn't yet when module_firewall ran
  # earlier in this same bootstrap -- e.g. a fresh instance running hardening
  # + Docker install in one go -- the first attempt inside module_firewall
  # would have gracefully skipped since Docker's DOCKER-USER chain didn't
  # exist yet). Idempotent/cheap to re-run even if it already succeeded.
  if [[ "$CLOUDFLARE_ONLY_WEB" == "true" ]]; then
    case "$OS_ID" in
      ubuntu|debian) module_docker_user_firewall ;;
    esac
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
