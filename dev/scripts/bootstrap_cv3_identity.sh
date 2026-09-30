#!/usr/bin/env bash
set -euo pipefail

# Run this inside the VM (vagrant user). It assumes cv3 containers exist.
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed in this shell."
  exit 1
fi

for container in cv3-keycloak cv3-mongo cv3-vault; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "Container $container is not running. Start the stack first."
    exit 1
  fi
done

until curl -fsS http://127.0.0.1:8080/realms/master/.well-known/openid-configuration >/dev/null 2>&1; do
  echo "Waiting for Keycloak..."
  sleep 2
done

kcadm() {
  docker exec cv3-keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

kcadm config credentials --server http://localhost:8080 --realm master --user admin --password adminadmin >/dev/null

if ! kcadm get realms/cafe_variome >/dev/null 2>&1; then
  kcadm create realms -s realm=cafe_variome -s enabled=true >/dev/null
fi

CLIENT_JSON="$(kcadm get clients -r cafe_variome -q clientId=test_client)"
CID="$(printf '%s\n' "$CLIENT_JSON" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
if [ -z "$CID" ]; then
  kcadm create clients -r cafe_variome \
    -s clientId=test_client \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s rootUrl=http://127.0.0.1:5080 \
    -s baseUrl=http://127.0.0.1:5080 \
    -s 'redirectUris=["http://127.0.0.1:5080/callback.html","http://127.0.0.1:5080/callback-silent.html","http://127.0.0.1:5080/*","http://localhost:5080/callback.html","http://localhost:5080/callback-silent.html","http://localhost:5080/*"]' \
    -s 'webOrigins=["http://127.0.0.1:5080","http://localhost:5080"]' \
    -s secret=cv3-local-client-secret >/dev/null
  CLIENT_JSON="$(kcadm get clients -r cafe_variome -q clientId=test_client)"
  CID="$(printf '%s\n' "$CLIENT_JSON" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
else
  kcadm update clients/$CID -r cafe_variome \
    -s enabled=true \
    -s publicClient=false \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s rootUrl=http://127.0.0.1:5080 \
    -s baseUrl=http://127.0.0.1:5080 \
    -s 'redirectUris=["http://127.0.0.1:5080/callback.html","http://127.0.0.1:5080/callback-silent.html","http://127.0.0.1:5080/*","http://localhost:5080/callback.html","http://localhost:5080/callback-silent.html","http://localhost:5080/*"]' \
    -s 'webOrigins=["http://127.0.0.1:5080","http://localhost:5080"]' >/dev/null
  kcadm update clients/$CID -r cafe_variome -s secret=cv3-local-client-secret >/dev/null
fi

USER_JSON="$(kcadm get users -r cafe_variome -q email=admin@example.com)"
USER_ID="$(printf '%s\n' "$USER_JSON" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
if [ -z "$USER_ID" ]; then
  kcadm create users -r cafe_variome \
    -s username=test_client_admin \
    -s email=admin@example.com \
    -s emailVerified=true \
    -s enabled=true \
    -s firstName=Admin \
    -s lastName=CafeVariome >/dev/null
  kcadm set-password -r cafe_variome --username test_client_admin --new-password cv_admin >/dev/null
  USER_JSON="$(kcadm get users -r cafe_variome -q email=admin@example.com)"
  USER_ID="$(printf '%s\n' "$USER_JSON" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
fi

# Ensure test admin password is set for first login flow.
kcadm set-password -r cafe_variome --username test_client_admin --new-password cv_admin >/dev/null || true

docker exec cv3-mongo mongosh --quiet cafevariome --eval "db.getCollection('user.info').updateOne({userId:'$USER_ID'},{\$set:{userId:'$USER_ID',role:'developer',active:true,budget:100}},{upsert:true}); printjson(db.getCollection('user.info').find({userId:'$USER_ID'}).toArray())"

docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root cv3-vault sh -lc "vault secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true; vault secrets enable -path=transit_cv3 transit >/dev/null 2>&1 || true"
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root cv3-vault sh -lc "vault kv put kv/cv3 keycloak_client_secret=cv3-local-client-secret secret_key=devsecretkeydevsecretkeydev1234 >/dev/null && vault write transit_cv3/keys/$USER_ID type=rsa-4096 >/dev/null 2>&1 || true; vault write transit_cv3/keys/$USER_ID/config deletion_allowed=true >/dev/null"

echo "CLIENT_ID=test_client"
echo "CLIENT_UUID=$CID"
echo "ADMIN_USER_ID=$USER_ID"
