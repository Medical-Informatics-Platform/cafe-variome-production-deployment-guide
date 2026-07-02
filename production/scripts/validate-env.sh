#!/usr/bin/env bash
# Fail-closed secrets gate - refuses to proceed while any required value is empty
# or still a placeholder. Run before deploying: ./scripts/validate-env.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$here/.env}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found - run: cp .env.template .env"; exit 1; }

set -a; . "$ENV_FILE"; set +a

fail=0
req() {
  local name="$1" val="${!1:-}"
  if [[ -z "$val" || "$val" =~ ^(CHANGE_ME|change-me|changeme|minioadmin)$ ]]; then
    echo "  ✗ $name is empty or a placeholder"; fail=1
  fi
}

echo "Validating $ENV_FILE ..."
# Always required:
req VAULT_ROLE_ID
req VAULT_SECRET_ID

# Required when the TLS reverse proxy is enabled:
if [ -n "${CV_PUBLIC_HOST:-}" ]; then
  req ACME_EMAIL
fi

# Required only for the self-contained local-infra overlay:
if [ "${CV_LOCAL_INFRA:-0}" = "1" ]; then
  for v in KEYCLOAK_CLIENT_SECRET KEYCLOAK_ADMIN_PASSWORD KC_DB_PASSWORD MONGO_ROOT_PASSWORD MONGO_APP_PASSWORD; do
    req "$v"
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "FAILED - fix the values above before deploying."
  exit 1
fi
echo "OK - all required secrets are set."
