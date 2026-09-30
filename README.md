# Cafe Variome Production Deployment Guide

This guide helps to deploy Cafe Variome v3 (CV3) on a hardened Linux server with rootless Docker.

| Path | Contents |
|---|---|
| [`production/`](production/) | Production deployment: compose stack, `cv.sh` wrapper, scripts. Runbook: [production/README.md](production/README.md). Security model: [production/SECURITY.md](production/SECURITY.md). |
| [`dev/`](dev/) | Local developer VM in dev mode. Not hardened; never expose it. See [dev/README.md](dev/README.md). |
| `renovate.json`, `.github/workflows/validate.yml` | Image digest updates and CI checks (compose merges, image pins, script syntax). |

## Prerequisites

- A Debian 13+ or Ubuntu 24.04+ server.
- SSH access to it with a sudo-capable user.
- Ansible on your control machine.

## 1. Provision the host

The host is hardened (CIS) and gets rootless Docker using the playbooks in [linux-server-management](https://github.com/NeuroTech-Platform/linux-server-management).

```bash
git clone https://github.com/NeuroTech-Platform/linux-server-management.git
cd linux-server-management
```

Copy the two example files from this repo and fill in the placeholders (server IP, SSH public key, initial password):

| From this repo | To the linux-server-management clone |
|---|---|
| `production/inventory/inventory.example` | `inventories/production/inventory` |
| `production/inventory/host_vars/cafe-variome-node/vars.yml.example` | `host_vars/cafe-variome-node/vars.yml` |

Notes:
- The inventory host must be named `cafe-variome-node`, with its address in `ansible_host`. If it isn't, the host vars are not applied.
- Use the full `vars.yml.example`. The upstream short example leaves out variables the playbook requires.
- The hardening pass deletes inbound firewall rules it does not manage. `POST_RUN_EXTRA_COMMANDS` in the example opens 80/443 again.
- Set `SSHD_ADMIN_NET` to your management network.

Harden the host. Connect as the server's initial user, for example `ubuntu` or `root`:

```bash
ansible-playbook -i inventories/production/inventory -l cafe-variome-node -u <initial-user> setup-playbook.yml
```

Install rootless Docker. Connect as the admin user created in the previous step:

```bash
ansible-playbook -i inventories/production/inventory -l cafe-variome-node -u <admin-user> install-docker-rootless.yml -K
```

## 2. Deploy CV3

Follow [production/README.md](production/README.md).

## Acknowledgements

This project and part of its upstream contributions have received funding from the IMI 2 Joint Undertaking (JU) under grant agreement No. 101034344.
