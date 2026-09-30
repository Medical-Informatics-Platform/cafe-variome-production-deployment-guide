#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed in this shell."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'cv3-keycloak'; then
  echo "Container cv3-keycloak is not running. Start the stack first."
  exit 1
fi

until curl -fsS http://127.0.0.1:8080/realms/master/.well-known/openid-configuration >/dev/null 2>&1; do
  echo "Waiting for Keycloak..."
  sleep 2
done

docker exec cv3-keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password adminadmin >/dev/null
CID=$(docker exec cv3-keycloak /opt/keycloak/bin/kcadm.sh get clients -r cafe_variome -q clientId=test_client | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)

if [ -z "${CID}" ]; then
  echo "Could not find client test_client in realm cafe_variome."
  exit 1
fi

docker exec cv3-keycloak /opt/keycloak/bin/kcadm.sh update clients/${CID} -r cafe_variome \
  -s rootUrl=http://127.0.0.1:5080 \
  -s baseUrl=http://127.0.0.1:5080 \
  -s 'redirectUris=["http://127.0.0.1:5080/callback.html","http://127.0.0.1:5080/callback-silent.html","http://127.0.0.1:5080/*","http://localhost:5080/callback.html","http://localhost:5080/callback-silent.html","http://localhost:5080/*"]' \
  -s 'webOrigins=["http://127.0.0.1:5080","http://localhost:5080"]' >/dev/null

echo "CID=${CID}"
