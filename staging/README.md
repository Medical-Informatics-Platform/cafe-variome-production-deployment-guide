# CV3 — local dev / staging

A throwaway local quick-start for **developers**: a Debian VM running CV3 in **dev mode**
with direct host ports and convenience bootstrap scripts. It is the fast inner-loop for
trying the stack out — it is **not** a deployment target.

> ⚠️ **Not hardened. Do not expose.** This path deliberately trades security for speed:
> Vault runs in **dev mode with a hardcoded root token**, Keycloak uses a default admin
> (`admin`/`adminadmin`), services are published on plain `http://127.0.0.1` ports, and
> there is no TLS. For anything reachable by others — including a shared staging server —
> use the hardened layer in [`../production/`](../production/) (see
> [../production/README.md](../production/README.md) and
> [../production/SECURITY.md](../production/SECURITY.md)).

## Contents

| Path | Purpose |
|---|---|
| `Vagrantfiles/vagrant-debian13-amd64/` | Debian 13 VM (qemu, x86_64) |
| `Vagrantfiles/vagrant-debian13-arm64/` | Debian 13 VM (qemu, arm64 — Apple Silicon) |
| `scripts/bootstrap_cv3_vault.sh` | dev Vault: enable AppRole/KV/transit, seed dev secrets, write `VAULT_ROLE_ID/SECRET_ID` to `~/cv3-deploy/.env` |
| `scripts/bootstrap_cv3_identity.sh` | dev Keycloak realm/client + initial user, Mongo seed |
| `scripts/update_keycloak_client.sh` | point the `test_client` redirect/web-origins at `http://127.0.0.1:5080` |
| `scripts/fix_cv3_direct_access_config.sh` | rewrite the frontend/backend config for direct `127.0.0.1` port access (5000/5100/5200/5080) |
| `scripts/run_cv3_bootstrap_from_host.sh` | convenience: `vagrant up`, upload+run the four scripts, restart CV3 |

## Quick start

1. **Boot the VM** (needs Vagrant + the qemu provider on the host):

   ```bash
   cd Vagrantfiles/vagrant-debian13-amd64   # or -arm64 on Apple Silicon
   vagrant up
   vagrant ssh
   ```

2. **Inside the VM**, install Docker and deploy CV3 to `~/cv3-deploy` — use the upstream
   curated compose from [`../work_dir/cafe-variome-production-deployment-guide/how-we-run-stuff.txt`](../work_dir/cafe-variome-production-deployment-guide/how-we-run-stuff.txt)
   (it expects `~/cv3-deploy/{docker-compose.yml,.env,config/}`), then `docker compose up -d`.

3. **Bootstrap** (the scripts assume `~/cv3-deploy` exists and the containers are up):

   ```bash
   bash bootstrap_cv3_vault.sh          # writes VAULT_ROLE_ID/SECRET_ID into ~/cv3-deploy/.env
   bash bootstrap_cv3_identity.sh
   bash fix_cv3_direct_access_config.sh # direct-port (127.0.0.1) frontend/backend config
   bash update_keycloak_client.sh
   cd ~/cv3-deploy && docker compose up -d
   ```

   From the host, `scripts/run_cv3_bootstrap_from_host.sh` automates steps 1+3 (run it from a
   directory that contains a `Vagrantfile`).

4. **Open** `http://127.0.0.1:5080/`.

## Relationship to production

This dev flow and the hardened [`../production/`](../production/) layer are independent:
different layout (`~/cv3-deploy` vs the `production/` overlays), different Vault/Keycloak
posture (dev vs non-dev + service-account), different access (direct ports vs TLS reverse
proxy). The production bootstrap (`production/scripts/bootstrap_local_infra.sh`) is adapted
from these scripts but for a real non-dev Vault and production credentials.
