#!/usr/bin/env bash
# Back up the self-contained local-infra state (CV_LOCAL_INFRA=1): MongoDB, the Vault
# file storage, the Keycloak Postgres, and the deployment secrets/config. Produces one
# timestamped tarball under production/backups/ (gitignored).
#
#   ./scripts/backup.sh                 # uses ./.env
#
# In EXTERNAL-infra production the databases/Vault are managed (and backed up) by their
# own operators - this script only covers what the local-infra overlay runs on this host.
# Run as the rootless Docker user from production/. Restore with scripts/restore.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; . ./.env; set +a
: "${MONGO_ROOT_USERNAME:?}"; : "${MONGO_ROOT_PASSWORD:?}"

HELPER_IMAGE="$(grep -oE 'redis:[0-9.]+-alpine@sha256:[0-9a-f]{64}' compose.local-infra.yml | head -1)"
[ -n "$HELPER_IMAGE" ] || {
  echo "ERROR: could not read the pinned helper image digest from compose.local-infra.yml."
  echo "       Refusing to fall back to an unpinned image for a Vault-volume backup."
  exit 1
}

TS="${1:-$(date +%Y%m%d-%H%M%S)}"
OUT="backups/$TS"; mkdir -p "$OUT"; chmod 700 backups "$OUT"
PROJECT="$(basename "$here")"   # compose project name = production dir name

echo "== MongoDB (mongodump, gzip archive) =="
docker exec cv3-mongo mongodump --quiet --archive --gzip \
  -u "$MONGO_ROOT_USERNAME" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin \
  > "$OUT/mongo.archive.gz"

echo "== Keycloak Postgres (pg_dump) =="
# --clean --if-exists: the dump carries DROP ... IF EXISTS statements, so restore.sh
# can apply it to a database that already has the Keycloak schema (a plain dump would
# fail on every CREATE with "already exists").
docker exec cv3-keycloak-postgres sh -c "pg_dump --clean --if-exists -U \"\${POSTGRES_USER:-keycloak}\" keycloak" | gzip > "$OUT/keycloak-pg.sql.gz"

echo "== Vault file storage (volume tar) =="
# Vault file backend has no snapshot API; tar the data volume. Unseal keys live in
# secrets/vault-init.json (also captured below) - both are needed to restore + unseal.
docker run --rm --network none \
  -v "${PROJECT}_cv_vault_data:/data:ro" -v "$here/$OUT:/backup" \
  --entrypoint sh "$HELPER_IMAGE" -c "tar czf /backup/vault-data.tgz -C /data ."

echo "== Secrets + rendered config =="
tar czf "$OUT/config-secrets.tgz" .env secrets config/*.json 2>/dev/null || true

chmod -R go-rwx "$OUT"
( cd backups && tar cf "$TS.tar" "$TS" && rm -rf "$TS" )
chmod 600 "backups/$TS.tar"

ARCHIVE="backups/$TS.tar"
if [ -n "${CV_BACKUP_AGE_RECIPIENT:-}" ]; then
  command -v age >/dev/null || { echo "ERROR: CV_BACKUP_AGE_RECIPIENT set but 'age' is not installed."; exit 1; }
  echo "== Encrypting with age -> $ARCHIVE.age =="
  age -r "$CV_BACKUP_AGE_RECIPIENT" -o "$ARCHIVE.age" "$ARCHIVE"
  chmod 600 "$ARCHIVE.age"; shred -u "$ARCHIVE" 2>/dev/null || rm -f "$ARCHIVE"
  ARCHIVE="$ARCHIVE.age"
elif [ -n "${CV_BACKUP_GPG_RECIPIENT:-}" ]; then
  command -v gpg >/dev/null || { echo "ERROR: CV_BACKUP_GPG_RECIPIENT set but 'gpg' is not installed."; exit 1; }
  echo "== Encrypting with gpg -> $ARCHIVE.gpg =="
  gpg --batch --yes --trust-model always -r "$CV_BACKUP_GPG_RECIPIENT" -o "$ARCHIVE.gpg" -e "$ARCHIVE"
  chmod 600 "$ARCHIVE.gpg"; shred -u "$ARCHIVE" 2>/dev/null || rm -f "$ARCHIVE"
  ARCHIVE="$ARCHIVE.gpg"
fi

echo
echo "DONE -> $here/$ARCHIVE"
case "$ARCHIVE" in
  *.age|*.gpg) echo "  Encrypted at rest. Keep the decryption key OFF this host." ;;
  *)
    echo "  !! PLAINTEXT. Contains the Vault unseal shares, full DB dumps and .env -"
    echo "     one file is the whole system. Set CV_BACKUP_AGE_RECIPIENT (or"
    echo "     CV_BACKUP_GPG_RECIPIENT) in .env to encrypt it here."
    ;;
esac
echo "  Move it off-host; nothing in this repo schedules or ships backups for you."
