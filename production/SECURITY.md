# CV3 production deployment - security architecture

This deployment layer applies a defence-in-depth model to the Cafe Variome v3 stack. Security rests on four boundaries - a hardened host, rootless Docker, per-container least privilege, and network segmentation - plus a pinned image supply chain and a no-hardcoded-secrets posture.

## 1. Host

- **CIS-hardened Debian/Ubuntu** via the upstream `konstruktoid` roles (`setup-playbook.yml`): SSH locked to keys + an admin allowlist, root account disabled, auditd, UFW default-deny (only 80/443 inbound, a narrow egress set), restrictive `umask`/`limits`, logind hardening.
- **Rootless Docker** (`install-docker-rootless.yml`): the daemon and every container run as the unprivileged `dockeruser` in a user namespace, so container-root maps to a non-root host subuid. A container breakout lands as nobody, not root.
- **Host tuning the CIS baseline omits** (`scripts/apply-host-tuning.sh`, from `deploy/*.conf`):
  - `nofile`/`nproc` raised for `dockeruser` and the user systemd manager (the CIS caps are too low for a ~14-container stack - first symptom is `error setting rlimit type 7: operation not permitted`).
  - `net.ipv4.ip_unprivileged_port_start = 80` so the rootless proxy can bind 80/443. Scoped to 80+ (22 etc. stay privileged). **Trade-off:** any process of `dockeruser` may now bind 80–1023; acceptable because the host is single-tenant and dockeruser is already the container principal.

## 2. Per-container least privilege (`compose.hardening.yml`)

Every service merges the `x-harden` anchor:

- `read_only: true` root filesystem; the few writable paths are explicit, size-capped `tmpfs` mounts (and owned by the in-image uid so they work under userns remap).
- `cap_drop: ["ALL"]`, then a minimal `cap_add` only where an image genuinely needs it (frontend nginx: `NET_BIND_SERVICE`; mongo: `CHOWN/SETUID/SETGID/DAC_OVERRIDE` for its entrypoint's privilege drop; egress squid: `SETUID/SETGID/CHOWN/DAC_OVERRIDE`).
- `security_opt: ["no-new-privileges:true"]`.
- `pids_limit`, `ulimits.nofile`, `mem_limit`, `cpus` per service.
- Non-root uid where the image allows it: Vault `100`, Keycloak Postgres `70`, Redis `999`, frontend nginx `101`. The CV3 backends already run as `appuser` (100).
- Config files are mounted **read-only**; only the secrets each container needs are in its `environment:` (no shared `env_file`).

> **Advisory limits.** Rootless Docker uses cgroup driver `none`, so `mem_limit`/`cpus` are **not kernel-enforced** - they document intent and back app-level limits. Treat host capacity planning, not cgroups, as the real resource boundary.

## 3. Network segmentation

The boundary that contains a compromised container. Three app networks are `internal: true` (no gateway, no internet route):

- `cv_edge` - the reverse proxy reaches the frontend + the three public backends + Keycloak.
- `cv_backend` - inter-backend / worker coordination.
- `cv_egress` - the lane backends use to reach Keycloak/Vault/MongoDB/Redis. In external-infra mode this is bridged outward only by the forced-egress Squid (`compose.egress.yml`); in local-infra mode the infra containers sit on it directly.

**Forced egress.** The backends have no direct internet route; outbound goes through a Squid with a default-deny allowlist that also blocks SSRF targets (loopback, RFC1918, link-local incl. `169.254.169.254` cloud metadata, the stack's own Docker subnets).

**TLS reverse proxy** (`compose.reverse-proxy.yml`). Caddy terminates HTTPS for the whole stack (sees plaintext, holds the key) and is the sole public ingress (80/443). Its ACME client egresses only through a dedicated Let's-Encrypt-only Squid (`HTTP(S)_PROXY` → `cv-tls-egress-proxy`, allowlist = ACME endpoints).

> **Rootless ingress trade-off.** Rootless `pasta` cannot forward host ports to a container that is *only* on `internal: true` networks, so `cv-proxy` also joins one non-internal `cv_ingress` bridge for inbound 80/443. A non-internal bridge carries an egress route too, so the strong "no egress" guarantee does not hold for the public proxy itself - its outbound is constrained by the `HTTP(S)_PROXY` → ACME-squid config rather than by network isolation. Only `cv-proxy` joins `cv_ingress`; every backend and the infra stay on `internal: true` networks. Caddy also binds `tcp4/0.0.0.0` because pasta runs `--ipv4-only` and won't forward an IPv6 listener.

## 4. Secrets & identity

- **Vault in non-dev mode**: file storage, persistent, real seal/unseal - **no hardcoded root token**. Initialised once by `scripts/bootstrap_local_infra.sh`, which writes the unseal keys + root token to `secrets/vault-init.json` (gitignored, `0600`). **Move that file offline and delete it from the host.** Vault boots **sealed** after any restart; re-unseal with `scripts/unseal_vault.sh`. There is no cloud auto-unseal here.
- Backends authenticate to Vault with an **AppRole** (`VAULT_ROLE_ID`/`VAULT_SECRET_ID`), scoped by a policy to the CV3 KV path + transit keys only.
- **Keycloak** runs in prod mode on its own Postgres, behind the TLS proxy at `/auth`. The db-manager's first-run installer creates the realm client + initial admin; that client's service account holds only the `realm-management` roles it needs (`manage/view/query users`).
- **MongoDB auth is enabled.** The CV3 image ignores the config's `User`/`Password` and builds an unauthenticated URI, so the app credentials are embedded in the connection `Host` (`user:pass@cv3-mongo`) to keep auth on; the `cv3app` user is scoped to the `cafevariome` DB. Use URL-safe (hex) passwords. The defence-in-depth here is auth **plus** the internal-only network - Mongo is never reachable off `cv_egress`.
- `scripts/validate-env.sh` is a fail-closed gate: it refuses to deploy while any required secret is empty or still a `CHANGE_ME` placeholder.
- Gitignored, never committed: `.env`, rendered `config/*.json` (carry the Mongo password), `secrets/`, `backups/`.

## 5. Image supply chain

- Every image is pinned by immutable digest (`repo:tag@sha256:…`) - the third-party CV3 images and all infra images (Vault, Keycloak, Postgres, Mongo, Redis, Caddy, Squid).
- **Renovate** (`renovate.json`) tracks those pins and opens grouped PRs for digest/version bumps: minors auto-proposed, **majors gated** behind the dependency dashboard, no automerge, with merge-confidence + changelog context.

## 6. Residual risks / hardening backlog

- **Keycloak rootfs is writable** (`start --optimized=false` augments at boot). Build a pre-optimised image and switch it to `read_only` to close this.
- **Caddy/`tls internal` on a no-DNS test box** is self-signed; production uses a real domain + Let's Encrypt over the egress squid (the ACME path is otherwise identical).
- The public proxy's egress (see §3) and the advisory resource limits (see §2) are the two places where rootless trades some isolation for workability.
