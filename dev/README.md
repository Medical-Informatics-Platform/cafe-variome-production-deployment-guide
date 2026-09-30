# CV3 local dev VM

A disposable Debian VM that runs CV3 in dev mode, for trying the stack locally.

> **Not secure. Never expose it.** Vault runs in dev mode with a hardcoded root token, the Keycloak admin is `admin`/`adminadmin`, services listen on plain HTTP on `127.0.0.1`, and there is no TLS. For any machine other people can reach, use [`../production/`](../production/).

This setup is separate from `production/`: it uses a different layout (`~/cv3-deploy`), different bootstrap scripts, and no reverse proxy.

## Contents

| Path | Purpose |
|---|---|
| `Vagrantfiles/vagrant-debian13-amd64/` | Debian 13 VM (qemu, x86_64) |
| `Vagrantfiles/vagrant-debian13-arm64/` | Debian 13 VM (qemu, arm64 / Apple Silicon) |
| `scripts/bootstrap_cv3_vault.sh` | Sets up dev Vault (AppRole, KV, transit, dev secrets) and writes `VAULT_ROLE_ID`/`VAULT_SECRET_ID` to `~/cv3-deploy/.env` |
| `scripts/bootstrap_cv3_identity.sh` | Creates the Keycloak realm, client and initial user; seeds MongoDB |
| `scripts/update_keycloak_client.sh` | Points the `test_client` redirect URIs and web origins at `http://127.0.0.1:5080` |
| `scripts/fix_cv3_direct_access_config.sh` | Rewrites the config for direct port access (5000/5100/5200/5080) |
| `scripts/run_cv3_bootstrap_from_host.sh` | From the host: runs `vagrant up`, then uploads and runs the four scripts above, then restarts CV3 |

## Quick start

1. Boot the VM. Requires Vagrant with the qemu provider.

   ```bash
   cd Vagrantfiles/vagrant-debian13-amd64   # use -arm64 on Apple Silicon
   vagrant up
   vagrant ssh
   ```

2. Inside the VM, install Docker. Put the CV3 team's upstream `docker-compose.yml`, `.env` and `config/` in `~/cv3-deploy`, then run `docker compose up -d`.

3. Bootstrap:

   ```bash
   bash bootstrap_cv3_vault.sh
   bash bootstrap_cv3_identity.sh
   bash fix_cv3_direct_access_config.sh
   bash update_keycloak_client.sh
   cd ~/cv3-deploy && docker compose up -d
   ```

   `scripts/run_cv3_bootstrap_from_host.sh` does steps 1 and 3 for you. Run it from a directory that contains a `Vagrantfile`.

4. Open `http://127.0.0.1:5080/`.
