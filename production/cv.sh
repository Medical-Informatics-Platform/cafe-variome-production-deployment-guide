#!/usr/bin/env bash
# Thin wrapper around `docker compose` for the rootless CV3 production deployment.
# Pins the rootless Docker socket and the compose file set so every command is short
# and identical:
#
#   ./cv.sh config          # render/validate the merged compose
#   ./cv.sh up -d           # start
#   ./cv.sh ps              # status
#   ./cv.sh logs -f cv3-backend-admin
#   ./cv.sh down
#
# Run as the rootless Docker user (dockeruser). Overlays are toggled from .env so
# `ps`/`logs`/`down` always see the same services as `up`:
#   CV_PUBLIC_HOST   set -> add the TLS reverse proxy (compose.reverse-proxy.yml)
#   CV_LOCAL_INFRA=1 -> run Keycloak+Vault+MongoDB locally (compose.local-infra.yml);
#                       otherwise the forced-egress proxy (compose.egress.yml) is used
#                       to reach EXTERNAL Keycloak/Vault.
set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

env_get() { grep -E "^$1=" "$here/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
[ -z "${CV_PUBLIC_HOST:-}" ] && CV_PUBLIC_HOST="$(env_get CV_PUBLIC_HOST)"
[ -z "${CV_LOCAL_INFRA:-}" ] && CV_LOCAL_INFRA="$(env_get CV_LOCAL_INFRA)"

files=(-f docker-compose.yml -f compose.hardening.yml)

# Infra path: local containers, or forced-egress to external infra. (Each is added
# only once its overlay file exists, so this wrapper works across build phases.)
if [ "${CV_LOCAL_INFRA:-0}" = "1" ] && [ -f compose.local-infra.yml ]; then
  files+=(-f compose.local-infra.yml)
elif [ -f compose.egress.yml ]; then
  files+=(-f compose.egress.yml)
fi

# Optional TLS reverse proxy (sole public ingress).
if [ -n "${CV_PUBLIC_HOST:-}" ] && [ -f compose.reverse-proxy.yml ]; then
  export CV_PUBLIC_HOST
  files+=(-f compose.reverse-proxy.yml)
fi

exec docker compose --env-file .env "${files[@]}" "$@"
