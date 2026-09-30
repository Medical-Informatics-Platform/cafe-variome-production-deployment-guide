# CV3 production deployment

Runs Cafe Variome v3 with rootless Docker on a host provisioned as described in [../README.md](../README.md). The security controls and their trade-offs are described in [SECURITY.md](SECURITY.md).

Run every command in this directory through `./cv.sh`. It is a wrapper around `docker compose` that chooses the compose overlays from `.env`.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | The 7 CV3 app containers. Images are pinned by digest; no host ports are published. |
| `compose.hardening.yml` | Per-container hardening: read-only root filesystem, dropped capabilities, tmpfs, non-root uids. |
| `compose.local-infra.yml` | Keycloak, Vault, MongoDB and Redis, for local-infra mode. |
| `compose.egress.yml` | Squid egress proxy, for external-infra mode. |
| `compose.reverse-proxy.yml` | Caddy TLS reverse proxy, plus a Squid that allows only ACME traffic. |
| `cv.sh` | `docker compose` wrapper. |
| `Caddyfile.reverse-proxy`, `squid.*.conf`, `allowed_domains.*.txt` | Proxy routing and egress allowlists. |
| `vault/vault.hcl` | Vault server config. |
| `config/` | App config templates. See [config/README.md](config/README.md). |
| `deploy/`, `scripts/apply-host-tuning.sh` | Host settings that the CIS baseline does not provide. |
| `scripts/` | Bootstrap, config rendering, validation, unseal, backup and restore. |
| `inventory/` | Ansible examples used by [../README.md](../README.md). |

## Deployment modes

Two variables in `.env` decide which overlays `cv.sh` loads.

| Variable | Value | Effect |
|---|---|---|
| `CV_LOCAL_INFRA` | `1` | Keycloak, Vault, MongoDB and Redis run on this host. Suited to a single-host deployment. |
| | unset | External infra: you provide Keycloak, Vault, MongoDB and Redis. The backends reach them through the egress proxy. Recommended for production. |
| `CV_PUBLIC_HOST` | hostname | Enables the Caddy TLS reverse proxy on ports 80/443, the only public entry point. |
| | unset | No public entry point. |

## 1. Host tuning

Run once as an admin user. This step is required: without it, containers fail to start and the proxy cannot bind 80/443.

```bash
sudo ./scripts/apply-host-tuning.sh dockeruser
```

It raises the file and process limits, allows binding ports 80 and above without root, sets limits for the rootless daemon, and makes the systemd journal persistent.

## 2. Configure

Copy `production/` to `dockeruser`'s home directory, for example `~/cafe-variome/production`, and make sure `dockeruser` owns it. Run everything from here on as `dockeruser`.

```bash
cp .env.template .env
chmod +x cv.sh scripts/*.sh
```

Edit `.env` and replace every `CHANGE_ME`. Generate secrets with `openssl rand -hex 32`. MongoDB passwords must be alphanumeric.

| Variable | Required when | Notes |
|---|---|---|
| `KEYCLOAK_CLIENT_SECRET`, `ADMIN_EMAIL`, `ADMIN_AFFILIATION` | always | Used during first-run install. |
| `VAULT_ROLE_ID`, `VAULT_SECRET_ID` | always | Local infra: leave as `CHANGE_ME`; the bootstrap script fills them in. External infra: get them from your Vault. |
| `CV_PUBLIC_HOST` | TLS proxy | For example `cafevariome.example.org`, or `<ip>.sslip.io` on a test machine without DNS. |
| `ACME_EMAIL` | TLS proxy | Let's Encrypt account email. |
| `CV_TLS=internal` | optional | Uses a self-signed certificate instead of Let's Encrypt, and makes `ACME_EMAIL` unnecessary. For test machines without DNS. Not in the template; add it yourself. |
| `KEYCLOAK_ADMIN_PASSWORD`, `KC_DB_PASSWORD`, `MONGO_ROOT_PASSWORD`, `MONGO_APP_PASSWORD` | local infra | |
| `CV_BACKUP_AGE_RECIPIENT` or `CV_BACKUP_GPG_RECIPIENT` | recommended | Encrypts backups. See [Backup](#backup). |

In external-infra mode, also list your Keycloak and Vault hosts in `allowed_domains.cv-egress.txt`.

Render the app config:

```bash
./scripts/render-config.sh
```

This writes `config/*.json`. It needs `CV_PUBLIC_HOST` and `MONGO_APP_PASSWORD` to be set in every mode.

`cv.sh` runs `scripts/validate-env.sh` before any command that starts containers. If a required value is missing or still a placeholder, a whole-stack start is refused; a start of named services only prints a warning. To skip the check once, set `CV_SKIP_ENV_CHECK=1`.

## 3. Deploy

### Local infra

The backends need Vault AppRole credentials, and those only exist after Vault has been initialised. So start the infra first, bootstrap it, then start the rest.

```bash
# 1. Start the infra containers only
./cv.sh up -d cv3-vault cv3-mongo cv3-redis cv3-keycloak-postgres cv3-keycloak

# 2. Initialise and unseal Vault, create the AppRole, Keycloak realm/client and Mongo app user.
#    Writes VAULT_ROLE_ID/VAULT_SECRET_ID to .env and the unseal keys to secrets/vault-init.json.
./scripts/bootstrap_local_infra.sh

# 3. Copy secrets/vault-init.json to offline storage, then delete it from the host.

# 4. Start everything. On first start the db-manager seeds MongoDB and Vault and creates the initial admin.
./cv.sh up -d
./cv.sh logs -f cv3-backend-dbm
```

The initial admin user is `test_client_admin`, with the temporary password `cv_admin`. You must change it at first login.

### External infra

Skip steps 1 to 3. Set the `cv3-*` hostnames in `config/backend_config.json` to your endpoints. Vault must already have the CV3 AppRole, and Keycloak must already have the realm and client. Then run `./cv.sh up -d`.

## 4. Verify

```bash
H="$CV_PUBLIC_HOST"
for p in / /api/ /query/ /federation/; do curl -sko /dev/null -w "$p %{http_code}\n" "https://$H$p"; done
curl -sk "https://$H/auth/realms/cafe_variome/.well-known/openid-configuration" | grep -o '"issuer":"[^"]*"'
```

Every route should return `200`, and the issuer should be `https://$CV_PUBLIC_HOST/auth/realms/cafe_variome`.

## 5. Operations

### Unseal Vault

Vault starts sealed after every host or Vault restart. Unseal it, then restart the backends with `./cv.sh restart`.

```bash
./scripts/unseal_vault.sh --stdin                               # paste 3 shares, then Ctrl-D
CV_UNSEAL_KEYS="$(pass cv3/unseal)" ./scripts/unseal_vault.sh   # or read them from a secret manager
```

If neither is given, the script reads `secrets/vault-init.json` and prints a warning.

### Backup

Local infra only. In external-infra mode, your managed services handle their own backups.

```bash
./scripts/backup.sh
```

This writes one tarball under `backups/`. It contains the Mongo dump, the Keycloak Postgres dump, Vault data, `.env`, `secrets/` and the rendered config. If `CV_BACKUP_AGE_RECIPIENT` or `CV_BACKUP_GPG_RECIPIENT` is set, the tarball is encrypted and the plaintext copy is deleted. Nothing in this repo schedules backups or copies them off the host; set that up yourself, for example with a cron job for `dockeruser`.

### Restore

Accepts `.tar`, `.tar.age` and `.tar.gpg`.

```bash
./scripts/restore.sh backups/<timestamp>.tar   # stops the backends and Keycloak, restores the data, restarts the infra
./scripts/unseal_vault.sh --stdin              # use the unseal shares from when the backup was taken
./cv.sh up -d
```

If the current `.env` has AppRole credentials newer than the backup, first restore `.env` from `config-secrets.tgz` inside the tarball.

### Rotate credentials

- The Vault AppRole `secret_id` expires 90 days after it is issued. You can change this with `VAULT_APPROLE_SECRET_ID_TTL` before running the bootstrap. Nothing warns you when it is about to expire. To rotate it, you need a Vault token with the `cv3` policy. The bootstrap revokes the root token; to get a new one, run `vault operator generate-root`.

  ```bash
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=<token> cv3-vault \
    vault write -f -field=secret_id auth/approle/role/cv3/secret-id
  # Put the new value in .env as VAULT_SECRET_ID, then:
  ./cv.sh up -d
  ```

- After go-live, rotate `KEYCLOAK_CLIENT_SECRET` and the initial admin password. Replace the shared Keycloak bootstrap admin with personal admin accounts.

### Logs

All containers log to the host journal, which keeps logs for 1 year up to 10 GB.

```bash
sudo journalctl CONTAINER_NAME=cv-proxy --since "2026-01-01"   # HTTP access log
journalctl --disk-usage
```

### Image updates

Renovate opens pull requests that update image digests. CV3 app images and infra images are grouped separately, and major versions wait for approval on the dependency dashboard.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Nothing listens on 80/443 | `apply-host-tuning.sh` has not been run. |
| 502 from a backend | The backend listens on `127.0.0.1`. The compose file sets `CV3_BIND=0.0.0.0:5000`; check that it is present. |
| Keycloak admin or login returns 404 | `Keycloak.URL` and `BackendURL` in `config/backend_config.json` must end with `/`. |
| `PermissionError` when a container reads its config | Run `./scripts/render-config.sh` again. It makes the rendered files readable by the container user. |
