# Testing

Nothing tests these playbooks against real nodes automatically. Before pushing a change, run the cases it touches on fresh VPSs.

## New cluster

Verify that `01-mesh.yaml` and `02-cluster.yaml` build the cluster in each of these cases:

- [ ] All nodes in one run
- [ ] One master first, then the rest
- [ ] One master and a worker first, then two more masters

## Flux bootstrap

- [ ] On a new cluster, verify `03-flux.yaml` ends with every node `Ready`, and with everything in `kubectl -n flux-system get fluxinstance,kustomizations,helmreleases` `Ready`.
- [ ] Verify Flux adopted the two Helm releases: `helm -n cilium-system history cilium` and `helm -n flux-system history flux-operator` each show a revision after the bootstrap's.
- [ ] Change a value in a component's `values.yaml` in k8s-fleet and push. Verify Flux upgrades the release without a field-manager conflict.
- [ ] Run `03-flux.yaml` again. Verify it makes no Helm calls and leaves the FluxInstance alone.

## Upgrade

- [ ] Change `rke2_version` and run `upgrade.yaml`. Verify it goes one node at a time, masters first: each node is drained, rebooted, `Ready` and uncordoned before the next one starts, and before a master goes down, every etcd member is `Ready`.
- [ ] Right after the run ends, verify `kubectl get nodes` shows the new version on every node, the last one included, and everything in `kubectl -n flux-system get fluxinstance,kustomizations,helmreleases` is `Ready`.
- [ ] Run `upgrade.yaml` again without changes. Verify no node is drained or rebooted, unless the OS asks for a reboot.

## etcd snapshots with `rke2_etcd_s3: true`

- [ ] Run `sudo rke2 etcd-snapshot save` on a master, then verify the snapshot shows in `sudo rke2 etcd-snapshot list` and in the bucket's console.
- [ ] After 7 days, verify each master has no more than 28 scheduled snapshots in the bucket. Make sure the bucket is configured to allow deletion, or use a lifecycle rule to delete old snapshots.

## etcd restore

Run these on freshly reinstalled VPSs. A node where RKE2 was only uninstalled can behave differently.

- [ ] Reinstall the masters and run `01-mesh.yaml`, then `restore-etcd.yaml` on the first master. Verify that `02-cluster.yaml` then joins the other masters to the restored cluster.
- [ ] Verify the snapshot's data is back: a ConfigMap created before the snapshot and deleted after it exists again after the restore.
- [ ] Verify that a worker from before the restore reconnects, and that `upgrade.yaml` then drains and reboots it, after which its pods run.
- [ ] Verify Flux resumes from the restored cluster without rerunning `03-flux.yaml`, and catches up with `main` if it changed after the snapshot.
