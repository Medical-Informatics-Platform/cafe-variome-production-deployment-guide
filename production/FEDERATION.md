# Federation

By default this deployment is an **isolated installation**. Setting `CV_FEDERATION=1` lets it join discovery networks with other CV3 installations. Isolated installs are unaffected.

> **Status:** tested between two live installations (Ubuntu 24.04, pinned images, October 2026). With separate Keycloaks, the join request reaches the peer but is rejected at the token check. With a shared Keycloak, the join, approval and node and user sync work in both directions. With synthetic data, federated meta queries (dataset discovery) and the network index exchange work; record queries return no results because of CV3 bugs (see Known CV3 issues).

## How CV3 federation works

- Installations talk to each other directly (peer to peer). There is no central server.
- Only `cv3-backend-network` contacts peers. `cv3-backend-query-meta` contacts external Beacon sources.
- For each peer, the network backend:
  1. checks `GET {peer}/federation/`;
  2. sends messages with `POST {peer}/federation/federation/`.
- Each message is signed with a per-network RSA key stored in Vault, and carries a Keycloak token.
- The receiver checks the token by calling `introspect` on **its own** Keycloak. So all installations in a network must share one Keycloak realm, each with its own client. With separate Keycloaks the receiver logs `Failed to get client id: 'client_id'` and drops the message.
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
   ./scripts/federation_add_peer_client.sh cv3-b.example.org admin@hospital-b.example.org
   ```

   The script creates B's client and B's initial admin account in this realm, and prints the values B needs and the admin's temporary password. Send them to B's operator over a secure channel. Then:
   - add B's hostname to `allowed_domains.federation.txt`, and run `./cv.sh restart cv-federation-proxy`;
   - add B's outbound IP to `CV_KC_ADMIN_PEERS` in `.env`, for example `"203.0.113.7/32"` (quoted), and run `./cv.sh up -d cv-proxy`. B's backends manage B's users through this realm's admin API. Every other client still gets 403.

## Set up each other installation (B)

1. Before the first start, add the values from A to `.env`:

   ```bash
   CV_FEDERATION=1
   CV_KEYCLOAK_URL=https://cv3-a.example.org/auth/
   KC_CLIENT=cv3-cv3-b-example-org
   KEYCLOAK_CLIENT_SECRET=<from A>
   ADMIN_EMAIL=<from A>
   ```

2. Add A's hostname (and every other peer's) to `allowed_domains.federation.txt`.
3. Deploy as in [README.md](README.md). `render-config.sh` points `Keycloak.URL` and `BackendURL` at A. The bootstrap still configures the local Keycloak, but CV3 does not use it. B's initial admin is the account A created, `<KC_CLIENT>_admin`, with the temporary password A sent you. B's own `secrets/initial-admin.txt` refers to the unused local Keycloak.
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

- **Request to join:** in the admin UI, open Network → Join a Network, enter a member's base URL (`https://<host>`), click Index, then Join on the network. The API equivalent is `POST /api/networks/join` with `{networkId, baseUrl}`.
- **Approve:** a server admin on that member approves the request. The admin UI of the pinned CV3 version does not list incoming requests (and its dashboard counter always shows 0), so use the API. Signed in to the admin UI, run this in the browser's developer console, with the admin's bearer token copied from any `/api/` request in the Network tab:

  ```js
  const H = {Authorization: 'Bearer <token>'};
  await (await fetch('/api/networks/requests?status=pending', {headers: H})).json();   // note messageId and challenge
  await fetch('/api/networks/requests/<messageId>/approve', {method: 'POST', headers: H}); // expect 204
  ```
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
- **Known CV3 issues** (pinned images, not fixable in this repo):
  - Creating a network that fails half-way (e.g. a Vault error) still stores the network. Delete the duplicate from MongoDB (`network.networks`).
  - The admin UI shows no incoming join requests, and the dashboard's "Network requests" count is always 0 (it queries `Pending`, but CV3 stores `pending`).
  - A join request that fails validation still shows as joined on the requesting side.
  - Record queries (local and federated) finish with no results: the query compiler rebuilds every filter with the library's base classes (`'EavQuery'`/`'SubjectQuery' object has no attribute 'generate_pipeline'`), and a receiving node reads the compiler's answer without waiting for it, so it replies to the peer with a non-JSON body.
  - Uploading and ingesting files through the admin API does not fill sources in this build.
  - HPO/ORDO similarity queries call the BTS service (`DiscoverySetting.btsEndpoint`, default `similarity.cafevariome.org`), which this stack neither provides nor allows as egress.
