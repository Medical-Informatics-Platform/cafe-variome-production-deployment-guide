# CV3 production deployment - security architecture

This deployment layer applies a defence-in-depth model to the Cafe Variome v3 stack. Security rests on four boundaries - a hardened host, rootless Docker, per-container least privilege, and network segmentation - plus a pinned image supply chain and a no-hardcoded-secrets posture.

## 1. Host

- **CIS-hardened Debian/Ubuntu** via the upstream `konstruktoid` roles (`setup-playbook.yml`): SSH locked to keys + an admin allowlist, root account disabled, auditd, UFW default-deny (only 80/443 inbound, a narrow egress set), restrictive `umask`/`limits`, logind hardening.
- **Rootless Docker** (`install-docker-rootless.yml`): the daemon and every container run as the unprivileged `dockeruser` in a user namespace. A process running as root *inside* a container maps to `dockeruser`'s own host uid; non-zero container uids map into `dockeruser`'s subuid range. So a breakout does not reach host root  but it does reach `dockeruser`, which owns every volume, `.env` and the rendered config, and may bind host ports 80–1023 (see the sysctl below). 
- **Host tuning the CIS baseline omits** (`scripts/apply-host-tuning.sh`, from `deploy/*.conf`):
  - `nofile`/`nproc` raised for `dockeruser` and the user systemd manager (the CIS caps are too low for a ~14-container stack - first symptom is `error setting rlimit type 7: operation not permitted`).
  - `net.ipv4.ip_unprivileged_port_start = 80` so the rootless proxy can bind 80/443. Scoped to 80+ (22 etc. stay privileged). **Trade-off:** any process of `dockeruser` may now bind 80–1023; acceptable because the host is single-tenant and dockeruser is already the container principal.

## 2. Per-container least privilege (`compose.hardening.yml`)

The seven CV3 application services merge the `x-harden` anchor; the infra and proxy
services in the overlays set the same fields explicitly (they need per-image tweaks).

- `read_only: true` root filesystem; the few writable paths are explicit, size-capped `tmpfs` mounts (and owned by the in-image uid so they work under userns remap). **Keycloak is the one exception** — see §7.
- `cap_drop: ["ALL"]`, then a minimal `cap_add` only where an image genuinely needs it: frontend nginx and Caddy `NET_BIND_SERVICE` (bind :80/:443); mongo `CHOWN/SETUID/SETGID/DAC_OVERRIDE` for its entrypoint's privilege drop; whichever egress squid is loaded, the same four (it drops to the `proxy` user). Four containers at a time, the two Squids are mutually exclusive, so all 15 defined services never run at once.
- `security_opt: ["no-new-privileges:true"]`.
- `pids_limit`, `ulimits.nofile`, `mem_limit`, `cpus` per service.
- Non-root uid where the image allows it: Vault `100`, Keycloak Postgres `70`, Redis `999`, frontend nginx `101`. The CV3 backends already run as `appuser` (100).
- Config files are mounted **read-only**; only the secrets each container needs are in its `environment:` (no shared `env_file`).

> **Advisory limits.** Rootless Docker uses cgroup driver `none`, so `mem_limit`/`cpus` are **not kernel-enforced** - they document intent and back app-level limits. Treat host capacity planning, not cgroups, as the real resource boundary.

## 3. Network segmentation

The boundary that contains a compromised container. Three app networks are `internal: true` - Docker still assigns the bridge an address, but installs **no default route and no NAT/masquerade** for it, so a container on one has no IP path off the machine:

- `cv_edge` - the reverse proxy reaches the frontend + the three public backends + Keycloak.
- `cv_backend` - inter-backend / worker coordination.
- `cv_egress` - the lane backends use to reach Keycloak/Vault/MongoDB/Redis. In external-infra mode this is bridged outward only by the forced-egress Squid (`compose.egress.yml`); in local-infra mode the infra containers sit on it directly.

**Forced egress.** The backends have no direct internet route; outbound goes through a Squid with a default-deny allowlist that also blocks SSRF targets (loopback, RFC1918, link-local incl. `169.254.169.254` cloud metadata, the stack's own Docker subnets).

**TLS reverse proxy** (`compose.reverse-proxy.yml`). Caddy terminates HTTPS for the whole stack (sees plaintext, holds the key) and is the sole public ingress (80/443). Its ACME client egresses only through a dedicated Let's-Encrypt-only Squid (`HTTP(S)_PROXY` → `cv-tls-egress-proxy`, allowlist = ACME endpoints).

> **Rootless ingress trade-off.** Rootless `pasta` cannot forward host ports to a container that is *only* on `internal: true` networks, so `cv-proxy` also joins one non-internal `cv_ingress` bridge for inbound 80/443. A non-internal bridge carries an egress route too, so the strong "no egress" guarantee does not hold for the public proxy itself - its outbound is constrained by the `HTTP(S)_PROXY` → ACME-squid config rather than by network isolation. Only `cv-proxy` joins `cv_ingress`; every backend and the infra stay on `internal: true` networks. Caddy also binds `tcp4/0.0.0.0` because pasta runs `--ipv4-only` and won't forward an IPv6 listener.

## 4. Secrets & identity

- **Vault in non-dev mode**: file storage, persistent, real seal/unseal - **no hardcoded root token**. Initialised once by `scripts/bootstrap_local_infra.sh`, which writes the unseal keys + root token to `secrets/vault-init.json` (gitignored, `0600`). **Move that file offline and delete it from the host.** Vault boots **sealed** after any restart; re-unseal with `scripts/unseal_vault.sh`. There is no cloud auto-unseal here.
- Backends authenticate to Vault with an **AppRole** (`VAULT_ROLE_ID`/`VAULT_SECRET_ID`), scoped by a policy to the CV3 KV path + transit keys only. The credential is **time-bounded**: `secret_id_ttl` 90d (override with `VAULT_APPROLE_SECRET_ID_TTL`), tokens 1h/24h. Rotate before expiry — `vault write -f auth/approle/role/cv3/secret-id`, then update `.env` and restart the backends. **Diarise this**: nothing here warns you as the TTL approaches.
- The **bootstrap root token is revoked** at the end of `bootstrap_local_infra.sh` and stripped from `secrets/vault-init.json` (keep `CV_KEEP_VAULT_ROOT_TOKEN=1` only for debugging). If you ever need root again, regenerate it from the unseal shares with `vault operator generate-root`.
- **Keycloak** runs in prod mode on its own Postgres, behind the TLS proxy at `/auth`. The db-manager's first-run installer creates the realm client + initial admin; that client's service account holds only the `realm-management` roles it needs (`manage/view/query users`). Additional best practices applied to the local realm (bootstrap + Caddyfile): the **admin console/API and master realm are blocked at the public edge** (403; admin access is via `kcadm.sh` in the container or an on-demand loopback tunnel - see `Caddyfile.reverse-proxy`), **brute-force detection** is on, **login + admin events** are recorded (1-year expiration, and successful logins are also surfaced into the container log -> journal), and a **password policy** (`length(12) and notUsername`) is set. Remaining operator duties: rotate `KC_BOOTSTRAP_ADMIN_*` after go-live (create named per-person admins, then delete the shared bootstrap admin) and keep the Keycloak image current via Renovate.
- **MongoDB auth is enabled.** The CV3 image ignores the config's `User`/`Password` and builds an unauthenticated URI, so the app credentials are embedded in the connection `Host` (`user:pass@cv3-mongo`) to keep auth on; the `cv3app` user is scoped to the `cafevariome` DB. Use URL-safe (hex) passwords. The defence-in-depth here is auth **plus** the internal-only network - Mongo is never reachable off `cv_egress`.
- `scripts/validate-env.sh` is a fail-closed gate, and `cv.sh` **runs it automatically** before any command that can start containers (`up`/`create`/`run`/`start`/`restart`); `config`/`ps`/`logs`/`down` stay usable on a half-configured box. It refuses to deploy while a required secret is empty or still looks like a placeholder (substring match, so `CHANGE_ME_now` is caught too), warns on short secrets, rejects a non-alphanumeric Mongo password (it goes into a `sed` replacement *and* the Mongo URI), refuses external-infra mode while `allowed_domains.cv-egress.txt` is comment-only, and tightens `.env` to `0600`. Override once with `CV_SKIP_ENV_CHECK=1`. It **parses** `.env` rather than sourcing it — `. .env` would execute a `$(...)` in a password.
- Gitignored, never committed: `.env`, rendered `config/*.json` (carry the Mongo password), `secrets/`, `backups/`.
- **Backups are encryptable at rest.** Set `CV_BACKUP_AGE_RECIPIENT` (or `CV_BACKUP_GPG_RECIPIENT`) in `.env` and `scripts/backup.sh` encrypts the tarball, which otherwise holds the unseal shares, both DB dumps and `.env` in one plaintext file. Keep the decryption key off this host. Nothing here schedules or ships backups — that is still an operator duty.

## 5. Image supply chain

- Every image is pinned by immutable digest (`repo:tag@sha256:…`) - the third-party CV3 images and all infra images (Vault, Keycloak, Postgres, Mongo, Redis, Caddy, Squid). This includes the helper container `backup.sh`/`restore.sh` use to tar the Vault volume: it reads the already-pinned alpine digest out of `compose.local-infra.yml` rather than pulling a floating `busybox`/`alpine` while a data volume is mounted, and **refuses to run** if it cannot resolve it.
- **Renovate** (`renovate.json`) tracks those pins and opens grouped PRs for digest/version bumps: minors auto-proposed, **majors gated** behind the dependency dashboard, no automerge, with merge-confidence + changelog context. `pinDigests` is on for the whole `docker-compose` manager, so an image added as a bare `repo:tag` gets pinned rather than silently escaping the guarantee above.
- **What pinning does not buy.** It proves the bytes you run are the bytes that were pinned, so tag mutation, registry compromise reusing a tag, and accidental drift all fail. It says nothing about whether those bytes are trustworthy: there is **no signature/attestation verification, no SBOM and no vulnerability scan** on CV yet; the mitigation is the containment in §2–§3.

## 6. Logging & audit retention (compliance)

Access/audit logs are a hard requirement here: they must survive stack redeploys and host reboots and be retained for **one year**.

- **Every container logs to the host systemd journal** (compose `journald` driver, tagged with the container name). Per-container `json-file` logs would be deleted on every container recreation - that is why they are not used. `cv.sh logs` / `docker logs` keep working (journald read-back).
- **The journal is made genuinely persistent** by `scripts/apply-host-tuning.sh`: the CIS hardening sets `Storage=persistent` but never creates `/var/log/journal`, so out of the box the journal is volatile and lost on reboot. The script creates the directory, installs `deploy/journald-cv3.conf` (`MaxRetentionSec=1year`, `SystemMaxUse=10G`, `SystemKeepFree=5G`, raised rate limits so bursty access logs aren't dropped) and flushes the volatile store.
- **HTTP access log**: Caddy (`cv-proxy`) writes one structured JSON line per request (timestamp, client IP, method, URI, status, user agent) to stdout -> journal. Query: `sudo journalctl CONTAINER_NAME=cv-proxy --since "..."`.
- **Identity audit**: Keycloak login/admin events are stored in its DB for a year (realm `eventsExpiration`) *and* successful/failed logins appear in its container log -> journal.
- **Caveats**: size caps evict oldest-first even inside the retention window - keep `SystemMaxUse` generous and watch `journalctl --disk-usage`; for court-grade immutability, ship the journal to an external WORM store (out of scope here).

## 7. Residual risks / hardening backlog

The paragraph below describes the known and accepted risks in this repository.

- **DNS is not filtered.** Docker's embedded resolver (`127.0.0.11`) answers on `internal: true` networks too, and the Squid allowlists never see it. It is a "no IP egress". A low-bandwidth DNS side channel remains available to a compromised container. Closing it woul mean pinning the resolver and logging/alerting on query volume.
- **The public proxy has a route out.** Rootless `pasta` cannot forward host ports into a container that only has internal networks, so `cv-proxy` also joins the routed `cv_ingress` bridge (see §3). Its outbound is constrained by `HTTP(S)_PROXY` env, which a deliberately compromised process can ignore.
- **Resource limits are advisory** (§2): cgroup driver `none`, so `mem_limit`/`cpus` — and `pids_limit`, which uses the same mechanism document intent here. Kernel-enforced: `ulimits.nofile`, tmpfs `size=` caps, journald retention caps. CPU is not capped by the container. Verify the driver on the host with `docker info -f '{{.CgroupDriver}}'`.
- **No isolation *within* a lane.** `DOCKER_IGNORE_BR_NETFILTER_ERROR=1` (`deploy/br-netfilter.conf`) is required because the hardened host has no `br_netfilter`, and it skips the inter-container-communication iptables refinement. Cross-network is still hard-blocked by topology; port-level restriction between peers that *share* a lane is not enforced. On `cv_egress` that means Vault, Mongo and Redis all speak **plaintext**, and **Redis is unauthenticated** - any container on that lane can read the cache. Closing it involves restoring ICC restriction, or authenticating Redis and adding in-lane TLS.
- **Keycloak rootfs is writable** (`start --optimized=false` augments at boot). Build a pre-optimised image and switch it to `read_only` to mitigate this. It is recommended to use one own organisation's managed Keycloak.
- **Unseal-key custody.** `bootstrap_local_infra.sh` writes all five shares to `secrets/vault-init.json`, and the 5-of-3 threshold gives no custodian separation while they sit in one file. `unseal_vault.sh` now accepts shares via `--stdin` or `CV_UNSEAL_KEYS`. It is recommended to use one own organisation's managed Vault.
- **No monitoring or alerting.** Metrics/log ship disabled in `config/backend_config.json.template`. The journal has the logs (§6) but nothing watches it.
- **No edge rate limiting** and no client certificates on the admin API. Security response headers are set at the Caddy edge, but there is no CSP (the SPA's inline/eval usage is unaudited).
- **Caddy/`tls internal` on a no-DNS test box** is self-signed; production uses a real domain + Let's Encrypt over the egress squid (the ACME path is otherwise identical).
