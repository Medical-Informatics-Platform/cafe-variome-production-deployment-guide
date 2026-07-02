#!/usr/bin/env bash
# Restore a local-infra backup produced by scripts/backup.sh.
#
#   ./scripts/restore.sh backups/20260630-120000.tar
#
# DESTRUCTIVE: overwrites the current MongoDB, Keycloak Postgres and Vault data. Bring the
# stack up first (./cv.sh up -d) so the infra containers exist, then run this, then unseal
# Vault (the restored data is sealed with the ORIGINAL keys from secrets/vault-init.json).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
ARCHIVE="${1:?usage: restore.sh <backups/TIMESTAMP.tar>}"
[ -f "$ARCHIVE" ] || { echo "ERROR: $ARCHIVE not found"; exit 1; }
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; . ./.env; set +a
PROJECT="$(basename "$here")"

read -r -p "This OVERWRITES current Mongo/Keycloak/Vault data. Type 'restore' to proceed: " ok
[ "$ok" = "restore" ] || { echo "aborted"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar xf "$ARCHIVE" -C "$TMP"; SRC="$TMP/$(ls "$TMP")"

echo "== Mongo restore (drop + mongorestore) =="
docker exec -i cv3-mongo mongorestore --quiet --archive --gzip --drop \
  -u "$MONGO_ROOT_USERNAME" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin < "$SRC/mongo.archive.gz"

echo "== Keycloak Postgres restore =="
gunzip -c "$SRC/keycloak-pg.sql.gz" | docker exec -i cv3-keycloak-postgres sh -c "psql -U \"\${POSTGRES_USER:-keycloak}\" -d keycloak"

echo "== Vault data restore (stop vault, replace volume contents, start) =="
docker stop cv3-vault >/dev/null
docker run --rm -v "${PROJECT}_cv_vault_data:/data" -v "$SRC:/backup:ro" \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/vault-data.tgz -C /data"
docker start cv3-vault >/dev/null

echo
echo "DONE. Now: ./scripts/unseal_vault.sh   (uses the ORIGINAL unseal keys), then"
echo "      ./cv.sh restart \$(./cv.sh config --services | grep cv3-backend)"
