# CV3 - hardened production deployment layer

This directory deploys Cafe Variome v3 on a **CIS-hardened, rootless-Docker** host with per-container least privilege, network segmentation, forced egress, a TLS reverse proxy, and digest-pinned images. For the *why* behind every control and the documented trade-offs, see [SECURITY.md](SECURITY.md).

> The top-level [../README.md](../README.md) covers the original manual flow. **This layer supersedes it** for hardened deployments - drive everything through `./cv.sh`.

## Layout

| File | Purpose |
|---|---|
| `docker-compose.yml` | the 7 CV3 app containers (digest-pinned, no host ports) |
| `compose.hardening.yml` | per-container hardening overlay (read-only, caps, tmpfs, uids) |
| `compose.local-infra.yml` | optional self-contained Keycloak + Vault + MongoDB + Redis |
| `compose.egress.yml` | forced-egress Squid for **external** infra mode |
| `compose.reverse-proxy.yml` | Caddy TLS ingress + ACME-only egress Squid |
| `cv.sh` | wrapper that stacks the right overlays (reads toggles from `.env`) |
| `Caddyfile.reverse-proxy`, `squid.*.conf`, `allowed_domains.*.txt` | proxy policy |
| `vault/vault.hcl` | non-dev Vault config (file storage, persistent) |
| `config/*.template` | config rendered to `config/*.json` by `scripts/render-config.sh` |
| `deploy/*.conf` | host drop-ins applied by `scripts/apply-host-tuning.sh` |
| `scripts/` | bootstrap, render, validate, unseal, backup/restore, host-tuning |

### Deployment modes (set in `.env`, read by `cv.sh`)

- **External infra (recommended production)** - `CV_LOCAL_INFRA` unset. You provide Keycloak / Vault / MongoDB / Redis; backends reach them through the forced-egress Squid (`compose.egress.yml`). Point the `cv3-*` hostnames in `config/backend_config.json` at your real endpoints.
- **Local infra (single host / test)** - `CV_LOCAL_INFRA=1`. Runs hardened Keycloak + Vault (non-dev) + MongoDB + Redis alongside CV3 (`compose.local-infra.yml`).
- Set `CV_PUBLIC_HOST` to enable the TLS reverse proxy (sole public ingress on 80/443).

## 1. Host prerequisites

Provision a Debian/Ubuntu server on any platform, then from your control machine run the repo's two playbooks (see [../README.md](../README.md) §2–4):

```bash
ansible-playbook -i <inventory> -l cafe-variome-node setup-playbook.yml          # CIS hardening + users + UFW
ansible-playbook -i <inventory> -l cafe-variome-node install-docker-rootless.yml # rootless Docker
```

Use the examples in [`inventory/`](inventory/) - note the host must be **named** `cafe-variome-node` with its address in `ansible_host` so the `host_vars/` apply, and `POST_RUN_EXTRA_COMMANDS` must re-open 80/443 (the hardening UFW pass deletes unmanaged inbound rules).

Then apply the host tuning the CIS baseline omits (raises ulimits, lets rootless bind 80/443, sets the rootless daemon limits) - **required**, or the stack can't start its containers or publish 80/443:

```bash
sudo ./scripts/apply-host-tuning.sh dockeruser
```

## 2. Configure

Copy `production/` to the rootless user's home (e.g. `/home/dockeruser/cafe-variome/`, owned by `dockeruser`), then as **dockeruser**:

```bash
cd ~/cafe-variome/production
cp .env.template .env
# Fill every CHANGE_ME. Generate strong, URL-safe values:  openssl rand -hex 32
#   - CV_LOCAL_INFRA=1            (local-infra mode) or leave unset (external)
#   - CV_PUBLIC_HOST=cafevariome.example.org   (or <ip>.sslip.io for a no-DNS test box)
#   - ACME_EMAIL=you@example.org   (real Let's Encrypt) - or set CV_TLS=internal for a
#                                   self-signed cert on a no-DNS box
#   - KEYCLOAK_ADMIN_PASSWORD, KC_DB_PASSWORD, MONGO_ROOT_PASSWORD, MONGO_APP_PASSWORD,
#     KEYCLOAK_CLIENT_SECRET            (local-infra)
chmod +x cv.sh scripts/*.sh
./scripts/render-config.sh           # config/*.template -> config/*.json (host-readable)
```

`VAULT_ROLE_ID`/`VAULT_SECRET_ID` stay `CHANGE_ME` for now - the bootstrap fills them.

## 3. Deploy (local-infra mode)

The backends need Vault AppRole credentials that only exist after Vault is initialised, so bring up the **infra first**, bootstrap, then the rest:

```bash
# 3a. infra only
./cv.sh up -d cv3-vault cv3-mongo cv3-redis cv3-keycloak-postgres cv3-keycloak

# 3b. provision prerequisites: init+unseal Vault, AppRole/policy/transit, Keycloak realm+
#     client (+ service-account roles), Mongo app user (dbOwner). Writes VAULT_ROLE_ID/
#     SECRET_ID + the unseal keys (secrets/vault-init.json).
./scripts/bootstrap_local_infra.sh

# 3c. MOVE secrets/vault-init.json OFFLINE, then delete it from the host.

# 3d. start everything. On first start the db-manager runs the app install
#     (seeds Mongo incl. config docs, writes the Vault KV, creates the initial admin).
./cv.sh up -d
./cv.sh logs -f cv3-backend-dbm          # watch: "Created initial admin user ... with password cv_admin"

./scripts/validate-env.sh                # fail-closed gate - all secrets set
```

The initial admin is `test_client_admin` (temp password `cv_admin`, must change at first login). For **external-infra mode**, skip 3a–3c, point `config/backend_config.json` at your real endpoints, and ensure that Vault/Keycloak already hold the CV3 AppRole + realm/client.

## 4. Verify

```bash
H="$CV_PUBLIC_HOST"
curl -sko /dev/null -w '/            %{http_code}\n' https://$H/
curl -sko /dev/null -w '/api         %{http_code}\n' https://$H/api/
curl -sko /dev/null -w '/query       %{http_code}\n' https://$H/query/
curl -sko /dev/null -w '/federation  %{http_code}\n' https://$H/federation/
curl -sk https://$H/auth/realms/cafe_variome/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
```

All routes should be `200`; the OIDC issuer should be `https://$CV_PUBLIC_HOST/auth/realms/cafe_variome`.

## 5. Operations

- **After any host or Vault restart** Vault boots *sealed*: `./scripts/unseal_vault.sh`, then `./cv.sh restart` the backends. (No cloud auto-unseal here - by design.)
- **Backups** (local-infra): `./scripts/backup.sh` → one encryptable tarball under `backups/` (Mongo dump + Keycloak Postgres + Vault data + secrets/config). Move it off-host. Restore with `./scripts/restore.sh backups/<ts>.tar` then re-unseal Vault. In external-infra mode the managed services own their backups.
- **Image updates**: `renovate.json` opens grouped PRs for digest/version bumps (CV3 app images and infra images separately); majors are gated behind the dependency dashboard. The brookeslab images move under `:latest` - Renovate tracks the digest.
- **Rotate** the bootstrap-only values (`KEYCLOAK_CLIENT_SECRET`, the initial admin password) after go-live; the `KEYCLOAK_CLIENT_SECRET`/`ADMIN_*` env on the db-manager can be blanked once the first install has run.

## Troubleshooting (rootless specifics)

These bit during bring-up and are encoded in the compose/config - see SECURITY.md §3 for the reasoning:

- **Proxy binds nothing on 80/443** → host tuning not applied (`apply-host-tuning.sh`), or the proxy is only on `internal:true` networks (it needs `cv_ingress`), or Caddy bound IPv6 (it's pinned to `tcp4/0.0.0.0` because pasta is `--ipv4-only`).
- **Backend 502 through the proxy** → the image binds `127.0.0.1` by default; the compose sets `CV3_BIND=0.0.0.0:5000` (each image adds its own `+offset` → 5000/5100/5200).
- **Keycloak admin/login 404** → the config's `Keycloak.URL`/`BackendURL` must end in `/` (python-keycloak builds `{URL}realms/...`).
- **`PermissionError` reading config** → re-run `render-config.sh` (it `chmod 0644`s the rendered JSON so the in-container uid can read the read-only mount).
