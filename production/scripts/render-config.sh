#!/usr/bin/env bash
# Render config/*.json from the committed *.template files, substituting
# __CV_PUBLIC_HOST__ with CV_PUBLIC_HOST from .env. Use this for the production
# reverse-proxy path (HTTPS + path routing). For an isolated/direct-port dev
# box use the repo's dev/scripts/fix_cv3_direct_access_config.sh instead.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
[ -f .env ] || { echo "ERROR: .env not found - cp .env.template .env"; exit 1; }
set -a; . ./.env; set +a
: "${CV_PUBLIC_HOST:?set CV_PUBLIC_HOST in .env}"
# backend_config.json carries the Mongo app credentials (the backends authenticate to
# Mongo with these - confirmed from the image's instance_config.json schema). Keep them
# out of the committed template via tokens; substitute from .env here. Use hex/alnum
# secrets (openssl rand -hex) so they're safe as sed replacements.
MONGO_APP_USERNAME="${MONGO_APP_USERNAME:-cv3app}"
: "${MONGO_APP_PASSWORD:?set MONGO_APP_PASSWORD in .env}"

# Keycloak client and URLs. Defaults: this host's Keycloak behind the proxy (URL) and
# in-stack (BackendURL). CV_KEYCLOAK_URL (federation with a shared Keycloak) points
# both at another installation's Keycloak. python-keycloak needs the trailing slash.
KC_CLIENT="${KC_CLIENT:-test_client}"
if [ -n "${CV_KEYCLOAK_URL:-}" ]; then
  KC_URL="${CV_KEYCLOAK_URL%/}/"
  KC_BACKEND_URL="$KC_URL"
else
  KC_URL="https://${CV_PUBLIC_HOST}/auth/"
  KC_BACKEND_URL="http://cv3-keycloak:8080/auth/"
fi

shopt -s nullglob
for t in config/*.template; do
  out="config/$(basename "$t" .template)"   # *.json.template -> *.json
  sed -e "s|__CV_PUBLIC_HOST__|${CV_PUBLIC_HOST}|g" \
      -e "s|__MONGO_APP_USERNAME__|${MONGO_APP_USERNAME}|g" \
      -e "s|__MONGO_APP_PASSWORD__|${MONGO_APP_PASSWORD}|g" \
      -e "s|__KC_CLIENT__|${KC_CLIENT}|g" \
      -e "s|__KC_URL__|${KC_URL}|g" \
      -e "s|__KC_BACKEND_URL__|${KC_BACKEND_URL}|g" \
      "$t" > "$out"
  # The containers run as their own in-image uid (appuser 100 / nginx 101), which under
  # userns remap is "other" relative to these dockeruser-owned files. A CIS-hardened
  # umask (027/077) would render them unreadable to that uid; force others-read so the
  # read-only bind mount is loadable. (Host is single-tenant; the real secrets - .env,
  # vault-init.json - stay 600.)
  chmod 0644 "$out"
  echo "rendered $out"
done
echo "Done. Review config/*.json (esp. backend_config.json - see config/README.md), then ./cv.sh up -d."
