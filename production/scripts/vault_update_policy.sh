#!/usr/bin/env bash
# Bring an existing local-infra install's Vault setup in line with the bootstrap:
#   - writes vault/cv3-policy.hcl as cv3-policy;
#   - sets the AppRole token lifetime (VAULT_APPROLE_TOKEN_TTL, default 2160h = 90d)
#     on the role and the approle mount, then restarts the backends so they log in
#     again and get such a token (CV3 never renews its Vault token).
# The bootstrap revoked its root token, so this creates a short-lived root token from
# the unseal shares (vault operator generate-root) and revokes it at the end.
#
# Unseal shares, as for unseal_vault.sh:
#   CV_UNSEAL_KEYS="..." ./scripts/vault_update_policy.sh
#   ./scripts/vault_update_policy.sh --stdin        # paste shares, Ctrl-D
#   ./scripts/vault_update_policy.sh                # falls back to secrets/vault-init.json
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
export PATH="$HOME/bin:$PATH"   # rootless Docker CLI location (install-docker-rootless.yml)
[ -S "/run/user/$(id -u)/docker.sock" ] || {
  echo "ERROR: no rootless Docker for user $(id -un). Run this as the Docker user: sudo -iu dockeruser" >&2
  exit 1
}

INIT="secrets/vault-init.json"
keys=()
if [ -n "${CV_UNSEAL_KEYS:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-splitting on the separators
  IFS=$', \n\t' read -r -d '' -a keys < <(printf '%s\0' "$CV_UNSEAL_KEYS") || true
elif [ "${1:-}" = "--stdin" ]; then
  echo "Paste unseal shares, one per line, then Ctrl-D:"
  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    [ -n "$line" ] && keys+=("$line")
  done
elif [ -f "$INIT" ]; then
  echo "WARNING: reading unseal shares from $INIT (keep them off the host; see README)."
  mapfile -t keys < <(python3 -c "import json;print('\n'.join(json.load(open('$INIT')).get('unseal_keys_b64') or []))")
else
  echo "ERROR: no unseal shares. Provide them with --stdin, CV_UNSEAL_KEYS, or $INIT."; exit 1
fi
[ "${#keys[@]}" -gt 0 ] || { echo "ERROR: no usable unseal shares found."; exit 1; }

dv() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault vault "$@"; }
json_get() { python3 -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }

[ "$(dv status -format=json | json_get sealed)" = "False" ] \
  || { echo "ERROR: Vault is sealed. Run ./scripts/unseal_vault.sh first."; exit 1; }

echo "== Vault: temporary root token from unseal shares =="
dv operator generate-root -cancel >/dev/null 2>&1 || true
init="$(dv operator generate-root -init -format=json)"
nonce="$(printf '%s' "$init" | json_get nonce)"
otp="$(printf '%s' "$init" | json_get otp)"
encoded=""
for k in "${keys[@]}"; do
  out="$(dv operator generate-root -nonce="$nonce" -format=json "$k")"
  encoded="$(printf '%s' "$out" | json_get encoded_token)"
  [ -n "$encoded" ] && break
done
[ -n "$encoded" ] || { dv operator generate-root -cancel >/dev/null 2>&1 || true; echo "ERROR: not enough valid shares."; exit 1; }
token="$(dv operator generate-root -decode="$encoded" -otp="$otp" | tr -d '\r\n')"

vt() { docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$token" cv3-vault vault "$@"; }
revoke() { vt token revoke -self >/dev/null 2>&1 && echo "== Vault: temporary root token revoked ==" || echo "WARN: revoke the temporary root token manually"; }
trap revoke EXIT

echo "== Vault: writing cv3-policy from vault/cv3-policy.hcl =="
docker exec -i cv3-vault sh -c 'cat > /tmp/cv3-policy.hcl' < vault/cv3-policy.hcl
vt policy write cv3-policy /tmp/cv3-policy.hcl

ttl="${VAULT_APPROLE_TOKEN_TTL:-2160h}"
echo "== Vault: AppRole token lifetime $ttl =="
vt auth tune -max-lease-ttl="$ttl" approle
vt write auth/approle/role/cv3 token_ttl="$ttl" token_max_ttl="$ttl"

revoke; trap - EXIT
echo "== restarting the backends so they get a token with the new lifetime =="
./cv.sh restart cv3-backend-admin cv3-backend-query cv3-backend-network \
  cv3-backend-query-meta cv3-backend-query-compiler cv3-backend-scheduler cv3-backend-database-manager
