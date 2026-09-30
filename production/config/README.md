# CV3 config

`../scripts/render-config.sh` creates the `*.json` files from the `*.template` files. It replaces the `__CV_PUBLIC_HOST__`, `__MONGO_APP_*__` and `__KC_*__` tokens with values from `.env`. The rendered files are gitignored and are mounted read-only into the containers.

| File | Mounted into | Purpose |
|---|---|---|
| `backend_config.json` | every backend, at `/home/appuser/.config/CV3Backend/instance_config.json` | Connections to Keycloak, Vault, MongoDB and Redis |
| `frontend_admin_config.json` | frontend, at `assets/assets/config.json` | Admin UI endpoints |
| `frontend_query_config.json` | frontend, at `discover/assets/assets/config.json` | Discover UI endpoints |
| `frontend_query_meta_config.json` | frontend, at `meta-discover/assets/assets/config.json` | Meta-discover UI endpoints |

## Notes

- **Frontend URLs** use the reverse-proxy paths under `https://$CV_PUBLIC_HOST`: `/api` goes to the admin backend, `/query` to the query backend, `/federation` to the network backend.
- **`Keycloak.URL`** is the address browsers use (`https://$CV_PUBLIC_HOST/auth/`). **`BackendURL`** is the address inside Docker (`http://cv3-keycloak:8080/auth/`). Both must end with `/`. If `CV_KEYCLOAK_URL` is set (federation), both are set to it. **`Keycloak.Client`** comes from `KC_CLIENT` (default `test_client`).
- **Vault AppRole credentials** are not in this file. They come from the `VAULT_ROLE_ID`/`VAULT_SECRET_ID` environment variables.
- **Redis** is required.
- **External infra:** replace the `cv3-*` hostnames with your endpoints.

To print the full config schema the image expects:

```bash
docker run --rm --entrypoint python3 brookeslab/cv3-backend-admin:latest \
  -c "from cv3_backend_lib.etc import consts; import json; print(json.dumps(consts.CONFIG_FILE, indent=2))"
```
