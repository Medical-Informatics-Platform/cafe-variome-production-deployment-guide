#!/usr/bin/env bash
set -euo pipefail

# Run this inside the VM (vagrant user). It assumes ~/cv3-deploy exists.
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed in this shell."
  exit 1
fi

if [ ! -f "$HOME/cv3-deploy/.env" ]; then
  echo "Missing $HOME/cv3-deploy/.env"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'cv3-vault'; then
  echo "Container cv3-vault is not running. Start the stack first."
  exit 1
fi

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault_cmd() {
  docker exec -e VAULT_ADDR="$VAULT_ADDR" -e VAULT_TOKEN="$VAULT_TOKEN" cv3-vault vault "$@"
}

until vault_cmd status >/dev/null 2>&1; do
  echo "Waiting for Vault..."
  sleep 2
done

vault_cmd auth enable approle >/dev/null 2>&1 || true
vault_cmd secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true
vault_cmd secrets enable -path=transit_cv3 transit >/dev/null 2>&1 || true

cat > /tmp/cv3-policy.hcl <<'POL'
path "kv/data/cv3" {
  capabilities = ["create", "update", "read"]
}

path "kv/metadata/cv3" {
  capabilities = ["read", "list"]
}

path "transit_cv3/keys/*" {
  capabilities = ["create", "read", "update", "list"]
}

path "transit_cv3/sign/*" {
  capabilities = ["create", "update", "read"]
}

path "transit_cv3/verify/*" {
  capabilities = ["create", "update", "read"]
}

path "transit_cv3/encrypt/*" {
  capabilities = ["create", "update", "read"]
}

path "transit_cv3/decrypt/*" {
  capabilities = ["create", "update", "read"]
}
POL

vault_cmd policy write cv3-policy /tmp/cv3-policy.hcl >/dev/null
vault_cmd write auth/approle/role/cv3 token_policies="cv3-policy" >/dev/null
ROLE_ID="$(vault_cmd read -field=role_id auth/approle/role/cv3/role-id)"
SECRET_ID="$(vault_cmd write -field=secret_id -f auth/approle/role/cv3/secret-id)"

vault_cmd kv put kv/cv3 keycloak_client_secret=cv3-local-client-secret secret_key=devsecretkeydevsecretkeydev1234 >/dev/null

cd ~/cv3-deploy
sed -i "s/^VAULT_ROLE_ID=.*/VAULT_ROLE_ID=${ROLE_ID}/" .env
sed -i "s/^VAULT_SECRET_ID=.*/VAULT_SECRET_ID=${SECRET_ID}/" .env

echo "VAULT_ROLE_ID=${ROLE_ID}"
echo "VAULT_SECRET_ID=${SECRET_ID}"
