#!/usr/bin/env bash
# Federation with a shared Keycloak (FEDERATION.md). Run on the installation that
# hosts the Keycloak (local-infra mode). Creates a confidential client for a peer
# installation in this realm and grants its service account the realm-management roles
# the peer's db-manager and admin backend need. Prints the values for the peer's .env.
# Running it again for the same peer rotates the client secret.
#
#   ./scripts/federation_add_peer_client.sh <peer-host> [client-id]
#
# Then allow the peer's outbound IP to reach this realm's admin API:
#   CV_KC_ADMIN_PEERS="<peer-ip>/32 ..." in .env, then ./cv.sh up -d cv-proxy
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
env_get() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" || true; }

peer="${1:?usage: $0 <peer-host> [client-id]}"
[[ "$peer" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: <peer-host> must be a bare hostname"; exit 1; }
client="${2:-cv3-${peer//./-}}"
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

cat <<EOF

Give these values to the operator of $peer, over a secure channel, for their .env:

  CV_FEDERATION=1
  CV_KEYCLOAK_URL=https://$own_host/auth/
  KC_CLIENT=$client
  KEYCLOAK_CLIENT_SECRET=$secret

On this host:
  - add $peer to allowed_domains.federation.txt, then ./cv.sh restart cv-federation-proxy
  - add the peer's outbound IP to CV_KC_ADMIN_PEERS in .env, then ./cv.sh up -d cv-proxy
EOF
