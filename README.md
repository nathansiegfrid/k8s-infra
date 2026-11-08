# k8s-infra

Ansible that turns plain VPSs from different providers into an RKE2 cluster, then bootstraps Flux from [k8s-fleet](https://github.com/nathansiegfrid/k8s-fleet).

## Migration in progress

The numbered playbooks in `ansible/` are moving to roles at the root, one feature at a time. Each step moves the files it reuses and deletes the playbooks it replaces; what's left in `ansible/` isn't maintained.

| Feature | Where |
| --- | --- |
| Admin user, SSH hardening, WireGuard mesh | `01-mesh.yaml` |
| Node baseline, RKE2, etcd restore | `02-cluster.yaml`, `upgrade.yaml`, `restore-etcd.yaml`, `destroy.yaml` |
| Kubeconfig, Cilium and Flux | `ansible/`, not migrated yet |
| DNS records | `terraform/`, until k8s-fleet's external-dns replaces it |

## What it builds

- **An admin user and hardened SSH on every host:** key auth only, no root login, Fail2Ban.
- **A WireGuard full mesh** between the nodes, which share no private network. Each node's private key is generated on the node and never leaves it. Admin machines join as extra peers.
- **Nodes ready for Kubernetes:** hostname, timezone, NTP, swap off, kernel modules and sysctls. The OS is upgraded only before RKE2 is installed.
- **RKE2 with the CIS profile.** Pod Security `restricted` is the default for every namespace except `kube-system`. API audit logging is on, the kubelet reserves 1 CPU and 1.5Gi for Kubernetes and the OS, and control-plane nodes are tainted `NoSchedule`.
- **etcd snapshots** every 6 hours to S3-compatible storage, keeping 28 (7 days).

## Layout

```
01-mesh.yaml        secure every host and build the WireGuard mesh
02-cluster.yaml     prepare the nodes and install RKE2, over WireGuard
upgrade.yaml        RKE2 config, OS and RKE2 upgrades, one node at a time
restore-etcd.yaml   restore etcd from an S3 snapshot
destroy.yaml        remove RKE2 from every node
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
rke2_server_token: <random, at least 16 characters>
rke2_agent_token: <random, at least 16 characters>
rke2_etcd_s3_bucket: <bucket>
rke2_etcd_s3_region: <region>
rke2_etcd_s3_endpoint: <endpoint, e.g. s3.amazonaws.com>
rke2_etcd_s3_access_key: <access key>
rke2_etcd_s3_secret_key: <secret key>
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
| | `rke2` | `k8s_nodes` | RKE2 on nodes that don't run it yet: the first master, then the other masters, then the workers |

Running them again is safe. A node already on the mesh gets WireGuard config changes in place, without dropping the tunnel, and `02-cluster.yaml` never upgrades, restarts or reboots a node that already runs RKE2.

## Day 2

### Upgrade RKE2, the OS or RKE2's config

Change `rke2_version` or the RKE2 config, then run `ansible-playbook upgrade.yaml`. It goes one node at a time, masters first. A node is drained and rebooted only when its RKE2 version or config changed, or the OS asks for a reboot. Before a master goes down, every etcd member has to be Ready, and each node has to be Ready again before the next one starts. A drain that doesn't finish in `rke2_drain_timeout` (2 minutes, 3 attempts) doesn't block the reboot.

### Restore etcd

```sh
ansible-playbook restore-etcd.yaml -e rke2_etcd_snapshot_name=<snapshot>
```

The restore runs on the first master, which can be a fresh node with the same WireGuard IP. `rke2 etcd-snapshot list` on a master lists the snapshots. No other master may run etcd during the restore: stop `rke2-server` on each and delete `/var/lib/rancher/rke2/server/db`, or rebuild them. The playbook stops before changing anything if one answers on port 2379. Afterwards, `02-cluster.yaml` starts the other masters again, and they join the restored cluster; rebuilt ones need `01-mesh.yaml` first. Workers reconnect on their own. A worker that was in the cluster before the restore can show pods stuck in `Pending` or `Terminating`; restarting the worker clears it.

### Add a node or an admin machine

For a node, add it to `inventory/hosts.yaml` and run `01-mesh.yaml`. Import the new client config on this machine, check that it reaches the node, then run `02-cluster.yaml`.

For an admin machine, add it to `wireguard_extra_peers` and run `01-mesh.yaml`; that's all it needs. Its client config is written to `generated/`, with its private key if the peer has `private_key` set. Otherwise fill the key in on the machine itself. The config sends a keepalive every 25 seconds, so a NAT in front of the machine keeps the tunnel open; set `persistent_keepalive` on the peer to change it.

### Tear down

`ansible-playbook destroy.yaml` removes RKE2 from every node, after you type `destroy-cluster`. WireGuard and the hosts stay.

## CI

ansible-lint (production profile) runs without decrypting anything, and skips `ansible/` and `terraform/` until they're migrated. A second job fails if any `*.sops.yaml` file isn't encrypted. Both run on every push to `main` and on pull requests.

CI doesn't run the playbooks against real nodes. The manual test cases for that are in [TESTING.md](TESTING.md).
