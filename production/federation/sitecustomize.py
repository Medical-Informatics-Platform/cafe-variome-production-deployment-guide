# Imported automatically by Python at startup in every CV3 backend when federation is
# enabled (compose.federation.yml mounts this directory at /opt/cv3-fed and prepends it
# to PYTHONPATH). It changes no CV3 code; it only adjusts two library defaults.
#
# 1. Extra CA certificates. If extra-ca.pem exists next to this file, it is appended to
#    the default CA bundle and exported as SSL_CERT_FILE / REQUESTS_CA_BUNDLE. Use it
#    for peers whose certificate comes from a private CA (e.g. Caddy `tls internal`).
#    Must run before aiohttp is imported: aiohttp builds its SSL context at import time.
#
# 2. Proxy support. CV3 sends peer traffic with aiohttp.ClientSession(), whose default
#    is trust_env=False, so HTTP(S)_PROXY is ignored and the traffic has no route out.
#    Defaulting trust_env to True sends it through the federation Squid, which enforces
#    the peer allowlist. NO_PROXY keeps in-stack traffic direct.
#
# Any failure here is printed and ignored so a backend never fails to start because of it.

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _install_extra_ca():
    extra = os.path.join(_HERE, "extra-ca.pem")
    if not (os.path.isfile(extra) and os.path.getsize(extra) > 0):
        return
    try:
        import certifi
        base = certifi.where()
    except ImportError:
        base = "/etc/ssl/certs/ca-certificates.crt"
    bundle = "/tmp/cv3-fed-ca-bundle.pem"
    with open(base) as src, open(extra) as add, open(bundle, "w") as out:
        out.write(src.read())
        out.write("\n")
        out.write(add.read())
    os.environ["SSL_CERT_FILE"] = bundle
    os.environ["REQUESTS_CA_BUNDLE"] = bundle


def _default_trust_env():
    try:
        import aiohttp
    except ImportError:
        return
    original = aiohttp.ClientSession.__init__

    def __init__(self, *args, **kwargs):
        kwargs.setdefault("trust_env", True)
        original(self, *args, **kwargs)

    aiohttp.ClientSession.__init__ = __init__


for _step in (_install_extra_ca, _default_trust_env):
    try:
        _step()
    except Exception as exc:  # never block startup
        print(f"cv3-fed sitecustomize: {_step.__name__} failed: {exc}", file=sys.stderr)
