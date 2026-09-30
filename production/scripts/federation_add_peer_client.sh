#!/usr/bin/env bash
# Federation with a shared Keycloak (FEDERATION.md). Run on the installation that
# hosts the Keycloak (local-infra mode). Creates a confidential client for a peer
# installation in this realm and grants its service account the realm-management roles
# the peer's db-manager and admin backend need. Prints the values for the peer's .env.
# Running it again for the same peer rotates the client secret.
#
#   ./scripts/federation_add_peer_client.sh <peer-host> <peer-admin-email> [client-id]
#
# It also creates the peer's initial admin account (<client-id>_admin) in this realm with
# a temporary password: the peer's db-manager would otherwise try the fixed password
# "cv_admin", which this realm's password policy rejects.
#
# Then allow the peer's outbound IP to reach this realm's admin API:
#   CV_KC_ADMIN_PEERS="<peer-ip>/32 ..." in .env, then ./cv.sh up -d cv-proxy
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

usage="usage: $0 <peer-host> <peer-admin-email> [client-id]"
peer="${1:?$usage}"
admin_email="${2:?$usage}"
[[ "$peer" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: <peer-host> must be a bare hostname"; exit 1; }
[[ "$admin_email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || { echo "ERROR: <peer-admin-email> is not an email address"; exit 1; }
client="${3:-cv3-${peer//./-}}"
[[ "$client" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: client-id may contain only letters, digits, '_' and '-'"; exit 1; }

own_host="$(env_get CV_PUBLIC_HOST)"
realm="$(env_get KC_REALM)"; realm="${realm:-cafe_variome}"
kadmin="$(env_get KEYCLOAK_ADMIN)"; kadmin="${kadmin:-admin}"
kpass="$(env_get KEYCLOAK_ADMIN_PASSWORD)"
[ -n "$own_host" ] && [ -n "$kpass" ] || { echo "ERROR: CV_PUBLIC_HOST and KEYCLOAK_ADMIN_PASSWORD must be set in .env"; exit 1; }
[ "$client" != "$(env_get KC_CLIENT)" ] && [ "$client" != "test_client" ] \
  || { echo "ERROR: $client is this installation's own client"; exit 1; }

secret="$(openssl rand -hex 32)"
kc() { docker exec cv3-keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080/auth --realm master \
  --user "$kadmin" --password "$kpass" >/dev/null

redirects="[\"https://$peer/callback.html\",\"https://$peer/callback-silent.html\",\"https://$peer/*\"]"
origins="[\"https://$peer\"]"
cid="$(kc get clients -r "$realm" -q clientId="$client" | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n1)"
if [ -z "$cid" ]; then
  kc create clients -r "$realm" -s clientId="$client" -s enabled=true -s protocol=openid-connect \
    -s publicClient=false -s serviceAccountsEnabled=true -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s "rootUrl=https://$peer" -s "baseUrl=https://$peer" \
    -s "redirectUris=$redirects" -s "webOrigins=$origins" -s secret="$secret" >/dev/null
  echo "Created client $client in realm $realm."
else
  kc update "clients/$cid" -r "$realm" -s "redirectUris=$redirects" -s "webOrigins=$origins" \
    -s secret="$secret" >/dev/null
  echo "Client $client already existed: redirect URIs updated and secret ROTATED."
fi
for role in manage-users view-users query-users; do
  kc add-roles -r "$realm" --uusername "service-account-$client" \
    --cclientid realm-management --rolename "$role" >/dev/null
done

admin_user="${client}_admin"
admin_pass=""
if [ -n "$(kc get users -r "$realm" -q username="$admin_user" -q exact=true --fields id | grep '"id"')" ]; then
  echo "Admin account $admin_user already exists (password unchanged)."
else
  admin_pass="$(openssl rand -hex 12)"
  kc create users -r "$realm" -s username="$admin_user" -s email="$admin_email" \
    -s emailVerified=true -s enabled=true -s firstName=Admin -s "lastName=Cafe Variome" \
    -s 'requiredActions=["UPDATE_PASSWORD"]' >/dev/null
  kc set-password -r "$realm" --username "$admin_user" --new-password "$admin_pass" --temporary >/dev/null
  echo "Created admin account $admin_user <$admin_email>."
fi

cat <<EOF

Give these values to the operator of $peer, over a secure channel, for their .env:

  CV_FEDERATION=1
  CV_KEYCLOAK_URL=https://$own_host/auth/
  KC_CLIENT=$client
  KEYCLOAK_CLIENT_SECRET=$secret
  ADMIN_EMAIL=$admin_email

Their initial admin: $admin_user${admin_pass:+, temporary password $admin_pass (changed at first login)}

On this host:
  - add $peer to allowed_domains.federation.txt, then ./cv.sh restart cv-federation-proxy
  - add the peer's outbound IP to CV_KC_ADMIN_PEERS in .env, then ./cv.sh up -d cv-proxy
EOF
