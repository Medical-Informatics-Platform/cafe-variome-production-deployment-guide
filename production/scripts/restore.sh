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

BACKENDS="cv3-backend-admin cv3-backend-query cv3-backend-network cv3-backend-query-meta cv3-backend-dbm cv3-backend-scheduler"

echo "== Stop writers (backends + Keycloak) so the restore is consistent =="
docker stop $BACKENDS cv3-keycloak >/dev/null

echo "== Mongo restore (drop DB, then mongorestore) =="
# Drop the app database FIRST: mongorestore --drop only drops collections that exist
# in the archive, so collections created after the backup would otherwise survive the
# restore (not a true point-in-time restore). Users live in admin.system.users and are
# restored from the archive itself.
docker exec cv3-mongo mongosh --quiet -u "$MONGO_ROOT_USERNAME" -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin --eval "db.getSiblingDB('cafevariome').dropDatabase()" >/dev/null
docker exec -i cv3-mongo mongorestore --quiet --archive --gzip --drop \
  -u "$MONGO_ROOT_USERNAME" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin < "$SRC/mongo.archive.gz"

echo "== Keycloak Postgres restore (dump carries DROP..IF EXISTS; Keycloak is stopped) =="
gunzip -c "$SRC/keycloak-pg.sql.gz" | docker exec -i cv3-keycloak-postgres sh -c "psql -q -U \"\${POSTGRES_USER:-keycloak}\" -d keycloak" >/dev/null

echo "== Vault data restore (stop vault, replace volume contents, start) =="
docker stop cv3-vault >/dev/null
docker run --rm -v "${PROJECT}_cv_vault_data:/data" -v "$SRC:/backup:ro" \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/vault-data.tgz -C /data"
docker start cv3-vault cv3-keycloak >/dev/null

echo
echo "DONE. Restored state is from the backup; anything written since is gone (by design)."
echo "  1. ./scripts/unseal_vault.sh          # Vault boots sealed; ORIGINAL unseal keys"
echo "  2. ./cv.sh up -d                      # start the stopped backends again"
echo "  If the backup's VAULT_ROLE_ID/SECRET_ID differ from the current .env, restore"
echo "  the .env from the backup's config-secrets.tgz too, then ./cv.sh up -d."
