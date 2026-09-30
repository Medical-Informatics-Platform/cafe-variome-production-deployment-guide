#!/usr/bin/env bash
# Apply the host-level tuning the hardened CV3 stack needs on top of a freshly
# CIS-hardened rootless-Docker host (setup-playbook.yml + install-docker-rootless.yml).
#
# These are NOT applied by the playbooks: the CIS baseline is deliberately tight
# (low ulimits, ip_forward off, privileged ports locked), and a multi-container
# rootless stack with a public TLS proxy needs four adjustments. Without them you hit,
# in order:
#   - "error setting rlimit type 7: operation not permitted"  (first container)
#   - the Caddy proxy binds nothing on 80/443 (rootless can't use privileged ports)
#
# Installs (from production/deploy/):
#   /etc/security/limits.d/99-dockeruser.conf                  (nproc/nofile for dockeruser)
#   /etc/systemd/system/user@.service.d/nofile.conf            (user-manager NOFILE ceiling)
#   /etc/sysctl.d/99-cafevariome-unprivileged-ports.conf       (let rootless bind 80/443)
#   ~dockeruser/.config/systemd/user/docker.service.d/docker-limits.conf  (daemon limits)
#   ~dockeruser/.config/systemd/user/docker.service.d/br-netfilter.conf   (internal nets)
#
# Run as a sudo-capable admin user (NOT as dockeruser):
#   sudo ./apply-host-tuning.sh [dockeruser]
# Idempotent; safe to re-run. Re-applies cleanly after a host re-image.
set -euo pipefail

DOCKER_USER="${1:-dockeruser}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$here/../deploy"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo (root) - it installs system drop-ins."; exit 1; }
id "$DOCKER_USER" >/dev/null 2>&1 || { echo "ERROR: user '$DOCKER_USER' not found."; exit 1; }
DUID="$(id -u "$DOCKER_USER")"

echo "== root drop-ins (limits + user-manager NOFILE + unprivileged ports) =="
install -m 0644 "$DEPLOY/dockeruser-limits.conf"   /etc/security/limits.d/99-dockeruser.conf
install -D -m 0644 "$DEPLOY/nofile.conf"           /etc/systemd/system/user@.service.d/nofile.conf
install -m 0644 "$DEPLOY/unprivileged-ports.conf"  /etc/sysctl.d/99-cafevariome-unprivileged-ports.conf
sysctl --system >/dev/null

echo "== persistent journal + 1-year retention (container/access logs live here) =="
# The hardening sets Storage=persistent but never creates /var/log/journal, so the
# journal is actually volatile (lost on reboot) until the directory exists. The CV3
# compose logs every container via the journald driver - see deploy/journald-cv3.conf.
install -D -m 0644 "$DEPLOY/journald-cv3.conf" /etc/systemd/journald.conf.d/cv3-retention.conf
install -d -m 2755 -g systemd-journal /var/log/journal
systemctl restart systemd-journald
# flush any volatile entries accumulated before this run into the persistent store
journalctl --flush 2>/dev/null || true
echo "   journal storage: $(test -d /var/log/journal && echo persistent || echo VOLATILE), usage: $(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[GM]' | head -1)"
systemctl daemon-reload
echo "   net.ipv4.ip_unprivileged_port_start = $(sysctl -n net.ipv4.ip_unprivileged_port_start)"

echo "== user (dockeruser) docker.service drop-ins =="
DROPIN_DIR="/home/$DOCKER_USER/.config/systemd/user/docker.service.d"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" "$DROPIN_DIR"
install -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0644 "$DEPLOY/docker-limits.conf" "$DROPIN_DIR/docker-limits.conf"
install -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0644 "$DEPLOY/br-netfilter.conf"  "$DROPIN_DIR/br-netfilter.conf"

echo "== restart the user manager + rootless docker so the new limits take effect =="
# Restarting user@UID picks up the NOFILE ceiling; restarting docker (as the user)
# reloads its drop-ins and re-reads the unprivileged-port sysctl for port forwarding.
# `systemctl --user` over `sudo -iu` has no session bus, so point it at the lingering
# user's runtime dir explicitly (XDG_RUNTIME_DIR) - else it can't reach the manager.
RUNDIR="/run/user/$DUID"
systemctl restart "user@${DUID}.service"
sleep 3
sudo -iu "$DOCKER_USER" bash -lc "export XDG_RUNTIME_DIR=$RUNDIR DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNDIR/bus; systemctl --user daemon-reload && systemctl --user restart docker"
sleep 4

echo "== verify =="
# Diagnostic only - never fail the run on it (docker may still be (re)starting).
sudo -iu "$DOCKER_USER" bash -lc "export XDG_RUNTIME_DIR=$RUNDIR; pid=\$(systemctl --user show docker -p MainPID --value 2>/dev/null); { [ -n \"\$pid\" ] && [ \"\$pid\" != 0 ] && grep 'open files' /proc/\$pid/limits 2>/dev/null | awk '{print \"   dockerd open files: \" \$4 \" (want >= 1048576)\"}'; } || echo '   (docker still starting - re-check with: systemctl --user status docker)'" || true
echo "Done. The CV3 stack can now start its containers and publish 80/443."
