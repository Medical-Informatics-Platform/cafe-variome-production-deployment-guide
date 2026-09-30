#!/usr/bin/env bash
# Re-unseal cv3-vault after a restart. Non-dev Vault always boots SEALED and there
# is no cloud auto-unseal here, so this must be run after every Vault/host restart.
#
# Key sources, in order:
#   1. CV_UNSEAL_KEYS  - newline/comma/space separated shares in the environment
#   2. --stdin         - shares on stdin, one per line (paste, or pipe from a manager)
#   3. secrets/vault-init.json  - the file bootstrap wrote
#
# The docs tell you to move that file OFF the host, which used to make this script
# unusable afterwards - the reason people leave the unseal keys sitting next to the
# sealed Vault they open. Prefer 1 or 2 so no share is stored on the server:
#   ./scripts/unseal_vault.sh --stdin        # then paste 3 shares, Ctrl-D
#   CV_UNSEAL_KEYS="$(pass cv3/unseal)" ./scripts/unseal_vault.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
export PATH="$HOME/bin:$PATH"   # rootless Docker CLI location (install-docker-rootless.yml)
[ -S "/run/user/$(id -u)/docker.sock" ] || {
  echo "ERROR: no rootless Docker for user $(id -un). Run this as the Docker user: sudo -iu dockeruser" >&2
  exit 1
}

INIT="$here/secrets/vault-init.json"
keys=()

if [ -n "${CV_UNSEAL_KEYS:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-splitting on the separators
  IFS=$', \n\t' read -r -d '' -a keys < <(printf '%s\0' "$CV_UNSEAL_KEYS") || true
  echo "Using unseal shares from CV_UNSEAL_KEYS (${#keys[@]} provided)."
elif [ "${1:-}" = "--stdin" ]; then
  echo "Paste unseal shares, one per line, then Ctrl-D:"
  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    [ -n "$line" ] && keys+=("$line")
  done
  echo "Read ${#keys[@]} share(s) from stdin."
elif [ -f "$INIT" ]; then
  echo "WARNING: reading unseal shares from $INIT."
  echo "         Move that file offline and use --stdin or CV_UNSEAL_KEYS instead;"
  echo "         keys stored beside the Vault they open defeat the seal."
  mapfile -t keys < <(python3 -c "
import json,sys
d=json.load(open('$INIT'))
print('\n'.join(d.get('unseal_keys_b64') or []))")
else
  echo "ERROR: no unseal shares. Provide them with --stdin, CV_UNSEAL_KEYS, or restore $INIT."
  exit 1
fi

[ "${#keys[@]}" -gt 0 ] || { echo "ERROR: no usable unseal shares found."; exit 1; }

dv() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault vault "$@"; }

sealed() { dv status -format=json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo True; }

# Feed shares until Vault reports unsealed, so a 5-share file with threshold 3 works
# and a threshold change does not need a code edit.
for k in "${keys[@]}"; do
  [ "$(sealed)" = "False" ] && break
  dv operator unseal "$k" >/dev/null 2>&1 || echo "  WARN: a share was rejected (wrong key?)"
done

if [ "$(sealed)" = "False" ]; then
  dv status | grep -iE 'sealed|version' || true
  echo "cv3-vault unsealed."
else
  echo "ERROR: cv3-vault is still sealed - not enough valid shares (threshold is 3)."
  exit 1
fi
