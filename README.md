# Cafe Variome Production Deployment Guide

This guide details the steps to deploy a production-ready Cafe Variome instance on a Linux server.

## Prerequisites

- **Operating System**: Ubuntu 24.04+ or Debian 12+ machine.
- **Access**: SSH access to the target machine with a user that has `sudo` privileges (referred to as `$BASTION_USER`).
- **Ansible**: Ansible installed on your control machine.

## 1. Clone Repository

Clone the Linux Server Management repository to your control machine:

```bash
git clone https://github.com/NeuroTech-Platform/linux-server-management.git
cd linux-server-management
```

## 2. Inventory and Host Configuration

Before running any playbooks, you need to define your target host and its specific configuration.

### 2.1. Create Inventory File

Create an inventory file (e.g., `inventories/production/inventory`) to define your target host.

```ini
[cafe-variome-node]
your-server-ip-or-hostname 
```

Ansible needs to know which servers to manage. This file maps your server's hostname or IP address to a group name (`cafe-variome-node`) that the playbooks will target.


### 2.2. Configure Host Variables

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

Host variables allow you to define specific configurations for a single host. Here, we define the users to be created, their SSH keys, firewall rules, and Docker settings. This ensures your server is configured exactly as needed for Cafe Variome. Most other settings are secure by default, inheriting from the [upstream hardening roles](https://github.com/konstruktoid/ansible-role-hardening) and the repository's [setup-playbook.yml](https://github.com/NeuroTech-Platform/linux-server-management/blob/main/setup-playbook.yml) and [install-docker-rootless.yml](https://github.com/NeuroTech-Platform/linux-server-management/blob/main/install-docker-rootless.yml).


## 3. CIS Server Hardening

Run the setup playbook to apply security hardening, create users, and configure the firewall.

```bash
$BASTION_USER = "server_bootstrap_username_usually_ubuntu_or_root"
ansible-playbook -i inventories/production/inventory -l cafe-variome-node -u $BASTION_USER setup-playbook.yml
```

This playbook applies security best practices (CIS benchmarks) to harden the operating system. It creates the specified users, configures the firewall (UFW), and secures the SSH daemon to prevent unauthorized access.


> **Note**: Replace `$BASTION_USER` with the initial SSH user of the machine (e.g., `ubuntu` or `root`).

## 4. Docker Rootless Installation

Install Docker in rootless mode for enhanced security with CIS controls.

```bash
$BASTION_USER = "possibly_new_user_after_previous_run"
ansible-playbook -i inventories/production/inventory -l cafe-variome-node -u $BASTION_USER install-docker-rootless.yml -K
```

Running Docker in rootless mode improves security by running the Docker daemon and containers as a non-root user. This mitigates potential vulnerabilities where a container breakout could lead to root access on the host. The setup also follows CIS recommendations as close as possible.


The `-K` flag prompts for the sudo password, which is required for some steps.

## 5. Running Cafe Variome

> [!NOTE]
> This section is still in testing and in the writing process.

## Acknowledgements

This project and part of its upstream contributions have received funding from the IMI 2 Joint Undertaking (JU) under grant agreement No. 101034344.