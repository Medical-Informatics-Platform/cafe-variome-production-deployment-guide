# Cafe Variome Production Deployment Guide

This guide details the steps to deploy a production-ready Cafe Variome instance on a Linux server.

## Prerequisites

- **Operating System**: Ubuntu 24.04+ or Debian 12+ machine.
- **Access**: SSH access to the target machine with a user that has `sudo` privileges (referred to as `$BASTION_USER`).
- **Ansible**: Ansible installed on your control machine.

## 1. Inventory and Host Configuration

Before running any playbooks, you need to define your target host and its specific configuration.

### 1.1. Create Inventory File

Create an inventory file (e.g., `inventories/production/inventory`) to define your target host.

```ini
[cafe-variome-node]
your-server-ip-or-hostname 
```

### 1.2. Configure Host Variables

Create a host variable file to configure the server, including user management and security settings.
Create the directory and file: `host_vars/cafe-variome-node/vars.yml`.

Use the following template based on `host_vars/README.md` of upstream repository, adjusting values as needed (especially SSH keys and passwords):

```yaml
---
# User Management
MANAGE_USERS: true
SSH_USERLIST:
  - username: admin
    admin: true
    public_key: "ssh-ed25519 AAAA..." # Replace with your actual public key
    initialpassword: "94_ChangeMe123!"   # Replace with a secure password

# Security & Hardening
DISABLE_ROOT_ACCOUNT: true
MANAGE_SSH: true
SSHD_ADMIN_NET:
  - "0.0.0.0/0" # Restrict this to your management IP/subnet for better security

# Firewall
MANAGE_UFW: true
UFW_OUTGOING_TRAFFIC:
  - { "port": 22, "proto": "tcp" }
  - 53
  - { "port": 80, "proto": "tcp" }
  - { "port": 443, "proto": "tcp" }
  - { "port": 123, "proto": "udp" }

# Docker Configuration
DOCKER_USER: "dockeruser"
DOCKER_COMPOSE: true
```

## 2. CIS Server Hardening

Run the setup playbook to apply security hardening, create users, and configure the firewall.

```bash
$BASTION_USER = "server_bootstrap_username_usually_ubuntu_or_root"
ansible-playbook -i inventories/production/inventory -l cafe-variome-node -u $BASTION_USER setup-playbook.yml
```

> **Note**: Replace `$BASTION_USER` with the initial SSH user of the machine (e.g., `ubuntu` or `root`).

## 3. Docker Rootless Installation

Install Docker in rootless mode for enhanced security with CIS controls.

```bash
$BASTION_USER = "possibly_new_user_after_previous_run"
ansible-playbook -i inventories/production/inventory -l cafe-variome-node -u $BASTION_USER install-docker-rootless.yml -K
```

The `-K` flag prompts for the sudo password, which is required for some steps.

## 4. Running Cafe Variome

> [!NOTE]
> This section is still in testing and in the writing process.
