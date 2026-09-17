#!/usr/bin/env bash
# Run once on a fresh EC2 instance to get it ready for `deploy.sh`. Only
# orchestrates: installing Docker and syncing this repo. Secrets are left to
# deploy.sh (npm run admin:create / tunnel:token), and running the stack is
# left to deploy.sh too — this script doesn't touch either.
#
# Usage:
#   REPO_URL=git@github.com:you/portfolio-6.git ./scripts/provision-ec2.sh
#
# Re-run anytime to update Docker or pull the latest repo state; both steps
# are idempotent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source=./lib/install-docker.sh
source ./lib/install-docker.sh
# shellcheck source=./lib/install-node.sh
source ./lib/install-node.sh
# shellcheck source=./lib/sync-repo.sh
source ./lib/sync-repo.sh

install_docker
install_node
sync_repo

# Only bcryptjs/readline are needed to run admin:create/tunnel:token — the
# app itself runs from the pulled image, so skip devDependencies here.
echo "==> Installing script dependencies (npm ci --omit=dev) in $TARGET_DIR..."
npm ci --omit=dev --prefix "$TARGET_DIR"

cat <<EOF

==> Provisioning complete.
==> Next steps, from $TARGET_DIR:
      cd "$TARGET_DIR"
      npm run tunnel:token   # if using --tunnel and no token secret yet
      npm run admin:create   # if secrets/admin-users.json has no users yet
      IMAGE=<your-ecr-image> ./deploy.sh --pull your-domain.com
EOF
