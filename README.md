# k8s-infra

Ansible that turns plain VPSs from different providers into an RKE2 cluster, then bootstraps Flux from [k8s-fleet](https://github.com/nathansiegfrid/k8s-fleet).

## Migration in progress

The numbered playbooks in `ansible/` are moving to roles at the root, one feature at a time. Each step moves the files it reuses and deletes the playbooks it replaces; what's left in `ansible/` isn't maintained.

| Feature | Where |
| --- | --- |
| Admin user, SSH hardening, WireGuard mesh | `01-mesh.yaml` |
| Node baseline | `02-cluster.yaml` |
| RKE2, kubeconfig, Cilium and Flux | `ansible/`, not migrated yet |
| DNS records | `terraform/`, until k8s-fleet's external-dns replaces it |

## What it builds

- **An admin user and hardened SSH on every host:** key auth only, no root login, Fail2Ban.
- **A WireGuard full mesh** between the nodes, which share no private network. Each node's private key is generated on the node and never leaves it. Admin machines join as extra peers.
- **Nodes ready for Kubernetes:** hostname, timezone, NTP, swap off, kernel modules and sysctls. The OS is upgraded only before RKE2 is installed.

## Layout

```
01-mesh.yaml        secure every host and build the WireGuard mesh
02-cluster.yaml     prepare the nodes for Kubernetes, over WireGuard
roles/              one role per concern, listed under "Building the cluster"
inventory/          hosts.yaml (git-ignored), group_vars, and secrets.sops.yaml
generated/          WireGuard client configs (git-ignored)
ansible/            the old playbooks, until they're migrated
terraform/          DNS records, until they move to k8s-fleet
```

## Requirements

On this machine:

- Ansible, plus the collections: `ansible-galaxy collection install -r requirements.yaml`
- [SOPS](https://getsops.io/) and [age](https://github.com/FiloSottile/age)
- WireGuard, to join the mesh

The nodes run Ubuntu or Debian.

## Setup

1. **Your age key.** Run `age-keygen -o <key file>`. SOPS looks for it at `~/Library/Application Support/sops/age/keys.txt` on macOS, `~/.config/sops/age/keys.txt` on Linux, or wherever `SOPS_AGE_KEY_FILE` points. Put its public key in `.sops.yaml`.
2. **The inventory.** Copy `inventory/hosts.yaml.example` to `inventory/hosts.yaml` and fill in the real IPs. It's git-ignored.
3. **The secrets.** Run `sops inventory/group_vars/k8s_nodes/secrets.sops.yaml`; SOPS encrypts the file when you save:

```yaml
wireguard_extra_peers:
  - name: laptop
    public_key: <from `wg pubkey` on the laptop>
    allowed_ips: 10.0.0.100/32
    private_key: <optional: the laptop's private key, written into its client config>
```

## Building the cluster

```sh
ansible-playbook 01-mesh.yaml
ansible-playbook 02-cluster.yaml
```

Between the two, this machine joins the mesh. `01-mesh.yaml` ends by listing the nodes this machine can't reach over WireGuard yet. Import this machine's client config from `generated/`, add its private key unless the config already has it, and bring the tunnel up. `02-cluster.yaml` connects only over WireGuard, and stops before changing anything if a node doesn't answer.

| Playbook | Role | Hosts | Does |
| --- | --- | --- | --- |
| `01-mesh.yaml` | `connection` | all | Finds how to reach each host: over WireGuard, else the public IP, else the provider's default user on a new VPS |
| | `admin_user`, `ssh_hardening` | all | The admin user with your key and passwordless sudo; Fail2Ban, no root login, keys only |
| | `wireguard` | `k8s_nodes` | The mesh, and client configs for extra peers in `generated/` |
| | `connection` (mesh) | `k8s_nodes` | Lists the nodes this machine can't reach over WireGuard yet |
| `02-cluster.yaml` | `connection` (mesh) | `k8s_nodes` | Stops the run if this machine can't reach a node over WireGuard |
| | `node_baseline` | `k8s_nodes` | Hostname, timezone, NTP, swap off, kernel modules and sysctls. Upgrades the OS, and reboots when it asks, only before RKE2 is installed |

Running them again is safe. A node already on the mesh gets WireGuard config changes in place, without dropping the tunnel.

### Add an admin machine

Add it to `wireguard_extra_peers` and run `01-mesh.yaml`. Its client config is written to `generated/`, with its private key if the peer has `private_key` set. Otherwise fill the key in on the machine itself.

## CI

ansible-lint (production profile) runs without decrypting anything, and skips `ansible/` and `terraform/` until they're migrated. A second job fails if any `*.sops.yaml` file isn't encrypted. Both run on every push to `main` and on pull requests.
