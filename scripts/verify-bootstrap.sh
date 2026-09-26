#!/bin/bash
# Verifies prod-bootstrap.sh ran successfully and all recent fixes took effect.
PASS=0; FAIL=0
ok()   { echo "✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "ℹ️  $1"; }

SSH_PORT="${SSH_PORT:-22}"
APP_USER="${APP_USER:-portfolio}"
REPO_DEST="${REPO_DEST:-/opt/${APP_USER}}"
# The user you actually SSH in as (NOT $APP_USER, which has no SSH access by
# design — it's a service account). Override e.g. SSH_LOGIN_USER=ec2-user.
SSH_LOGIN_USER="${SSH_LOGIN_USER:-ubuntu}"
# Set these to match whatever you passed to prod-bootstrap.sh, so this script
# knows which checks apply (Cloudflare-only firewall is opt-in, not default).
CLOUDFLARE_ONLY_WEB="${CLOUDFLARE_ONLY_WEB:-false}"
AWS_SECURITY_GROUP_ID="${AWS_SECURITY_GROUP_ID:-}"

echo "=== OS detection ==="
. /etc/os-release
echo "OS: $ID $VERSION_ID"

echo ""
echo "=== 1. SSH hardening (module_secure_ssh) ==="
grep -q "^PermitRootLogin no" /etc/ssh/sshd_config && ok "PermitRootLogin no" || bad "PermitRootLogin not disabled"
grep -q "^X11Forwarding no" /etc/ssh/sshd_config && ok "X11Forwarding no" || bad "X11Forwarding not disabled"
grep -q "^ClientAliveInterval 300" /etc/ssh/sshd_config && ok "ClientAliveInterval 300" || bad "ClientAliveInterval missing"
grep -q "^Port ${SSH_PORT}" /etc/ssh/sshd_config && ok "Port set to ${SSH_PORT}" || bad "Port not set correctly"
systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null \
  && ok "sshd service active" || bad "sshd service not active"

# --- SSH diagnostics (useful when troubleshooting connection/lockout issues) ---
echo ""
echo "--- SSH diagnostics ---"

echo "[1] Listening sockets for sshd:"
sudo ss -tlnp | grep sshd && ok "sshd is listening" || bad "sshd not found in listening sockets"

echo ""
echo "[2] Configured port:"
grep -i "^Port" /etc/ssh/sshd_config

echo ""
echo "[3] Auth settings:"
grep -iE "^(PasswordAuthentication|PubkeyAuthentication|AuthorizedKeysFile)" /etc/ssh/sshd_config

SSH_LOGIN_HOME=$(getent passwd "$SSH_LOGIN_USER" | cut -d: -f6)

echo ""
echo "[4] authorized_keys for login user ($SSH_LOGIN_USER):"
if [[ -n "$SSH_LOGIN_HOME" && -d "$SSH_LOGIN_HOME/.ssh" ]]; then
  sudo ls -la "$SSH_LOGIN_HOME/.ssh/"
  sudo cat "$SSH_LOGIN_HOME/.ssh/authorized_keys" 2>/dev/null | wc -l | xargs -I{} echo "  ({} key(s) present)"
  ok "$SSH_LOGIN_USER has an .ssh directory"
else
  bad "$SSH_LOGIN_USER has no .ssh directory at $SSH_LOGIN_HOME"
fi

echo ""
echo "[5] Permissions for $SSH_LOGIN_USER's .ssh:"
if [[ -n "$SSH_LOGIN_HOME" ]]; then
  sudo stat -c '%a %U:%G %n' "$SSH_LOGIN_HOME/.ssh" 2>/dev/null
  sudo stat -c '%a %U:%G %n' "$SSH_LOGIN_HOME/.ssh/authorized_keys" 2>/dev/null
  DIR_PERM=$(sudo stat -c '%a' "$SSH_LOGIN_HOME/.ssh" 2>/dev/null)
  KEY_PERM=$(sudo stat -c '%a' "$SSH_LOGIN_HOME/.ssh/authorized_keys" 2>/dev/null)
  [[ "$DIR_PERM" == "700" ]] && ok ".ssh dir perms 700" || bad ".ssh dir perms are $DIR_PERM (expected 700)"
  [[ "$KEY_PERM" == "600" ]] && ok "authorized_keys perms 600" || bad "authorized_keys perms are $KEY_PERM (expected 600)"
fi

echo ""
echo "[6] Recent sshd auth log entries:"
sudo journalctl -u sshd -n 50 --no-pager 2>/dev/null || sudo journalctl -u ssh -n 50 --no-pager 2>/dev/null

echo ""
echo "=== 2. Firewall (module_firewall) — Ubuntu/Debian only ==="
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
  ufw status | grep -q "Status: active" && ok "ufw active" || bad "ufw not active"
  ufw status | grep -q "${SSH_PORT}/tcp" && ok "ufw allows SSH port ${SSH_PORT}" || bad "ufw missing SSH port rule"

  if [[ "$CLOUDFLARE_ONLY_WEB" == "true" ]]; then
    info "CLOUDFLARE_ONLY_WEB=true — expecting per-CIDR Cloudflare rules on 80,443/tcp instead of open-to-anywhere"
    CF_RULE_COUNT=$(ufw status | grep -cE "80,443/tcp[[:space:]]+ALLOW[[:space:]]+[0-9a-fA-F:.]+/[0-9]+")
    [[ "$CF_RULE_COUNT" -gt 0 ]] && ok "ufw has ${CF_RULE_COUNT} Cloudflare-range rule(s) for 80,443/tcp" \
      || bad "No per-CIDR Cloudflare rules found for 80,443/tcp (expected when CLOUDFLARE_ONLY_WEB=true)"
    ufw status | grep -qE "80,443/tcp[[:space:]]+ALLOW[[:space:]]+Anywhere" \
      && bad "80,443/tcp still open to Anywhere — Cloudflare-only restriction not applied" \
      || ok "80,443/tcp is NOT open to Anywhere"
  else
    ufw status | grep -q "80/tcp" && ok "ufw allows 80/tcp" || bad "ufw missing 80/tcp"
    ufw status | grep -q "443/tcp" && ok "ufw allows 443/tcp" || bad "ufw missing 443/tcp"
  fi
else
  info "Skipped (Amazon Linux relies on Security Groups)"
fi

echo ""
echo "=== 3. Cloudflare-only firewall (system-level, opt-in) ==="
if [[ "$CLOUDFLARE_ONLY_WEB" == "true" ]]; then
  if [[ -f /etc/cron.d/cloudflare-fw-refresh ]]; then
    ok "Weekly refresh cron installed (/etc/cron.d/cloudflare-fw-refresh)"
    grep -qE "^0 3 \* \* 0 " /etc/cron.d/cloudflare-fw-refresh && ok "Refresh cron scheduled weekly (Sun 3am)" || bad "Refresh cron schedule unexpected"
  else
    bad "/etc/cron.d/cloudflare-fw-refresh missing (expected when CLOUDFLARE_ONLY_WEB=true)"
  fi
  [[ -x /usr/local/bin/refresh-cloudflare-fw.sh ]] && ok "Refresh script present and executable" || bad "Refresh script missing/not executable"

  if [[ -n "$AWS_SECURITY_GROUP_ID" ]] && command -v aws >/dev/null 2>&1; then
    SG_JSON=$(aws ec2 describe-security-groups --group-ids "$AWS_SECURITY_GROUP_ID" 2>/dev/null)
    if [[ -n "$SG_JSON" ]]; then
      OPEN_RULES=$(echo "$SG_JSON" | grep -c '0.0.0.0/0\|::/0' || true)
      [[ "$OPEN_RULES" -eq 0 ]] && ok "Security Group ${AWS_SECURITY_GROUP_ID} has no open (0.0.0.0/0 or ::/0) rules" \
        || bad "Security Group ${AWS_SECURITY_GROUP_ID} still has ${OPEN_RULES} open rule(s) on 80/443"
    else
      bad "Could not describe Security Group ${AWS_SECURITY_GROUP_ID} (check aws cli credentials/permissions)"
    fi
  else
    info "AWS_SECURITY_GROUP_ID not set or aws cli unavailable — skipping Security Group check"
  fi
else
  info "Skipped (CLOUDFLARE_ONLY_WEB not enabled)"
fi

echo ""
echo "=== 4. fail2ban (module_fail2ban) ==="
systemctl is-active --quiet fail2ban && ok "fail2ban service active" || bad "fail2ban not active"
if [[ -f /etc/fail2ban/jail.local ]]; then
  ok "jail.local exists"
  grep -q "port = ${SSH_PORT}" /etc/fail2ban/jail.local && ok "jail.local port matches SSH_PORT (${SSH_PORT})" || bad "jail.local port mismatch"
  grep -q "^enabled = true" /etc/fail2ban/jail.local && ok "sshd jail enabled" || bad "sshd jail not enabled"
else
  bad "jail.local missing"
fi
fail2ban-client status sshd 2>/dev/null && ok "fail2ban sshd jail is running" || bad "fail2ban sshd jail not running/reporting"

echo ""
echo "=== 5. sysctl hardening (module_sysctl_hardening) ==="
[[ -f /etc/sysctl.d/99-production-hardening.conf ]] && ok "sysctl conf file present" || bad "sysctl conf missing"
[[ "$(sysctl -n net.ipv4.tcp_syncookies)" == "1" ]] && ok "tcp_syncookies=1" || bad "tcp_syncookies not applied"
[[ "$(sysctl -n net.ipv4.conf.all.accept_source_route)" == "0" ]] && ok "accept_source_route=0" || bad "accept_source_route not applied"
[[ "$(sysctl -n net.ipv6.conf.all.accept_redirects 2>/dev/null)" == "0" ]] && ok "IPv6 accept_redirects=0" || info "IPv6 setting not applied/available"

echo ""
echo "=== 6. Docker (run_install_docker + configure_docker_daemon) ==="
command -v docker >/dev/null 2>&1 && ok "docker installed: $(docker --version)" || bad "docker not installed"
docker compose version >/dev/null 2>&1 && ok "docker compose plugin works: $(docker compose version --short 2>/dev/null)" || bad "docker compose not working"
systemctl is-active --quiet docker && ok "docker service active" || bad "docker service not active"
if [[ -f /etc/docker/daemon.json ]]; then
  ok "daemon.json present"
  python3 -c "import json; json.load(open('/etc/docker/daemon.json'))" 2>/dev/null && ok "daemon.json is valid JSON" || bad "daemon.json invalid JSON"
  grep -q '"live-restore": true' /etc/docker/daemon.json && ok "live-restore enabled" || bad "live-restore missing"
else
  bad "daemon.json missing"
fi
id "$APP_USER" 2>/dev/null | grep -q docker && ok "$APP_USER is in docker group" || bad "$APP_USER not in docker group"

echo ""
echo "=== 7. Node.js ==="
command -v node >/dev/null 2>&1 && ok "node installed: $(node -v)" || bad "node not installed"
command -v pm2 >/dev/null 2>&1 && ok "pm2 installed: $(pm2 -v)" || bad "pm2 not installed"

echo ""
echo "=== 8. App user (module_create_app_user) ==="
if id "$APP_USER" >/dev/null 2>&1; then
  ok "$APP_USER exists"
  UID_NUM=$(id -u "$APP_USER")
  [[ "$UID_NUM" -lt 1000 ]] && ok "$APP_USER is a system account (UID $UID_NUM)" || info "$APP_USER UID=$UID_NUM (not a system account — ok if useradd without --system was intended)"
  getent passwd "$APP_USER" | grep -q "/bin/bash$" && ok "$APP_USER shell is /bin/bash" || bad "$APP_USER shell not /bin/bash"
  passwd -S "$APP_USER" 2>/dev/null | grep -qE "^\S+ L" && ok "$APP_USER password is locked" || info "$APP_USER password lock status unclear"
else
  bad "$APP_USER does not exist"
fi

echo ""
echo "=== 9. Repo sync (run_sync_repo) ==="
if [[ -d "${REPO_DEST}/.git" ]]; then
  ok "Repo cloned at $REPO_DEST"
  echo "  Branch: $(git -C "$REPO_DEST" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "  Last commit: $(git -C "$REPO_DEST" log -1 --oneline 2>/dev/null)"
  OWNER=$(stat -c '%U' "$REPO_DEST" 2>/dev/null)
  [[ "$OWNER" == "$APP_USER" ]] && ok "Repo owned by $APP_USER" || bad "Repo owned by $OWNER, expected $APP_USER"
else
  info "Repo not synced (SYNC_REPO=false or REPO_URL unset — check if expected)"
fi

echo ""
echo "=== 10. apt version-comparison bug fix (Ubuntu/Debian only) ==="
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
  APT_VER=$(apt-get --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  echo "  apt version detected: $APT_VER"
  if [[ -f /etc/apt/keyrings/docker.asc ]]; then
    ok "Using ASC key method (apt >= 2.4 path) — docker.asc present"
  elif [[ -f /etc/apt/keyrings/docker.gpg ]]; then
    ok "Using dearmored GPG key method (apt < 2.4 path) — docker.gpg present"
  else
    bad "Neither docker.asc nor docker.gpg found under /etc/apt/keyrings/"
  fi
else
  info "Skipped (Amazon Linux doesn't use this apt-specific logic)"
fi

echo ""
echo "=== 11. Log file ==="
[[ -f /var/log/prod-bootstrap.log ]] && ok "Bootstrap log exists" || bad "Bootstrap log missing"
grep -q "Bootstrap completed successfully" /var/log/prod-bootstrap.log && ok "Bootstrap completed successfully (per log)" || bad "No success marker in log — check for errors"

echo ""
echo "=================================================="
echo "RESULT: $PASS passed, $FAIL failed"
echo "=================================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

# scp verify-bootstrap.sh ec2-user@<host>:~/    # or ubuntu@<host>
# ssh <user>@<host>
# sudo APP_USER=portfolio SSH_PORT=22 SSH_LOGIN_USER=ubuntu bash verify-bootstrap.sh
#
# If you ran prod-bootstrap.sh with the Cloudflare-only firewall enabled,
# pass the same values here so section 2/3's checks match what was applied:
# sudo APP_USER=portfolio SSH_PORT=22 SSH_LOGIN_USER=ubuntu \
#      CLOUDFLARE_ONLY_WEB=true AWS_SECURITY_GROUP_ID=sg-xxxxxxxxxxxx \
#      bash verify-bootstrap.sh