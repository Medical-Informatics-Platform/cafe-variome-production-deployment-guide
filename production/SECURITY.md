# CV3 production security model

This deployment relies on four layers of protection: a hardened host, rootless Docker, least privilege for each container, and network segmentation. It also pins every image by digest and keeps no secrets in the repo. Section 7 lists the risks that remain.

## 1. Host

- **CIS hardening** (`setup-playbook.yml`, using the konstruktoid roles):
  - SSH login by key only, restricted to an admin network.
  - Root account disabled.
  - auditd enabled.
  - UFW denies by default. Inbound: 80/443, plus SSH from `SSHD_ADMIN_NET` (the example allows `0.0.0.0/0` until you narrow it). Outbound is limited to a short list.
- **Rootless Docker** (`install-docker-rootless.yml`). The Docker daemon and all containers run as `dockeruser`.
  - Root inside a container maps to `dockeruser` on the host, not to host root.
  - A container breakout therefore reaches `dockeruser`. That user owns every volume, `.env` and the rendered config.
- **Host tuning** (`scripts/apply-host-tuning.sh`):
  - Raises `nofile`/`nproc` for `dockeruser`. The CIS limits are too low for this stack.
  - Sets `net.ipv4.ip_unprivileged_port_start = 80` so the proxy can bind 80/443. Trade-off: any `dockeruser` process can bind ports 80–1023. This is acceptable because the host has a single tenant.

## 2. Container least privilege (`compose.hardening.yml`)

The app services share one hardening block. The infra and proxy services set the same fields individually.

- **Read-only root filesystem.** Writable paths are size-capped `tmpfs` mounts. Keycloak is the exception (see §7).
- **`cap_drop: ALL`**, with capabilities added back only where an image needs them:
  - frontend nginx and Caddy get `NET_BIND_SERVICE`;
  - MongoDB and the active egress Squid get `CHOWN`, `SETUID`, `SETGID` and `DAC_OVERRIDE` to drop privileges at startup. Only one of the two egress Squids runs at a time.
- **`no-new-privileges:true`.**
- **Limits per service:** `pids_limit`, `ulimits.nofile`, `mem_limit` and `cpus`. Only `ulimits.nofile` is enforced under rootless Docker; the others document intent (see §7).
- **Non-root users** where the image allows it: Vault `100`, Keycloak Postgres `70`, Redis `999`, nginx `101`, CV3 backends `appuser` (`100`).
- **Config and secrets.** Config is mounted read-only. Each container receives only the secrets it needs, through `environment:`. There is no shared `env_file`.

## 3. Network segmentation

Three networks are marked `internal: true`. Docker gives them no default route and no NAT, so a container attached only to these networks cannot reach anything outside the host.

| Network | Connects |
|---|---|
| `cv_edge` | The reverse proxy to the frontend, the three public backends and Keycloak. |
| `cv_backend` | The backends and workers to each other. |
| `cv_egress` | The backends to Keycloak, Vault, MongoDB and Redis. In local-infra mode the infra containers are on this network. In external-infra mode the egress Squid is the only way out. |

**Egress.** Backends reach the internet only through a Squid proxy. Its allowlist denies by default and also blocks loopback, RFC1918, link-local addresses (including `169.254.169.254`) and the stack's own subnets.

**Ingress.** Caddy (`cv-proxy`) terminates TLS and is the only public entry point. It holds the TLS key and sees all traffic in plaintext. Its ACME client goes out through a second Squid that allows only Let's Encrypt endpoints. `cv-proxy` is also attached to a routed network, `cv_ingress`; see §7.

## 4. Secrets and identity

- **Vault** runs in non-dev mode, with file storage and a real seal. There is no hardcoded root token and no auto-unseal.
  - `bootstrap_local_infra.sh` initialises Vault with 5 key shares and a threshold of 3. It writes them to `secrets/vault-init.json` (mode `0600`, gitignored). Move that file offline.
  - At the end of the bootstrap, the root token is revoked and removed from the file. `CV_KEEP_VAULT_ROOT_TOKEN=1` keeps it, for debugging only.
- **AppRole.** Backends authenticate with `VAULT_ROLE_ID`/`VAULT_SECRET_ID`.
  - The policy allows only the CV3 KV path and the transit keys.
  - The `secret_id` expires after 90 days. Tokens last 1 hour, renewable up to 24 hours.
  - For rotation, see [README.md](README.md#rotate-credentials).
- **Keycloak** runs in production mode on its own Postgres, under `/auth`.
  - The service account of the CV3 client has only the `manage-users`, `view-users` and `query-users` roles.
  - The admin console, the admin API and the master realm return 403 at the public proxy. Administer Keycloak with `kcadm.sh` inside the container, or through an SSH tunnel (see `Caddyfile.reverse-proxy`).
  - Brute-force detection is on. Login and admin events are kept for 1 year.
  - Password policy: at least 12 characters, and not equal to the username.
- **MongoDB** requires authentication. The CV3 image ignores the configured user and password, so the credentials are embedded in the host field (`user:pass@cv3-mongo`). The `cv3app` user can access only the `cafevariome` database.
- **`validate-env.sh`**, run by `cv.sh` before any start, blocks a deployment when:
  - a required secret is empty or looks like a placeholder;
  - a MongoDB password is not alphanumeric;
  - external-infra mode is used but the egress allowlist is empty.

  It also warns about short secrets and sets `.env` to mode `0600`. Limits: starting named services only prints a warning (needed for the bootstrap), and `CV_SKIP_ENV_CHECK=1` skips the check entirely.
- **Never committed** (gitignored): `.env`, `config/*.json` (they contain the MongoDB password), `secrets/`, `backups/`.
- **Backups** contain the unseal shares, both database dumps and `.env`. They are plaintext unless you set an age or GPG recipient; keep the decryption key off this host. Nothing here schedules backups or copies them off the host.

## 5. Image supply chain

- Every image is pinned by digest (`repo:tag@sha256:…`). This includes the helper container that `backup.sh` and `restore.sh` use; they refuse to run if its pinned digest cannot be found.
- Renovate proposes digest and version updates. Major versions need approval on the dependency dashboard, nothing is merged automatically, and `pinDigests` pins any image added without a digest.
- CI checks that the compose files merge in both modes, that every image is pinned, and that the scripts parse.
- Limits: pinning guarantees you run exactly the bytes you pinned. It does not show that those bytes are safe. There is no signature verification, SBOM or vulnerability scanning.

## 6. Logging and retention

Access and audit logs must survive redeploys and reboots, and are kept for 1 year.

- Every container uses the `journald` log driver. `json-file` logs would be lost whenever a container is recreated.
- `apply-host-tuning.sh` makes the journal persistent by creating `/var/log/journal`, which the CIS role does not do. It also installs `deploy/journald-cv3.conf`: `MaxRetentionSec=1year`, `SystemMaxUse=10G`, `SystemKeepFree=5G`, and higher rate limits.
- Caddy writes one JSON line per request (time, client IP, method, URI, status, user agent). Query it with `sudo journalctl CONTAINER_NAME=cv-proxy`.
- Keycloak keeps login and admin events in its database for 1 year, and also writes logins to the journal.
- Caveats:
  - When the size cap is reached, the oldest entries are deleted even if they are less than a year old. Monitor usage with `journalctl --disk-usage`.
  - For tamper-proof retention, ship the journal to external WORM storage. This is not covered here.

## 7. Residual risks

None of the fixes in the right-hand column are implemented in this repo.

| Risk | Mitigation suggested |
|---|---|
| DNS is not filtered. Docker's resolver answers on internal networks, so a compromised container has a low-bandwidth DNS side channel. | Pin the resolver, and log and alert on query volume. |
| `cv-proxy` has a route out. Rootless `pasta` cannot forward ports to a container that is only on internal networks, so it also joins `cv_ingress`. Its egress is limited only by `HTTP(S)_PROXY`, which a compromised process can ignore. Caddy binds `tcp4/0.0.0.0` because pasta forwards IPv4 only. | No fix proposed yet. |
| Resource limits are not enforced by the kernel. Rootless Docker uses cgroup driver `none`, so `mem_limit`, `cpus` and `pids_limit` have no effect. `ulimits.nofile`, tmpfs sizes and journald caps are enforced. Check the driver with `docker info -f '{{.CgroupDriver}}'`. | Plan host capacity. |
| No isolation between containers on the same network. The host has no `br_netfilter` (`deploy/br-netfilter.conf`), so inter-container restrictions are skipped. On `cv_egress`, Vault, MongoDB and Redis traffic is plaintext, and Redis has no authentication. | Restore ICC restrictions, or add Redis authentication and TLS on that network. |
| Keycloak's root filesystem is writable, because `start --optimized=false` builds at boot. | Build a pre-optimised image and set `read_only`, or use your organisation's managed Keycloak. |
| All 5 unseal shares are stored in one file, so the 3-of-5 threshold does not separate custodians. | Hand the shares to separate people and use `unseal_vault.sh --stdin`, or use your organisation's managed Vault. |
| No monitoring or alerting. Metrics and log shipping are disabled in `backend_config.json.template`. | Add external monitoring. |
| No rate limiting at the proxy and no CSP. Security headers are set, but the SPA's inline and eval usage has not been audited. | No fix proposed yet. |
| With `CV_TLS=internal` the certificate is self-signed. | Use a real domain and Let's Encrypt in production. |
