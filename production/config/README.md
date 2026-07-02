# CV3 config files

These are mounted **read-only** into the containers (see `docker-compose.yml`). The committed `*.template` files carry the structure with a `__CV_PUBLIC_HOST__` token; `../scripts/render-config.sh` substitutes `CV_PUBLIC_HOST` from `.env` to produce the real `*.json` (which are gitignored). The rendered files map to:

| File | Mounted into | Purpose |
|---|---|---|
| `backend_config.json` | every backend → `/home/appuser/.config/CV3Backend/instance_config.json` | Keycloak + Vault + MongoDB connection |
| `frontend_admin_config.json` | frontend `assets/assets/config.json` | admin UI endpoints |
| `frontend_query_config.json` | frontend `discover/assets/assets/config.json` | discover/query UI |
| `frontend_query_meta_config.json` | frontend `meta-discover/assets/assets/config.json` | meta-discover UI |

The frontend URLs use the reverse-proxy paths (`/api`→admin, `/query`→query, `/federation`→network) served at `https://$CV_PUBLIC_HOST`. For an isolated direct-port machine instead, use `../../staging/scripts/fix_cv3_direct_access_config.sh`.

## `backend_config.json` schema (reconciled against the image)
`backend_config.json.template` is the **full** `instance_config.json` schema the brookeslab images actually load, with only the connection blocks pointed at the stack. Confirmed from the image (`IS_PYPI` mode → read from `appdirs.user_config_dir('CV3Backend')` = `/home/appuser/.config/CV3Backend/instance_config.json`, which is exactly where `docker-compose.yml` mounts it):

```bash
docker run --rm --entrypoint python3 brookeslab/cv3-backend-admin:latest \
  -c "from cv3_backend_lib.etc import consts; import json; print(json.dumps(consts.CONFIG_FILE, indent=2))"
```

Notable points that drove the template:
- **`Redis`** is required (caching/locking/metrics) - provided as `cv3-redis` by the local-infra overlay; supply an external Redis in production.
- **`MongoDB.User`/`Password`** - the backends authenticate to Mongo with these. The local-infra bootstrap creates that app user (`MONGO_APP_USERNAME`/`MONGO_APP_PASSWORD`); `render-config.sh` substitutes them into the rendered JSON (keep them out of git).
- **`Vault` AppRole** creds are NOT in this file - they come from the `VAULT_ROLE_ID`/`VAULT_SECRET_ID` environment variables (see `docker-compose.yml`).
- `Keycloak.URL` is the browser issuer (`https://$CV_PUBLIC_HOST/auth`); `BackendURL` is the in-cluster address (`http://cv3-keycloak:8080/auth`, `/auth` because `KC_HTTP_RELATIVE_PATH=/auth`).

For an **external** Keycloak/Vault/Mongo/Redis, replace the `cv3-*` hostnames with your real endpoints and drop the local-infra overlay (`CV_LOCAL_INFRA` unset → `cv.sh` uses the forced-egress proxy instead).
