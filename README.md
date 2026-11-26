# k8s-infra

Ansible playbooks that bootstrap an RKE2 cluster on Debian VPSs from different providers, then hand the cluster over to Flux and [k8s-fleet](https://github.com/nathansiegfrid/k8s-fleet).

[ONBOARDING.md](ONBOARDING.md) explains how the repositories fit together and walks through the one-time setup.

## What it builds

VPSs from different providers share no private network, and each one is exposed to the internet through a public IP. So the cluster is built on top of a WireGuard mesh with SSH hardening:

1. **Locked-down hosts.** Each host gets an admin user with your key and passwordless sudo. SSH accepts keys only and refuses root logins, and Fail2Ban runs on every host.
2. **A WireGuard mesh.** Every node reaches every other node through an encrypted tunnel. Each node generates its own private key, which never leaves the node. The mesh uses `10.0.0.0/22`: nodes get addresses in `10.0.0.0/24`, and admin machines join as extra peers in `10.0.3.0/24`. Every later step connects over the mesh. Once k8s-fleet's host firewall is running, SSH and the Kubernetes API accept connections from outside the cluster only from `10.0.3.0/24`.
3. **RKE2 with the CIS profile.** Pod Security `restricted` is the default outside `kube-system`, API audit logging is on, and the masters are tainted `NoSchedule`. etcd is snapshotted to S3-compatible storage every 6 hours, and snapshots are kept for 7 days.
4. **Flux.** Cilium and Flux Operator are installed from k8s-fleet's own files, along with the two secrets Flux can't get from git. From there, k8s-fleet manages everything that runs on the cluster, including Cilium and Flux.

## Layout

```
01-mesh.yaml        secure every host and build the WireGuard mesh
02-cluster.yaml     prepare the nodes and install RKE2, over WireGuard
03-flux.yaml        bootstrap Flux from k8s-fleet, on the first master
upgrade.yaml        RKE2 config, OS and RKE2 upgrades, one node at a time
restore-etcd.yaml   restore etcd from an S3 snapshot
destroy.yaml        remove RKE2 from every node
roles/              one role per concern, listed under "Building the cluster"
inventory/          hosts.yaml (git-ignored), group_vars, and secrets.sops.yaml
generated/          WireGuard client configs (git-ignored)
```

## Setup

The one-time setup, from installing the tools to creating the keys and the inventory, is a checklist in [ONBOARDING.md](ONBOARDING.md#setup-checklist). One of the steps is the secrets file. Open it with `sops inventory/group_vars/k8s_nodes/secrets.sops.yaml`, and SOPS encrypts it when you save:

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
    client_ip: 10.0.3.1
    public_key: <from `wg pubkey` on the laptop>
    private_key: <optional: the laptop's private key, written into its client config>
flux_git_deploy_key: |
  <the deploy key's private half>
flux_sops_age_key: <the cluster's age private key>
```

## Building the cluster

```sh
ansible-playbook 01-mesh.yaml
ansible-playbook 02-cluster.yaml
ansible-playbook 03-flux.yaml
```

Your machine has to join the mesh between the first two playbooks. `01-mesh.yaml` finishes by listing the nodes your machine can't reach over WireGuard yet. Import your machine's client config from `generated/`, add its private key if the config doesn't already have it, and bring the tunnel up. `02-cluster.yaml` and `03-flux.yaml` connect only over WireGuard, and they stop before changing anything if a node doesn't answer.

| Playbook | Role | Hosts | What it does |
| --- | --- | --- | --- |
| `01-mesh.yaml` | `connection` | all | Works out how to reach each host: over WireGuard, otherwise the public IP, otherwise the provider's default user on a new VPS |
| | `admin_user`, `ssh_hardening` | all | Creates the admin user with your key and passwordless sudo; sets up Fail2Ban, turns off root login, and allows keys only |
| | `wireguard` | `k8s_nodes` | Builds the mesh, and writes client configs for extra peers to `generated/` |
| | `connection` (mesh) | `k8s_nodes` | Lists the nodes your machine can't reach over WireGuard yet |
| `02-cluster.yaml` | `connection` (mesh) | `k8s_nodes` | Stops the run if your machine can't reach a node over WireGuard |
| | `node_baseline` | `k8s_nodes` | Sets the hostname, timezone and NTP, turns off swap and rpcbind, and loads kernel modules and sysctls. Upgrades the OS, and reboots if it asks to, but only before RKE2 is installed |
| | `rke2` | `k8s_nodes` | Installs RKE2 on nodes that don't run it yet: the first master, then the other masters, then the workers. On masters, it puts `kubectl`, `crictl` and `ctr` on the PATH and writes a kubeconfig for the admin user |
| `03-flux.yaml` | `connection` (mesh) | first master | Stops the run if your machine can't reach it over WireGuard |
| | `flux_bootstrap` | first master | Installs Helm, then Cilium and Flux Operator from k8s-fleet's files. Creates the deploy key and age key Secrets and the FluxInstance, then waits until Flux is Ready |

You can run any of them again safely:

- A node that's already on the mesh gets peer changes in place, without dropping the tunnel. Changing a node's address or prefix needs `wg0` restarted on each node.
- `02-cluster.yaml` never upgrades, restarts or reboots a node that already runs RKE2.
- `03-flux.yaml` skips the components Flux already manages and leaves the FluxInstance alone. It does update the two Secrets, which makes it the way to rotate the deploy key or the cluster's age key.

The Flux bootstrap clones k8s-fleet's `main` fresh on every run. It installs what Flux will sync, never your local edits, so push your k8s-fleet changes before running it.

## Day 2

### Upgrade RKE2, the OS or RKE2's config

Change `rke2_version` or the RKE2 config, then run `ansible-playbook upgrade.yaml`. It works through one node at a time, masters first. It drains and reboots a node only if the node's RKE2 version or config changed, or the OS asks for a reboot. Each node has to be Ready before the next one starts, and every etcd member has to be Ready before a master goes down.

[Renovate](https://docs.renovatebot.com/) opens a pull request for each new RKE2 version, one minor version at a time, because RKE2 can't skip a minor. Merging the pull request only changes the file, so you still have to run `upgrade.yaml`.

### Restore etcd

```sh
ansible-playbook restore-etcd.yaml -e rke2_etcd_snapshot_name=<snapshot>
```

The restore brings the first master back from a snapshot. To find the snapshot's name, run `rke2 etcd-snapshot list` on a master. The first master can be a fresh node with the same WireGuard IP: run `01-mesh.yaml` on it first, and then `restore-etcd.yaml`.

1. **Before restore:** no other master can be running etcd. On each one, stop `rke2-server` and delete `/var/lib/rancher/rke2/server/db`, or rebuild the master. The playbook stops if any of them answers on port 2379.
2. **After restore:** run `02-cluster.yaml` to rejoin the other nodes. Rebuilt masters and workers need `01-mesh.yaml` first. A rebuilt worker also needs `kubectl delete node <name>` before it joins, or it's rejected because its new node password doesn't match the stored one. Workers that kept running reconnect on their own after some time.
3. **`upgrade.yaml`:** a worker that kept running still holds the state it saw after the snapshot was taken, so Cilium may drop its pods' traffic. A reboot fixes this. The restore marks every worker it can reach for a reboot, and `upgrade.yaml` then reboots them one at a time.

### Add a node or an admin machine

To add a node, add it to `inventory/hosts.yaml` and run `01-mesh.yaml`. Import the updated client config so your machine can reach the new node, then run `02-cluster.yaml`.

To add an admin machine, add it to `wireguard_extra_peers` with a `client_ip` in `10.0.3.0/24`, run `01-mesh.yaml`, and import its config from `generated/`. To give a machine access to only some nodes, such as a tenant's device that only needs the workers, set the peer's `group` to that inventory group. The other nodes don't list the peer, so they drop its traffic. Other per-peer options, such as MTU and keepalive, are in `roles/wireguard/defaults/main.yaml`.

### Tear down

`ansible-playbook destroy.yaml` removes RKE2 from every node once you type `destroy-cluster` to confirm. WireGuard and the hosts themselves stay in place.

## CI

ansible-lint runs with the production profile and doesn't need to decrypt anything. A second job fails if any `*.sops.yaml` file isn't encrypted. Both run on every push to `main` and on pull requests. Nothing runs the playbooks against real nodes: the manual test cases are in [TESTING.md](TESTING.md).
