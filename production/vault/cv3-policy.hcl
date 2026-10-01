# Vault policy for the CV3 backends' AppRole (cv3). Written by
# scripts/bootstrap_local_infra.sh on first install, and by
# scripts/vault_update_policy.sh on an existing install.
#
# KV v2 under kv/cv3 (Vault.KV2Path=kv, KV2Prefix=cv3 in backend_config.json). The
# backends use the top-level secret and these sub-paths: keycloak/<realm>, shared,
# beacon/<source>, upload/<user>, network/<network>/<node>/<user> (federation keys).
path "kv/data/cv3"          { capabilities = ["create","update","read"] }
path "kv/data/cv3/*"        { capabilities = ["create","update","read"] }
path "kv/metadata/cv3"      { capabilities = ["read","list"] }
# delete: removing a Beacon source, an upload key, or leaving a network deletes the
# secret with all versions (DELETE on the metadata path).
path "kv/metadata/cv3/*"    { capabilities = ["read","list","delete"] }

# Transit (Vault.TransitPath=transit_cv3): per-user RSA keys.
# delete: the db-manager's periodic cleanup removes departed users' keys (the app
# marks keys deletion_allowed at creation).
path "transit_cv3/keys"      { capabilities = ["list"] }
path "transit_cv3/keys/*"    { capabilities = ["create","read","update","list","delete"] }
path "transit_cv3/export/*"  { capabilities = ["read"] }
path "transit_cv3/sign/*"    { capabilities = ["create","update","read"] }
path "transit_cv3/verify/*"  { capabilities = ["create","update","read"] }
path "transit_cv3/encrypt/*" { capabilities = ["create","update","read"] }
path "transit_cv3/decrypt/*" { capabilities = ["create","update","read"] }
