#!/usr/bin/env bash
set -euo pipefail

# Run this script from the host machine, from this folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

vagrant up

for script in bootstrap_cv3_vault.sh bootstrap_cv3_identity.sh fix_cv3_direct_access_config.sh update_keycloak_client.sh; do
  echo "Uploading ${script}..."
  vagrant upload "$script" "/tmp/${script}"
  echo "Running ${script}..."
  vagrant ssh -c "bash /tmp/${script}"
done

echo "Restarting CV3 services..."
vagrant ssh -c 'cd ~/cv3-deploy && docker compose restart cv3-backend-admin cv3-backend-query cv3-backend-network cv3-backend-query-meta cv3-backend-scheduler cv3-backend-database-manager cv3-frontend'

echo "CV3 bootstrap complete."
echo "Open: http://127.0.0.1:5080/"
