# k8s-infra

Ansible that turns plain VPSs from different providers into an RKE2 cluster, then bootstraps Flux from [k8s-fleet](https://github.com/nathansiegfrid/k8s-fleet).

## Migration in progress

The numbered playbooks in `ansible/` are moving to roles at the root, one feature at a time. Each step moves the files it reuses and deletes the playbooks it replaces; what's left in `ansible/` isn't maintained.

| Feature | Where |
| --- | --- |
| Admin user and SSH hardening | `01-mesh.yaml` |
| WireGuard, node baseline, RKE2, kubeconfig, Cilium and Flux | `ansible/`, not migrated yet |
| DNS records | `terraform/`, until k8s-fleet's external-dns replaces it |

## What it builds

- **An admin user and hardened SSH on every host:** key auth only, no root login, Fail2Ban.

## Layout

```
01-mesh.yaml        secure every host
roles/              one role per concern, listed under "Building the cluster"
inventory/          hosts.yaml (git-ignored)
ansible/            the old playbooks, until they're migrated
terraform/          DNS records, until they move to k8s-fleet
```

## Requirements

On this machine, Ansible and the collections: `ansible-galaxy collection install -r requirements.yaml`.

The nodes run Ubuntu or Debian.

## Setup

Copy `inventory/hosts.yaml.example` to `inventory/hosts.yaml` and fill in the real IPs. It's git-ignored.

## Building the cluster

```sh
ansible-playbook 01-mesh.yaml
```

| Playbook | Role | Hosts | Does |
| --- | --- | --- | --- |
| `01-mesh.yaml` | `connection` | all | Finds how to reach each host: over WireGuard, else the public IP, else the provider's default user on a new VPS |
| | `admin_user`, `ssh_hardening` | all | The admin user with your key and passwordless sudo; Fail2Ban, no root login, keys only |

Running it again is safe.

## CI

ansible-lint (production profile) runs on every push to `main` and on pull requests. It skips `ansible/` and `terraform/` until they're migrated.
