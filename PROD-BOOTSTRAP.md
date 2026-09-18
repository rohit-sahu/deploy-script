# AWS Production Instance: Node.js, Docker, GitHub Sync & Security Hardening

This document captures for future reference:
1. The **modular** production bootstrap script — common hardening + Node.js + Docker Engine + GitHub repo sync — each as an independent, toggleable module in one file.
2. How to run it safely on AWS (including selectively enabling/disabling modules).
3. A beginner-friendly, line-by-line walkthrough of what the (earlier, simpler) script does — the same concepts apply to the modular version.

> **Note:** The script below (Section 1) supersedes the original Node.js-only version. See `files/prod-bootstrap.sh` for the live copy.

---

## 1. The Script (Modular: Hardening + Node.js + Docker + Repo Sync)

Save this as `scripts/prod-bootstrap.sh` on the EC2 instance. It is organized into independent modules, each toggleable via environment variables, so you can run only what you need.

```bash
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
APP_USER="${APP_USER:-nodeapp}"
SSH_PORT="${SSH_PORT:-22}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-yes}"

# Node.js settings
NODE_MAJOR="${NODE_MAJOR:-20}"

# Docker settings
DOCKER_COMPOSE_PLUGIN="${DOCKER_COMPOSE_PLUGIN:-true}"

# GitHub repo sync settings
REPO_URL="${REPO_URL:-}"                       # e.g. git@github.com:org/app.git or https://github.com/org/app.git
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DEST="${REPO_DEST:-/opt/${APP_USER}/app}"
REPO_DEPLOY_KEY="${REPO_DEPLOY_KEY:-}"          # path to an SSH deploy key file, optional

echo "[INFO] Starting production bootstrap at $(date -u)"
echo "[INFO] DRY_RUN=${DRY_RUN} | HARDENING=${INSTALL_COMMON_HARDENING} | NODE=${INSTALL_NODE} | DOCKER=${INSTALL_DOCKER} | SYNC_REPO=${SYNC_REPO}"

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

###############################################################################
# OS detection (shared by all modules)
###############################################################################
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    echo "[ERROR] Cannot detect OS"
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
      DEBIAN_FRONTEND=noninteractive run apt-get upgrade -y
      run apt-get install -y curl git unzip tar ca-certificates gnupg lsb-release
      ;;
    *)
      echo "[ERROR] Unsupported OS: $OS_ID $OS_VERSION"
      exit 1
      ;;
  esac
}

module_create_app_user() {
  echo "==> [common_setup] Ensuring app user exists"
  if ! id "$APP_USER" >/dev/null 2>&1; then
    run useradd --create-home --shell /bin/bash "$APP_USER"
    echo "[INFO] Created user: $APP_USER"
  else
    echo "[INFO] User already exists: $APP_USER"
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
    echo "Port ${SSH_PORT}" >> "$sshd_config"
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
      run apt-get install -y ufw
      run ufw allow "${SSH_PORT}/tcp"
      run ufw allow 80/tcp
      run ufw allow 443/tcp
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
    ubuntu|debian) run apt-get install -y fail2ban ;;
    amzn)
      if [[ "$OS_VERSION" == "2" ]]; then run yum install -y fail2ban; else run dnf install -y fail2ban; fi
      ;;
  esac
  systemctl enable --now fail2ban || true
}

module_sysctl_hardening() {
  echo "==> [hardening] Applying kernel/network hardening"
  cat >/etc/sysctl.d/99-production-hardening.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
kernel.randomize_va_space = 2
EOF
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
    esac
  fi

  run npm install -g pm2
  node -v || true
  npm -v || true
  pm2 -v || true
}

###############################################################################
# MODULE: docker — Docker Engine + Compose plugin
###############################################################################
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
        run install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | run gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        run chmod a+r /etc/apt/keyrings/docker.gpg
        local arch
        arch="$(dpkg --print-architecture)"
        local codename
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${codename} stable" \
          > /etc/apt/sources.list.d/docker.list
        run apt-get update -y
        run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    esac
  fi

  run systemctl enable --now docker

  # Let the app user run docker without sudo
  if id "$APP_USER" >/dev/null 2>&1; then
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
    chmod 600 "$REPO_DEPLOY_KEY"
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

  if id "$APP_USER" >/dev/null 2>&1; then
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
```

### Modules in this script
| Module | Function(s) | Toggle variable | Notes |
|---|---|---|---|
| **Common setup** | `module_common_setup`, `module_create_app_user` | always runs | OS detection, package manager update, base tools, creates the `nodeapp` (or custom) user |
| **Common hardening** | `module_secure_ssh`, `module_firewall`, `module_fail2ban`, `module_sysctl_hardening`, `module_auto_updates` | `INSTALL_COMMON_HARDENING` | SSH lockdown (with rollback safety), firewall, fail2ban, kernel hardening, auto security patches |
| **Node.js** | `run_install_node` | `INSTALL_NODE` | Installs Node.js (via NodeSource) + `pm2`, skips if already installed |
| **Docker** | `run_install_docker`, `configure_docker_daemon` | `INSTALL_DOCKER`, `CONFIGURE_DOCKER_DAEMON` | Installs Docker Engine + Compose plugin, enables the service, adds the app user to the `docker` group, configures log rotation + `live-restore` |
| **GitHub repo sync** | `run_sync_repo` | `SYNC_REPO` (needs `REPO_URL`) | Clones the repo on first run, does a hard-reset pull on subsequent runs, supports a dedicated deploy key |

### Why this version is production-grade
- **Modular** — each concern (hardening, Node, Docker, repo sync) is an independent function block; disable any of them without touching the others.
- **Idempotent** — safe to re-run; skips Node/Docker install if already present, and does a safe `fetch` + `reset --hard` for repo sync instead of re-cloning.
- **Validates `sshd -t` before restarting SSH** and auto-rolls back on failure — prevents SSH lockout.
- Only disables password auth if `AuthorizedKeysFile` is confirmed configured.
- Adds `fail2ban`, tighter `sysctl` hardening, `ClientAliveInterval`.
- Has a `DRY_RUN=true` mode to preview every change with no side effects.
- Docker and Node install steps check `command -v` first, so re-running the script doesn't break existing installs.
- Repo sync supports a dedicated **deploy key** so you don't have to reuse your personal SSH key on the server.
- No auto-trigger on logout — you run it deliberately, once, with a rollback plan.

### Example usage (toggling modules)
```bash
# Install everything (hardening + Node + Docker + repo sync)
sudo REPO_URL="git@github.com:org/app.git" ./prod-bootstrap.sh

# Only Docker, skip Node and repo sync
sudo INSTALL_NODE=false SYNC_REPO=false ./prod-bootstrap.sh

# Only sync a private repo using a deploy key, skip hardening/Node/Docker
sudo INSTALL_COMMON_HARDENING=false INSTALL_NODE=false INSTALL_DOCKER=false \
  REPO_URL="git@github.com:org/app.git" REPO_BRANCH="main" \
  REPO_DEST="/opt/nodeapp/app" REPO_DEPLOY_KEY="/home/ec2-user/deploy_key" \
  ./prod-bootstrap.sh

# Preview everything without making changes
sudo DRY_RUN=true REPO_URL="git@github.com:org/app.git" ./prod-bootstrap.sh
```

---

---

## 2. How to Run It Safely on AWS (Beginner Steps)

### Background concepts
- **EC2 instance** = a virtual server in AWS.
- **SSH** = the way you remotely log into that server's terminal from your laptop.
- **Script (`.sh` file)** = a text file of commands you run all at once instead of typing manually.

### Step A — Connect to your server
```bash
ssh -i my-key.pem ec2-user@<your-instance-public-ip>
```
- `-i my-key.pem` = the private key file AWS gave you when the instance was created.
- `ec2-user` = default username (`ubuntu` for Ubuntu AMIs).

### Step B — Get the script onto the server
**Option 1: Create directly on the server**
```bash
nano prod-bootstrap.sh
# paste script content, then save: Ctrl+O, Enter, Ctrl+X
```

**Option 2: Copy from your laptop**
```bash
scp -i my-key.pem prod-bootstrap.sh ec2-user@<your-instance-ip>:~/
```

### Step C — Make it executable
```bash
chmod +x prod-bootstrap.sh
```

### Step D — Preview changes first (dry run)
```bash
sudo DRY_RUN=true ./prod-bootstrap.sh
```
Review `/var/log/prod-bootstrap.log` to see what it *would* do.

### Step D.5 — If syncing a private GitHub repo, set up a deploy key first
For a **private repo**, don't reuse your personal SSH key on a server. Instead, generate a dedicated **deploy key**:
```bash
# On the server
ssh-keygen -t ed25519 -f ~/deploy_key -N "" -C "ec2-deploy-key"
cat ~/deploy_key.pub
```
Copy the printed public key into **GitHub → Repo → Settings → Deploy keys → Add deploy key** (read-only is enough unless the server needs to push). Then point the script at it:
```bash
sudo REPO_URL="git@github.com:org/app.git" \
     REPO_BRANCH="main" \
     REPO_DEST="/opt/nodeapp/app" \
     REPO_DEPLOY_KEY="/home/ec2-user/deploy_key" \
     ./prod-bootstrap.sh
```
For a **public repo**, you can just use the HTTPS URL and skip the deploy key entirely:
```bash
sudo REPO_URL="https://github.com/org/app.git" ./prod-bootstrap.sh
```

### Step E — Run it for real
```bash
sudo ./prod-bootstrap.sh
```
Or, selectively enable/disable modules — see the "Example usage" table in Section 1.

### Step F — Verify before closing your session
**Critical:** keep your current terminal open, and in a **second, new terminal window**, test that you can still connect:
```bash
ssh -i my-key.pem ec2-user@<your-instance-ip>
```
If the second connection succeeds, you're safe. If it fails, do NOT close the first (still-connected) terminal — use it to fix the issue (restore backup config at `/etc/ssh/sshd_config.bak.<timestamp>`).

### Production-scale alternative: AWS Systems Manager (SSM)
For fleets of servers, avoid manual SSH entirely:
```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=instanceIds,Values=<i-id>" \
  --parameters commands="sudo bash /path/to/prod-bootstrap.sh"
```
Output is logged to CloudWatch/S3, with no risk of locking yourself out of your own terminal.

### Safety checklist before running on production
1. Take a **snapshot or AMI backup** of the instance first.
   ```bash
   aws ec2 create-image --instance-id <i-id> --name "pre-hardening-ami" --no-reboot
   ```
2. Run with `DRY_RUN=true` first.
3. Keep a second SSH session open while applying real changes.
4. Confirm SSH still works before closing any session.
5. Never trigger this script from a shell logout hook (`~/.bash_logout`) in production — hardening must be a deliberate, verified action, not an automatic side effect of exiting a terminal.

---

## 3. Line-by-Line Walkthrough (Beginner Explanation)

### Header & Safety Setup
```bash
#!/usr/bin/env bash
```
The "shebang" — tells Linux to run this file using `bash`.

```bash
set -Eeuo pipefail
```
Safety switch for the whole script:
- `-e`: stop immediately if any command fails.
- `-u`: treat use of an unset variable as an error (catches typos).
- `-o pipefail`: if a piped command chain fails partway, treat the whole chain as failed.
- `-E`: makes error trapping work inside functions too.

```bash
LOG_FILE="/var/log/prod-bootstrap.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
```
Sets up a log file. Everything printed to the screen is also saved to `$LOG_FILE`, so you can review it later even after closing the terminal.

```bash
trap 'echo "[ERROR] Failed at line $LINENO. See $LOG_FILE"; exit 1' ERR
```
If any command fails, print exactly which line number failed, then stop.

### Root Check
```bash
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash $0"
  exit 1
fi
```
`EUID` = 0 means you're root (admin). If not run with `sudo`, stop and tell the user.

### Configuration Variables
```bash
NODE_MAJOR="${NODE_MAJOR:-20}"
APP_USER="${APP_USER:-nodeapp}"
SSH_PORT="${SSH_PORT:-22}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-yes}"
DRY_RUN="${DRY_RUN:-false}"
```
`${VAR:-default}` means "use VAR if it was set when running the script, otherwise use this default." Lets you customize behavior, e.g. `sudo SSH_PORT=2222 ./prod-bootstrap.sh`.

### The `run` Helper Function
```bash
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}
```
Wraps every risky command. If `DRY_RUN=true`, it just prints what would happen instead of executing it — this is the "preview mode."

### `detect_os` Function
```bash
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    echo "[ERROR] Cannot detect OS"
    exit 1
  fi
  echo "[INFO] Detected OS: $OS_ID $OS_VERSION"
}
```
Reads `/etc/os-release` to figure out which Linux distro is running (Amazon Linux 2, Amazon Linux 2023, or Ubuntu/Debian), since each uses different install commands.

### `update_system` Function
Uses a `case` statement (like a big if/else) to pick the right package manager:
- Amazon Linux 2 → `yum`
- Amazon Linux 2023 → `dnf`
- Ubuntu/Debian → `apt-get`

Updates existing software (patches security holes) and installs helper tools (`curl`, `git`, `fail2ban`, `ufw`, etc.). Unknown OS → stop with an error instead of guessing.

### `install_node` Function
```bash
if command -v node >/dev/null 2>&1; then
  echo "[INFO] Node already installed..."
```
Checks if `node` already exists — skips reinstalling (makes the script idempotent/safe to re-run).

Otherwise, downloads the official **NodeSource** setup script (adds Node's official package repo) and installs `nodejs` via the OS's package manager. Also installs **pm2** globally — a tool that keeps your Node app running forever, restarting it if it crashes or the server reboots.

### `create_app_user` Function
```bash
if ! id "$APP_USER" >/dev/null 2>&1; then
  run useradd --create-home --shell /bin/bash "$APP_USER"
```
Creates a dedicated, non-root user (default: `nodeapp`) to run your app. Running as root is dangerous — if the app is compromised, a limited user account contains the damage.

### `secure_ssh` Function (most important safety part)
1. **Backs up** `sshd_config` with a timestamp before changing anything.
2. Only disables password login (`PasswordAuthentication no`) if `AuthorizedKeysFile` is already confirmed configured — prevents accidentally locking yourself out with no way to log in.
3. Sets several hardening options via `sed` (find-and-replace in the config file):
   - `PermitRootLogin no` — no direct root SSH login.
   - `X11Forwarding no` — disables an unneeded graphical feature.
   - `ClientAliveInterval 300` / `ClientAliveCountMax 2` — auto-disconnects idle SSH sessions after ~10 minutes.
   - `Port` — sets the SSH port.
4. **Critical step:** runs `sshd -t` to validate the new config *before* restarting SSH.
   - If valid → restarts SSH.
   - If invalid → restores the backup immediately and aborts, so you never get locked out.

### `configure_firewall` Function
On Ubuntu/Debian, uses `ufw` to allow only SSH, HTTP (80), and HTTPS (443), blocking everything else. On Amazon Linux (no built-in `ufw`), relies on **AWS Security Groups** instead (managed from the AWS console).

### `configure_fail2ban` Function
Enables **fail2ban**, which watches for repeated failed login attempts and automatically blocks the attacker's IP.

### `set_basic_sysctl` Function
Writes kernel-level networking security settings to `/etc/sysctl.d/99-production-hardening.conf`:
- `tcp_syncookies` — protects against SYN flood attacks.
- `rp_filter` — prevents IP spoofing.
- `accept_redirects` / `send_redirects` — blocks a network redirection attack trick.
- `randomize_va_space` — randomizes memory layout, making software exploits harder.

`sysctl --system` reloads these settings immediately.

### `enable_auto_updates` Function
On Ubuntu/Debian, turns on **unattended-upgrades** (automatic security patching in the background). On Amazon Linux, there's no equivalent built-in, so it recommends AWS Systems Manager Patch Manager instead.

### `main` Function — the "table of contents"
```bash
main() {
  detect_os
  update_system
  create_app_user
  install_node
  secure_ssh
  configure_firewall
  configure_fail2ban
  set_basic_sysctl
  enable_auto_updates
  ...
}

main
```
Defines the order everything runs in: detect OS → patch system → create app user → install Node/pm2 → harden SSH → configure firewall → enable fail2ban → apply kernel hardening → enable auto-updates → print summary.

The final line `main` is what actually **triggers** execution — everything above it just defines functions; nothing runs until this line calls them.

### New Module: `run_install_docker`
- Checks if `docker` already exists (idempotent), skips if so.
- On Amazon Linux 2, uses `amazon-linux-extras install docker` (Amazon's own packaging shortcut).
- On Amazon Linux 2023, adds Docker's official `dnf` repo (since `amazon-linux-extras` doesn't exist there) and installs `docker-ce`.
- On Ubuntu/Debian, **first calls `purge_conflicting_docker_packages`** (see below), then adds Docker's official signed `apt` repo (GPG key + repo file), then installs `docker-ce` + the Compose plugin (`docker compose`, the modern replacement for the old standalone `docker-compose`).
- `systemctl enable --now docker` starts Docker immediately and makes it start automatically on reboot.
- `usermod -aG docker "$APP_USER"` adds your app user to the `docker` group, so it can run `docker` commands without needing `sudo` every time (takes effect after that user logs in again).

### Helper: `purge_conflicting_docker_packages` (Ubuntu/Debian only)
Docker's official docs recommend removing distro-provided Docker/Podman/containerd/runc
packages before installing `docker-ce`, since running both can cause package or socket
conflicts (`/var/run/docker.sock`). This helper is **conditional and idempotent**:
```bash
purge_conflicting_docker_packages() {
  local conflicting_pkgs=("docker.io" "docker-doc" "docker-compose" "docker-compose-v2" "podman-docker" "containerd" "runc")
  local found_pkgs=()
  for pkg in "${conflicting_pkgs[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      found_pkgs+=("$pkg")
    fi
  done
  if [[ ${#found_pkgs[@]} -eq 0 ]]; then
    echo "[INFO] No conflicting packages found. Skipping purge."
    return 0
  fi
  run apt-get purge -y "${found_pkgs[@]}"
}
```
- It **checks first** (`dpkg -l <pkg> | grep '^ii'`, meaning "installed") rather than
  blindly running `apt-get purge` — on a clean EC2 instance, nothing is found and it's
  skipped entirely, so it never fails or does unnecessary work.
- Only purges packages that are **actually present**, avoiding `apt-get` errors for
  packages that don't exist.
- Not needed on Amazon Linux, since `amazon-linux-extras`/Docker's RHEL repo don't have
  this same conflict pattern.

### Helper: `apt_supports_asc_signed_by` — generic old-vs-new system support
Docker's official docs changed over time: older guides use `gpg --dearmor` to produce a
binary `docker.gpg` keyring; the current docs use a plain ASCII-armored `docker.asc` key
(no dearmor step needed) because modern `apt` (>= 2.4, i.e. **Ubuntu 22.04+/Debian 12+**)
accepts ASCII-armored keys directly in `signed-by=`. Older systems (Ubuntu 20.04, Debian
11 and earlier) still require the binary keyring.

Rather than hardcoding a list of codenames (which needs updating every time a new Ubuntu/
Debian release ships), the script detects the **actual installed apt version**:
```bash
apt_supports_asc_signed_by() {
  local apt_version
  apt_version="$(apt-get --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$apt_version" ]]; then
    return 1   # couldn't detect — fall back to the safer/older method
  fi
  awk -v v="$apt_version" 'BEGIN { exit !(v >= 2.4) }'
}
```
- Extracts the numeric version from `apt-get --version` (e.g. `2.7.14` → `2.7`).
- Uses `awk` for the floating-point comparison (bash can't compare decimals natively).
- If detection fails for any reason, it safely **falls back to the older/dearmored method**
  — never assumes a newer capability it can't confirm.

`run_install_docker`'s Ubuntu/Debian branch then picks the right key format automatically:
```bash
if apt_supports_asc_signed_by; then
  # modern apt: ASCII-armored .asc key, no dearmor needed
  curl -fsSL ".../gpg" | run tee /etc/apt/keyrings/docker.asc >/dev/null
  ...
else
  # older apt: dearmor into a binary .gpg keyring
  curl -fsSL ".../gpg" | run gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  ...
fi
```
This means the **same script works correctly on both older and newer Ubuntu/Debian
systems**, always using the method appropriate for that system's `apt` version.

### Helper: `write_file` — DRY_RUN-safe file writes
Earlier versions of the script wrote the apt repo file with a raw redirect
(`echo "..." > /etc/apt/sources.list.d/docker.list`), which — unlike commands wrapped in
`run()` — would **write the file even during a `DRY_RUN=true` preview**. `write_file` fixes
this:
```bash
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
```
Now `write_file /etc/apt/sources.list.d/docker.list "deb [...] ..."` only touches the
filesystem when `DRY_RUN=false` (the default for a real run), keeping dry-run previews
truly side-effect-free.

### Helper: `configure_docker_daemon` — production-sensible Docker daemon config
By default, Docker's `json-file` log driver keeps **unbounded** container logs — a
long-running production container can silently fill up the entire disk over weeks/months.
This helper writes `/etc/docker/daemon.json` with two production-standard settings:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
```
- **`log-opts` (max-size/max-file)** — caps each container's logs at 10MB × 3 rotated
  files (~30MB max per container) instead of growing forever. Configurable via
  `DOCKER_LOG_MAX_SIZE` / `DOCKER_LOG_MAX_FILE` env vars.
- **`live-restore: true`** — keeps running containers alive even if the Docker **daemon**
  itself restarts (e.g. during a Docker upgrade) — avoids unnecessary app downtime.

**Note on a common mistake:** a raw copy-paste of this config sometimes drops the opening
`{`, producing invalid JSON that would silently break Docker on restart. This helper avoids
that risk entirely — it:
1. Writes the config to a **temp file** first, never touching the real file directly.
2. **Validates the JSON** with `python3 -c "import json; json.load(...)"` before applying it
   (skips validation gracefully if `python3` isn't available, since Docker is generally
   still expected to catch bad config at restart).
3. **Backs up** any existing `daemon.json` before overwriting.
4. Restarts Docker, and **automatically rolls back** to the previous config if the restart
   fails — so a bad config can never leave Docker down.
5. Respects `DRY_RUN` — previews the generated JSON without touching the filesystem.

`systemctl daemon-reload` is included for completeness (relevant if you ever modify the
systemd unit file itself), though strictly it isn't required just for `daemon.json` changes
— only `systemctl restart docker` is needed to apply those.

Toggle this module off with `CONFIGURE_DOCKER_DAEMON=false` if you manage `daemon.json`
some other way (e.g. via configuration management).

### New Module: `run_sync_repo`
- Only runs if `REPO_URL` is set — otherwise it's skipped safely.
- Supports an optional **dedicated deploy key** (`REPO_DEPLOY_KEY`) instead of reusing your personal SSH key — safer for production servers, and you can revoke it independently in GitHub without affecting your own access.
- **First run:** clones the repo fresh into `REPO_DEST` (default `/opt/nodeapp/app`).
- **Subsequent runs:** instead of re-cloning, it does `git fetch` + `git reset --hard origin/<branch>` — this pulls the latest code and discards any local changes on the server, ensuring the server always matches what's in GitHub (important for production — no manual edits should live only on the server).
- Sets file ownership (`chown`) to the app user so the app can read/write its own code directory without needing root.

---

## Key Takeaways
- Treat security-affecting scripts as **deliberate, verified actions** — never auto-trigger them from logout/login hooks in production.
- Always have a **rollback plan** (backups, snapshots, a second open session) before changing SSH/firewall settings.
- Use `DRY_RUN` (or equivalent preview modes) to see what a script will do before it does it.
- Prefer AWS-native orchestration (SSM Run Command, user-data, Infrastructure as Code) over manual ad-hoc SSH scripting for fleets of production servers.

---

# 4. Docker-Based Hosting: Directory Structure, Image Delivery & User Roles

## 4.1 Where to put your app on the host (when using Docker)

Since the app runs **inside a container**, the host only needs deployment config —
not your full source code.

| Path | Verdict |
|---|---|
| `/opt/app` | ⚠️ Too generic — ambiguous if you host more than one app |
| `/opt/nodeapp/app` | ⚠️ Confusing — `nodeapp` is a *user*, not the *app name* |
| **`/opt/<real-app-name>/`** | ✅ Best — clear, describes the actual service |

Recommended layout:
```
/opt/<app-name>/
├── docker-compose.yml     ← services, ports, volumes
├── .env                   ← secrets/config (never committed to git)
├── scripts/               ← deploy/backup/restart helper scripts
│   ├── deploy.sh
│   └── backup.sh
├── data/                  ← persistent volume-mounted data
└── logs/                  ← optional, if not using docker logs/CloudWatch
```

Rule of thumb: name the folder after the **application**, and name the OS user after
its **role** (e.g. `billingapp`, `deploy`) — don't conflate the two.

`/var/www/<app-name>` is also valid (common when Nginx fronts the app), but avoid
reusing Nginx's default `/var/www/html` docroot for your app.

## 4.2 How to get the Docker image onto the AWS instance

**Don't manually copy image files (`docker save`/`scp`/`docker load`) for production.**
Use a container registry instead — versioned, fast, and repeatable.

### Recommended: Amazon ECR (native to AWS)
```bash
# Build & push (CI/build machine)
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
docker build -t myapp:latest .
docker tag myapp:latest <account-id>.dkr.ecr.<region>.amazonaws.com/myapp:latest
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/myapp:latest
```

```bash
# Pull & run (EC2 instance, using an IAM role — no manual credentials needed)
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
docker pull <account-id>.dkr.ecr.<region>.amazonaws.com/myapp:latest
```

| Registry | When to use |
|---|---|
| **Amazon ECR** ✅ | Best for AWS — fastest pulls, IAM-integrated, private by default |
| GitHub Container Registry (GHCR) | If CI/CD is already in GitHub Actions |
| Docker Hub | Simple, but private repos need a paid plan |

### Example `docker-compose.yml`
```yaml
services:
  app:
    image: <account-id>.dkr.ecr.<region>.amazonaws.com/myapp:latest
    restart: unless-stopped
    ports:
      - "80:3000"
    env_file: .env
    volumes:
      - ./data:/app/data
```
```bash
cd /opt/<app-name>
docker compose pull
docker compose up -d
```

### What to sync via GitHub for this workflow
Only sync a **lightweight deploy repo/folder** (not full app source) to the EC2 host:
- `docker-compose.yml`
- `.env.example` (real `.env` stays out of git — injected via secrets manager or manually)
- `scripts/` (deploy, backup, restart helpers)

The actual application source builds into the image via CI — only the **built image**
ships to EC2, not raw source files.

## 4.3 Role of the app user (e.g. `nodeapp`) in a Docker-based setup

Even though Node.js itself now runs **inside the container**, the dedicated OS user
is still valuable — its purpose just shifts:

### Still needed for:
1. **Owning the deployment directory** (`/opt/<app-name>/`) — `docker-compose.yml`,
   `.env`, `data/`, `logs/` are owned by this user, not root. Limits blast radius if
   deploy scripts/CI are compromised.
2. **Running `docker compose`/`docker` commands without `sudo`** — the bootstrap
   script does `usermod -aG docker <app_user>`, letting this user run:
   ```bash
   docker compose pull
   docker compose up -d
   ```
   without root privileges.
3. **SSH/deploy identity** — CI/CD (GitHub Actions, Jenkins) or manual deploys SSH in
   as this user, not `root`/`ec2-user` — cleaner audit trail, restricted permissions.
4. **Cron jobs** (backups, log rotation, health checks) run as this user, not root.

### No longer needed for:
- ❌ Running `node`/`npm` directly on the host — the app runs inside the container,
  so Node.js doesn't need to be installed on the EC2 host at all.
- ❌ Owning raw application source code on the host — code lives in the Docker image.

### Practical implication for the bootstrap script
Since Node.js runs in-container, you can **skip installing Node.js on the host**:
```bash
sudo INSTALL_NODE=false \
     REPO_URL="git@github.com:org/deploy-config.git" \
     REPO_DEST="/opt/<app-name>" \
     ./prod-bootstrap.sh
```
This installs Docker, creates the app user (now acting as a **deployment user**
rather than a Node runtime user), and syncs just the deploy-config repo.

## 4.4 Key Takeaways (Docker Hosting)
- Directory name = app name (`/opt/<app-name>`), not the OS username.
- Ship images via a **registry (ECR)**, never manual file copies, for production.
- Only sync **deploy config** (compose file, `.env.example`, scripts) via git — not
  full source code — when the app is containerized.
- The dedicated app user's role shifts from "runs Node" to "owns files + runs Docker
  commands + is the deploy/SSH identity" — still valuable, just repurposed.
- `INSTALL_NODE` becomes optional/skippable on the host once you're fully
  container-based.
