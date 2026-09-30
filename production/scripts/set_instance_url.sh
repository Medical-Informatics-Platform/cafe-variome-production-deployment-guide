#!/usr/bin/env bash
# Federation (FEDERATION.md): set the URL, and optionally the name, that this
# installation advertises to peers. The db-manager's first-run install seeds the URL as
# http://localhost:5000, which the network backend treats as unreachable. Peers must
# enter exactly this URL (https://$CV_PUBLIC_HOST) when they invite or add this host.
#
#   ./scripts/set_instance_url.sh ["Display name"]
#
# Local-infra mode only (writes to cv3-mongo). Run after the first full start.
# External infra: PATCH /api/config/global {"instanceSetting":{"url":...}} as server admin.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
export PATH="$HOME/bin:$PATH"   # rootless Docker CLI location (install-docker-rootless.yml)
[ -S "/run/user/$(id -u)/docker.sock" ] || {
  echo "ERROR: no rootless Docker for user $(id -un). Run this as the Docker user: sudo -iu dockeruser" >&2
  exit 1
}

[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
env_get() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" || true; }

host="$(env_get CV_PUBLIC_HOST)"
[ -n "$host" ] || { echo "ERROR: CV_PUBLIC_HOST is not set in .env"; exit 1; }
[ "$(env_get CV_LOCAL_INFRA)" = "1" ] || { echo "ERROR: local-infra mode only; see the header for external infra"; exit 1; }
mongo_user="$(env_get MONGO_ROOT_USERNAME)"; mongo_user="${mongo_user:-cv3root}"
mongo_pass="$(env_get MONGO_ROOT_PASSWORD)"
url="https://$host"

name="${1:-}"
if [ -n "$name" ] && [[ ! "$name" =~ ^[A-Za-z0-9\ ._-]+$ ]]; then
  echo "ERROR: name may contain only letters, digits, spaces, '.', '_' and '-'"; exit 1
fi
set_fields="url: '$url'"
[ -n "$name" ] && set_fields="$set_fields, name: '$name'"

matched="$(docker exec cv3-mongo mongosh --quiet -u "$mongo_user" -p "$mongo_pass" \
  --authenticationDatabase admin cafevariome \
  --eval "db.getCollection('instance.config').updateOne({id: 'InstanceConfig'}, {\$set: {$set_fields}}).matchedCount")"
if [ "$matched" != "1" ]; then
  echo "ERROR: no InstanceConfig document yet. Start the full stack first (./cv.sh up -d)."; exit 1
fi
echo "Instance URL set to $url${name:+, name '$name'}."

# The backends read InstanceConfig at startup.
./cv.sh restart cv3-backend-admin cv3-backend-query cv3-backend-network \
  cv3-backend-query-meta cv3-backend-scheduler
