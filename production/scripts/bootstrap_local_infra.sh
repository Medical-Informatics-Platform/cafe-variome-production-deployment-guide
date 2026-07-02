#!/usr/bin/env bash
# One-time bootstrap for the self-contained local-infra overlay (CV_LOCAL_INFRA=1):
#   1. Vault: initialise (if needed) + unseal, then enable AppRole/KV-v2/transit and
#      seed the CV3 policy/role/secrets; write VAULT_ROLE_ID/SECRET_ID back to .env.
#   2. Keycloak: create the realm + CV3 client (prod redirect/web-origins) + admin user.
#   3. MongoDB: upsert the admin user.info doc + the user's transit key.
#
# Adapted from staging/scripts/bootstrap_cv3_vault.sh + bootstrap_cv3_identity.sh, but for
# NON-dev Vault (real root token from init, not "root") and production credentials
# (KEYCLOAK_ADMIN_PASSWORD, MONGO_ROOT_PASSWORD) + HTTPS reverse-proxy URLs.
#
# Run as the rootless Docker user from production/ AFTER `./cv.sh up -d` is healthy.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

[ -f .env ] || { echo "ERROR: .env not found (cp .env.template .env)"; exit 1; }
set -a; . ./.env; set +a
: "${CV_PUBLIC_HOST:?set CV_PUBLIC_HOST in .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD in .env}"
: "${KEYCLOAK_CLIENT_SECRET:?set KEYCLOAK_CLIENT_SECRET in .env}"
: "${MONGO_ROOT_PASSWORD:?set MONGO_ROOT_PASSWORD in .env}"
KADMIN="${KEYCLOAK_ADMIN:-admin}"
REALM="${KC_REALM:-cafe_variome}"
CLIENT="${KC_CLIENT:-test_client}"
ADMIN_MAIL="${ADMIN_EMAIL:-admin@example.org}"
MONGO_USER="${MONGO_ROOT_USERNAME:-cv3root}"
MONGO_APP_USERNAME="${MONGO_APP_USERNAME:-cv3app}"
: "${MONGO_APP_PASSWORD:?set MONGO_APP_PASSWORD in .env}"
mkdir -p secrets && chmod 700 secrets
INIT="secrets/vault-init.json"

vstatus() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault vault status -format=json 2>/dev/null; }
vt() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" cv3-vault vault "$@"; }
# Vault is "ready to talk to" once its API answers - whether unsealed (exit 0) or
# sealed (exit 2). Before bootstrap, a fresh Vault is sealed+uninitialised, so waiting
# for exit 0 here would loop forever (we are the thing that unseals it). Exit 1 = the
# API is not up yet.
vready() { local rc; docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault vault status >/dev/null 2>&1; rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; }

echo "== Vault: wait for API =="
until vready; do echo "  waiting for cv3-vault API..."; sleep 2; done

if [ "$(vstatus | python3 -c 'import json,sys;print(json.load(sys.stdin)["initialized"])')" != "True" ]; then
  echo "== Vault: initialising (unseal keys + root token -> $INIT - MOVE OFFLINE) =="
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault \
    vault operator init -key-shares=5 -key-threshold=3 -format=json > "$INIT"
  chmod 600 "$INIT"
fi
ROOT_TOKEN="$(python3 -c "import json;print(json.load(open('$INIT'))['root_token'])")"

if [ "$(vstatus | python3 -c 'import json,sys;print(json.load(sys.stdin)["sealed"])')" = "True" ]; then
  echo "== Vault: unsealing =="
  for i in 0 1 2; do
    k="$(python3 -c "import json;print(json.load(open('$INIT'))['unseal_keys_b64'][$i])")"
    docker exec -e VAULT_ADDR=http://127.0.0.1:8200 cv3-vault vault operator unseal "$k" >/dev/null
  done
fi

echo "== Vault: CV3 approle / kv-v2 / transit =="
vt auth enable approle  >/dev/null 2>&1 || true
vt secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true
vt secrets enable -path=transit_cv3 transit >/dev/null 2>&1 || true
docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" cv3-vault sh -c 'cat > /tmp/cv3-policy.hcl' <<'POL'
path "kv/data/cv3"        { capabilities = ["create","update","read"] }
path "kv/metadata/cv3"    { capabilities = ["read","list"] }
# delete: the db-manager's periodic cleanup removes departed users' transit keys
# (the app marks keys deletion_allowed at creation); without it the cleanup job
# fails with hvac Forbidden on every cycle after any user deletion.
path "transit_cv3/keys/*"    { capabilities = ["create","read","update","list","delete"] }
path "transit_cv3/sign/*"    { capabilities = ["create","update","read"] }
path "transit_cv3/verify/*"  { capabilities = ["create","update","read"] }
path "transit_cv3/encrypt/*" { capabilities = ["create","update","read"] }
path "transit_cv3/decrypt/*" { capabilities = ["create","update","read"] }
POL
vt policy write cv3-policy /tmp/cv3-policy.hcl >/dev/null
vt write auth/approle/role/cv3 token_policies="cv3-policy" >/dev/null
ROLE_ID="$(vt read -field=role_id auth/approle/role/cv3/role-id)"
SECRET_ID="$(vt write -field=secret_id -f auth/approle/role/cv3/secret-id)"
vt kv put kv/cv3 keycloak_client_secret="$KEYCLOAK_CLIENT_SECRET" secret_key="$(openssl rand -hex 16)" >/dev/null
sed -i "s|^VAULT_ROLE_ID=.*|VAULT_ROLE_ID=${ROLE_ID}|"   .env
sed -i "s|^VAULT_SECRET_ID=.*|VAULT_SECRET_ID=${SECRET_ID}|" .env
echo "   VAULT_ROLE_ID/SECRET_ID written to .env (restart backends to pick up)."

# NOTE: this script only provisions the PREREQUISITES the cv3 db-manager cannot create
# itself - a unsealed Vault with the cv3 AppRole, and a Keycloak realm+client whose
# service account it logs in as. On first start the db-manager's non_interactive_install
# then does the actual app install (drops+seeds Mongo incl. the config docs, writes the
# Vault KV secret, and creates the initial admin user in Keycloak+Mongo+Vault-transit
# from KEYCLOAK_CLIENT_SECRET/ADMIN_EMAIL/ADMIN_AFFILIATION). So we deliberately do NOT
# create the admin user / user.info / transit key here.

echo "== Keycloak: realm + client (+ service-account roles the db-manager needs) =="
kc() { docker exec cv3-keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
until kc config credentials --server http://localhost:8080/auth --realm master --user "$KADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1; do
  echo "  waiting for cv3-keycloak..."; sleep 3
done
kc get "realms/$REALM" >/dev/null 2>&1 || kc create realms -s "realm=$REALM" -s enabled=true >/dev/null
CID="$(kc get clients -r "$REALM" -q clientId="$CLIENT" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
REDIR="[\"https://$CV_PUBLIC_HOST/callback.html\",\"https://$CV_PUBLIC_HOST/callback-silent.html\",\"https://$CV_PUBLIC_HOST/*\"]"
ORIGINS="[\"https://$CV_PUBLIC_HOST\"]"
if [ -z "$CID" ]; then
  kc create clients -r "$REALM" -s clientId="$CLIENT" -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s serviceAccountsEnabled=true -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s "rootUrl=https://$CV_PUBLIC_HOST" -s "baseUrl=https://$CV_PUBLIC_HOST" \
    -s "redirectUris=$REDIR" -s "webOrigins=$ORIGINS" -s secret="$KEYCLOAK_CLIENT_SECRET" >/dev/null
  CID="$(kc get clients -r "$REALM" -q clientId="$CLIENT" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
else
  kc update "clients/$CID" -r "$REALM" -s "redirectUris=$REDIR" -s "webOrigins=$ORIGINS" -s secret="$KEYCLOAK_CLIENT_SECRET" >/dev/null
fi
# The db-manager logs into Keycloak as this client's service account (client-credentials)
# and calls create_user for the initial admin, so grant it the realm-management rights
# to manage/view users in this realm.
for role in manage-users view-users query-users; do
  kc add-roles -r "$REALM" --uusername "service-account-${CLIENT}" --cclientid realm-management --rolename "$role" >/dev/null 2>&1 \
    || echo "  WARN: could not grant realm-management:$role to service-account-${CLIENT}"
done

echo "== Keycloak: realm hardening (brute force, audit events, password policy) =="
# Best-practice realm settings for a public deployment (idempotent):
#  - brute-force detection: temporary account lockout on repeated failed logins
#    (permanentLockout stays false - no self-inflicted DoS on shared accounts).
#  - login + admin EVENT auditing, retained ~1 year in Keycloak's DB (eventsExpiration
#    is seconds) - complements the host journal, which captures the containers' logs.
#  - a minimum password policy; applies on next password (re)set, so the dbm-created
#    temporary admin password still works and must be upgraded at first login.
kc update "realms/$REALM" \
  -s bruteForceProtected=true -s failureFactor=10 \
  -s 'passwordPolicy=length(12) and notUsername' >/dev/null
kc update "events/config" -r "$REALM" \
  -s eventsEnabled=true -s eventsExpiration=31536000 \
  -s adminEventsEnabled=true -s adminEventsDetailsEnabled=true >/dev/null
echo "   brute-force on, events on (1y), passwordPolicy=length(12)+notUsername"

echo "== Mongo: app user with dbOwner (the db-manager's init_db drops + recreates the DB) =="
mongo_root() { docker exec cv3-mongo mongosh --quiet -u "$MONGO_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin cafevariome --eval "$1"; }
mongo_root "db.getSiblingDB('cafevariome').runCommand({createUser:'$MONGO_APP_USERNAME',pwd:'$MONGO_APP_PASSWORD',roles:[{role:'dbOwner',db:'cafevariome'}]})" 2>/dev/null \
  || mongo_root "db.getSiblingDB('cafevariome').updateUser('$MONGO_APP_USERNAME',{pwd:'$MONGO_APP_PASSWORD',roles:[{role:'dbOwner',db:'cafevariome'}]})"

echo
echo "DONE (prerequisites provisioned)."
echo "  realm=$REALM client=$CLIENT  (service account: service-account-$CLIENT)"
echo "  Vault AppRole seeded; VAULT_ROLE_ID/SECRET_ID written to .env."
echo "  Next: ./cv.sh up -d  - the db-manager will run the first-run install (DB seed,"
echo "        Vault KV, and create the admin user '${CLIENT}_admin' for ${ADMIN_MAIL})."
echo "        Watch it with: ./cv.sh logs -f cv3-backend-dbm"
echo "  Vault unseal keys + root token are in $INIT - MOVE THEM OFFLINE and delete from the server."
echo "  Re-unseal after any restart: ./scripts/unseal_vault.sh ; then ./cv.sh restart <backends>"
