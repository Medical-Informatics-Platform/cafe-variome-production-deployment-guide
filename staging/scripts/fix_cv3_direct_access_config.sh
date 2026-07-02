#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "$HOME/cv3-deploy" ]; then
  echo "Missing $HOME/cv3-deploy"
  exit 1
fi

cd "$HOME/cv3-deploy"

cat > config/frontend_admin_config.json <<'JSON'
{
  "backendUrl": "http://127.0.0.1:5000",
  "redirectUrl": "http://127.0.0.1:5080/callback.html",
  "redirectSilentUrl": "http://127.0.0.1:5080/callback-silent.html",
  "adminUrl": "http://127.0.0.1:5080",
  "discoverUrl": "http://127.0.0.1:5080/discover",
  "metaDiscoverUrl": "http://127.0.0.1:5080/meta-discover"
}
JSON

cat > config/frontend_query_config.json <<'JSON'
{
  "backendUrl": "http://127.0.0.1:5100",
  "redirectUrl": "http://127.0.0.1:5080/callback.html",
  "redirectSilentUrl": "http://127.0.0.1:5080/callback-silent.html",
  "adminUrl": "http://127.0.0.1:5080",
  "discoverUrl": "http://127.0.0.1:5080/discover",
  "metaDiscoverUrl": "http://127.0.0.1:5080/meta-discover"
}
JSON

cat > config/frontend_query_meta_config.json <<'JSON'
{
  "backendUrl": "http://127.0.0.1:5100",
  "redirectUrl": "http://127.0.0.1:5080/callback.html",
  "redirectSilentUrl": "http://127.0.0.1:5080/callback-silent.html",
  "adminUrl": "http://127.0.0.1:5080",
  "discoverUrl": "http://127.0.0.1:5080/discover",
  "metaDiscoverUrl": "http://127.0.0.1:5080/meta-discover"
}
JSON

sed -i 's#"URL": "http://localhost:8080"#"URL": "http://127.0.0.1:8080"#' config/backend_config.json
sed -i 's#http://localhost:5080/callback.html#http://127.0.0.1:5080/callback.html#g' config/backend_config.json
sed -i 's#http://localhost:5080/callback-silent.html#http://127.0.0.1:5080/callback-silent.html#g' config/backend_config.json

docker compose restart cv3-backend-admin cv3-backend-query cv3-backend-network cv3-backend-query-meta cv3-backend-scheduler cv3-backend-database-manager cv3-frontend

echo "Updated frontend/backend config for direct host access via 127.0.0.1."
