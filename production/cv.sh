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
export PATH="$HOME/bin:$PATH"   # rootless Docker CLI location (install-docker-rootless.yml)
[ -S "/run/user/$(id -u)/docker.sock" ] || {
  echo "ERROR: no rootless Docker for user $(id -un). Run this as the Docker user: sudo -iu dockeruser" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

env_get() { grep -E "^$1=" "$here/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" || true; }
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

# Optional federation (FEDERATION.md). Loaded last so its HTTP(S)_PROXY values win.
#   CV_FEDERATION=1  -> filtered egress to peers (compose.federation.yml)
#   CV_KEYCLOAK_URL  -> use another installation's Keycloak (compose.shared-keycloak.yml)
[ -z "${CV_FEDERATION:-}" ] && CV_FEDERATION="$(env_get CV_FEDERATION)"
[ -z "${CV_KEYCLOAK_URL:-}" ] && CV_KEYCLOAK_URL="$(env_get CV_KEYCLOAK_URL)"
if [ "${CV_FEDERATION:-0}" = "1" ]; then
  [ -n "${CV_PUBLIC_HOST:-}" ] || { echo "CV_FEDERATION=1 needs CV_PUBLIC_HOST (peers reach you over HTTPS)." >&2; exit 1; }
  files+=(-f compose.federation.yml)
  [ -n "${CV_KEYCLOAK_URL:-}" ] && files+=(-f compose.shared-keycloak.yml)
elif [ -n "${CV_KEYCLOAK_URL:-}" ]; then
  echo "CV_KEYCLOAK_URL is set but CV_FEDERATION is not 1; the backends would have no route to it." >&2
  exit 1
fi

# Fail-closed secrets gate. SECURITY.md calls validate-env.sh a gate that "refuses to
# deploy", so it has to actually run before anything starts - not as a step the runbook
# asks you to remember afterwards. Only gate commands that can START containers; config/
# ps/logs/down stay usable on a half-configured box (that is when you need them most).
#
# A TARGETED start (`./cv.sh up -d cv3-vault ...`) only warns. That is the documented
# bootstrap step 3a: Vault has to be running before bootstrap_local_infra.sh can mint
# the AppRole, so VAULT_ROLE_ID/SECRET_ID are legitimately still placeholders then.
# A whole-stack start is what gets enforced.
case "${1:-}" in
  up|create|run|start|restart)
    if [ "${CV_SKIP_ENV_CHECK:-0}" != "1" ]; then
      targeted=0
      for a in "${@:2}"; do
        case "$a" in
          -*) ;;                      # flags (-d, --build, ...) are not service names
          *) targeted=1; break ;;
        esac
      done
      if [ "$targeted" = "1" ]; then
        "$here/scripts/validate-env.sh" || {
          echo
          echo "NOTE: targeted '$1' - continuing anyway (bootstrap path). The whole-stack"
          echo "      './cv.sh $1' will refuse until the above is fixed."
        }
      else
        "$here/scripts/validate-env.sh" || {
          echo
          echo "Refusing to '$1' the whole stack. Fix .env, or override once with:"
          echo "      CV_SKIP_ENV_CHECK=1 ./cv.sh $*"
          exit 1
        }
      fi
      echo
    fi
    ;;
esac

exec docker compose --env-file .env "${files[@]}" "$@"
