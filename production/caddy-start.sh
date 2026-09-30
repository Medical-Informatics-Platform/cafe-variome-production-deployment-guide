#!/bin/sh
# cv-proxy entrypoint (compose.reverse-proxy.yml). Runs Caddy from the Caddyfile, with
# one fix the Caddyfile cannot express.
#
# `default_bind tcp4/0.0.0.0` keeps Caddy's listeners IPv4-only, which rootless pasta
# needs. The Caddyfile adapter also copies that value into the ACME issuer's
# `challenges.bind_host`, and the HTTP-01 solver then fails with
# "could not start listener for challenge server at tcp4/0.0.0.0:80: lookup tcp4/0.0.0.0:
# no such host", so no certificate is ever issued. Without bind_host, the solver's own
# listener gets "address in use" from Caddy's :80 socket and Caddy's HTTP server answers
# the challenge instead (the normal path).
set -eu
caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile \
  | sed -e 's#,"bind_host":"[^"]*"##g' -e 's#"bind_host":"[^"]*",\{0,1\}##g' \
  > /tmp/caddy.json
exec caddy run --config /tmp/caddy.json
