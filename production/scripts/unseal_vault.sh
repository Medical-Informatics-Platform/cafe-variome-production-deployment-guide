#!/usr/bin/env bash
# Re-unseal cv3-vault after a restart. Non-dev Vault always boots SEALED and there
# is no cloud auto-unseal here, so this must be run after every Vault/host restart.
# Reads the unseal keys saved by bootstrap_local_infra.sh (keep that file offline).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

INIT="$here/secrets/vault-init.json"
[ -f "$INIT" ] || { echo "ERROR: $INIT not found. Run scripts/bootstrap_local_infra.sh first (and keep the keys safe)."; exit 1; }

dv() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault vault "$@"; }
for i in 0 1 2; do
  k="$(python3 -c "import json;print(json.load(open('$INIT'))['unseal_keys_b64'][$i])")"
  dv operator unseal "$k" >/dev/null
done
dv status | grep -iE 'sealed|version' || true
echo "cv3-vault unsealed."
