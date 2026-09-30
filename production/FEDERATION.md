# Federation

By default this deployment is an **isolated installation**. Setting `CV_FEDERATION=1` lets it join discovery networks with other CV3 installations. Isolated installs are unaffected.

> **Status:** the egress path, proxy patch, CA handling, Caddy rule and config rendering have been tested in the pinned images. A full join between two live installations has not been tested yet. The shared-Keycloak requirement below is inferred from the CV3 code; the test procedure checks both setups.

## How CV3 federation works

- Installations talk to each other directly (peer to peer). There is no central server.
- Only `cv3-backend-network` contacts peers. `cv3-backend-query-meta` contacts external Beacon sources.
- For each peer, the network backend:
  1. checks `GET {peer}/federation/`;
  2. sends messages with `POST {peer}/federation/federation/`.
- Each message is signed with a per-network RSA key stored in Vault, and carries a Keycloak token.
- The receiver checks the token by calling `introspect` on **its own** Keycloak. So all installations in a network must share one Keycloak realm (*inferred*), each with its own client.
- Peers verify TLS certificates.

## What `CV_FEDERATION=1` adds

| Piece | Purpose |
|---|---|
| `compose.federation.yml` | Adds `cv-federation-proxy`, a Squid that allows only the hosts in `allowed_domains.federation.txt` (plus `allowed_domains.cv-egress.txt`). The network and query-meta backends send outbound traffic through it. |
| `federation/sitecustomize.py` | Mounted read-only into those backends. CV3's HTTP client (aiohttp) ignores `HTTP(S)_PROXY`; this makes it respect the proxy. It also loads `federation/extra-ca.pem` if the file exists. |
| `allowed_networks.federation.txt` | Private address ranges that peers may use. Private addresses are blocked otherwise. |
| `compose.shared-keycloak.yml` | Loaded when `CV_KEYCLOAK_URL` is set. The admin, query and db-manager backends reach the shared Keycloak through the same proxy. |
| `scripts/set_instance_url.sh` | Sets the URL this installation advertises. The installer sets it to `http://localhost:5000`, which does not work for federation. |
| `scripts/federation_add_peer_client.sh` | On the Keycloak host: creates a peer installation's client. |

## Requirements

- A public hostname (`CV_PUBLIC_HOST`) with a certificate that peers trust. Use Let's Encrypt. With `CV_TLS=internal`, every peer must add your Caddy root CA to its `federation/extra-ca.pem` (see [Private CA](#private-ca)).
- Every installation can reach every other one on 443.
- One installation hosts the shared Keycloak (local-infra mode). The others use it through `CV_KEYCLOAK_URL`.

## Set up the Keycloak host (installation A)

1. Deploy as in [README.md](README.md). Also set `CV_FEDERATION=1` in `.env`.
2. After the first full start, set the advertised URL. The name is shown to peers.

   ```bash
   ./scripts/set_instance_url.sh "Hospital A"
   ```

3. For each other installation B:

   ```bash
   ./scripts/federation_add_peer_client.sh cv3-b.example.org
   ```

   The script prints the four values B needs. Send them to B's operator over a secure channel. Then:
   - add B's hostname to `allowed_domains.federation.txt`, and run `./cv.sh restart cv-federation-proxy`;
   - add B's outbound IP to `CV_KC_ADMIN_PEERS` in `.env`, for example `"203.0.113.7/32"` (quoted), and run `./cv.sh up -d cv-proxy`. B's backends manage B's users through this realm's admin API. Every other client still gets 403.

## Set up each other installation (B)

1. Before the first start, add the four values from A to `.env`:

   ```bash
   CV_FEDERATION=1
   CV_KEYCLOAK_URL=https://cv3-a.example.org/auth/
   KC_CLIENT=cv3-cv3-b-example-org
   KEYCLOAK_CLIENT_SECRET=<from A>
   ```

2. Add A's hostname (and every other peer's) to `allowed_domains.federation.txt`.
3. Deploy as in [README.md](README.md). `render-config.sh` points `Keycloak.URL` and `BackendURL` at A. The bootstrap still configures the local Keycloak, but CV3 does not use it. The initial admin is created in A's realm as `<KC_CLIENT>_admin`, with the temporary password `cv_admin`.
4. Set the advertised URL:

   ```bash
   ./scripts/set_instance_url.sh "Hospital B"
   ```

## Private CA

For test hosts with `CV_TLS=internal`:

1. Export each peer's Caddy root certificate on that peer:

   ```bash
   docker exec cv-proxy cat /data/caddy/pki/authorities/local/root.crt
   ```

2. Concatenate the certificates into `federation/extra-ca.pem` on every installation. The file is gitignored.
3. Run `./cv.sh up -d`.

## Join a network

Use the admin UI, or the admin API under `/api`.

- **Request to join:** a data admin calls `POST /api/networks/join` with `{networkId, baseUrl}`, where `baseUrl` is a member's URL (`https://<host>`). A server admin on that member approves with `POST /api/networks/requests/<id>/approve`.
- **Invite:** a member calls `POST /api/networks/<id>/invite` with `{baseUrl}`. The invited side approves the same way.
- **Verify the challenge:** every request and invite shows three random words. The code does not check them; compare them with the other admin over a separate channel before approving.
- **Approve other nodes:** nodes learned from other members appear as pending. A data admin approves each one with `POST /api/nodes/<id>/approve`.

`baseUrl` must be exactly the URL the peer advertises (`https://<its CV_PUBLIC_HOST>`, no trailing slash). Otherwise the approval is rejected.

## Operating notes

- **Silent failures.** The federation endpoint returns `200 Success` even when a message fails validation. Diagnose with the logs:

  ```bash
  ./cv.sh logs cv3-backend-network
  sudo journalctl CONTAINER_NAME=cv-federation-proxy   # denied destinations: TCP_DENIED
  ```

- **Beacon sources.** Hosts queried by `cv3-backend-query-meta` must also be in `allowed_domains.federation.txt`.
- **Backups.** Network keys and peer public keys are stored in Vault, so `backup.sh` covers them. Losing them means rejoining every network.
- **Security trade-offs.** See [SECURITY.md](SECURITY.md) §3 and §7.
