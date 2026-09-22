#!/usr/bin/env bash
# Fail-closed secrets gate - refuses to proceed while any required value is empty
# or still a placeholder. cv.sh runs this automatically before any command that
# would start containers (up/create/run/restart); run it by hand any time with:
#   ./scripts/validate-env.sh
# Skip once (not recommended) with CV_SKIP_ENV_CHECK=1.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$here/.env}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found - run: cp .env.template .env"; exit 1; }

# Parse .env instead of sourcing it. `. .env` executes the file, so a stray
# backtick or $(...) in a password would run as shell - this file is data, not code.
declare -A ENVV=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"                                  # tolerate CRLF
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
  key="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
  # strip one layer of matching quotes; leave the value otherwise untouched
  if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
  ENVV["$key"]="$val"
done < "$ENV_FILE"

get() { printf '%s' "${ENVV[$1]-}"; }

fail=0
# Placeholder detection is a SUBSTRING match, case-insensitive: the old anchored
# ^CHANGE_ME$ let "CHANGE_ME_now" and "my-changeme" through.
req() {
  local name="$1" val; val="$(get "$1")"
  local lower="${val,,}"
  if [ -z "$val" ]; then
    echo "  ✗ $name is empty"; fail=1
  elif [[ "$lower" == *change_me* || "$lower" == *change-me* || "$lower" == *changeme* \
       || "$lower" == *"replace_me"* || "$lower" == *"your-"* || "$lower" == minioadmin \
       || "$lower" == *example.com* || "$lower" == *example.org* ]]; then
    echo "  ✗ $name still looks like a placeholder ($val)"; fail=1
  fi
}

# Warn (do not fail) when a secret is short enough to be guessable.
weak() {
  local name="$1" min="$2" val; val="$(get "$1")"
  if [ -n "$val" ] && [ "${#val}" -lt "$min" ]; then
    echo "  ! $name is only ${#val} chars (want >= $min): openssl rand -hex $((min / 2))"
  fi
}

echo "Validating $ENV_FILE ..."

# Always required - every backend authenticates to Vault with these.
req VAULT_ROLE_ID
req VAULT_SECRET_ID

# The db-manager's first-run install consumes these in BOTH infra modes, so they are
# not local-infra-only (docker-compose.yml passes them to cv3-backend-database-manager).
req KEYCLOAK_CLIENT_SECRET
req ADMIN_EMAIL
req ADMIN_AFFILIATION
weak KEYCLOAK_CLIENT_SECRET 32

# Required when the TLS reverse proxy is enabled.
if [ -n "$(get CV_PUBLIC_HOST)" ]; then
  # "internal" selects Caddy's self-signed CA and needs no ACME account.
  if [ "$(get CV_TLS)" != "internal" ]; then
    req ACME_EMAIL
  fi
else
  echo "  ! CV_PUBLIC_HOST is unset: no TLS reverse proxy, so the stack has NO public"
  echo "    ingress. Intentional only for an internal/offline box."
fi

# Required only for the self-contained local-infra overlay.
if [ "$(get CV_LOCAL_INFRA)" = "1" ]; then
  for v in KEYCLOAK_ADMIN_PASSWORD KC_DB_PASSWORD MONGO_ROOT_PASSWORD MONGO_APP_PASSWORD; do
    req "$v"
  done
  weak KEYCLOAK_ADMIN_PASSWORD 16
  weak KC_DB_PASSWORD 24
  weak MONGO_ROOT_PASSWORD 24
  weak MONGO_APP_PASSWORD 24
  # render-config.sh substitutes these into backend_config.json with sed, and the CV3
  # image embeds the app password in the Mongo connection host - so a non-hex password
  # can break both the sed and the URI.
  for v in MONGO_ROOT_PASSWORD MONGO_APP_PASSWORD; do
    val="$(get "$v")"
    if [ -n "$val" ] && [[ ! "$val" =~ ^[A-Za-z0-9]+$ ]]; then
      echo "  ✗ $v must be alphanumeric (it goes into a sed replacement and a Mongo URI):"
      echo "      openssl rand -hex 24"
      fail=1
    fi
  done
else
  echo "  ! CV_LOCAL_INFRA != 1 (external-infra mode): make sure"
  echo "    allowed_domains.cv-egress.txt lists your external Keycloak + Vault hosts,"
  echo "    or cv-egress-proxy denies everything and the backends cannot start."
  if ! grep -qE '^[[:space:]]*[^#[:space:]]' "$here/allowed_domains.cv-egress.txt" 2>/dev/null; then
    echo "  ✗ allowed_domains.cv-egress.txt has no active entries (comments only)"; fail=1
  fi
fi

# The file holds every secret in the deployment; it must not be world/group readable.
mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '')"
if [ -n "$mode" ] && [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
  echo "  ! $ENV_FILE mode is $mode - tightening to 600"
  chmod 600 "$ENV_FILE" || echo "  ! could not chmod $ENV_FILE"
fi

if [ "$fail" -ne 0 ]; then
  echo "FAILED - fix the values above before deploying."
  exit 1
fi
echo "OK - all required secrets are set."
