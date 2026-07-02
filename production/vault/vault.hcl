ui = true

# No swap on this host, and the container can't mlock without IPC_LOCK; disabling
# mlock keeps the cap set empty. (Acceptable because there is no swap to leak to.)
disable_mlock = true

# Persistent file storage on the cv_vault_data volume - NOT the in-memory dev backend.
# Path is /vault/file (pre-created and owned by the image's `vault` user, uid 100), so
# the container can run AS uid 100 with a read-only rootfs and still write here without
# a privilege-drop (which would need SETGID) or a manual volume chown.
storage "file" {
  path = "/vault/file"
}

# Vault is reached only on the internal cv_egress network (cv3-vault:8200), so TLS
# terminates at that trust boundary. For an INTERNET-exposed or cross-host Vault,
# add a TLS cert here (tls_cert_file/tls_key_file) and set api_addr to https - see
# README § Production / SECURITY.md.
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://cv3-vault:8200"
