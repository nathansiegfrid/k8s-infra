# Testing

Nothing tests these playbooks against real nodes automatically. Before pushing a change, run the cases it touches on fresh VPSs.

## New cluster

Verify that `01-mesh.yaml` and `02-cluster.yaml` build the cluster in each of these cases:

- [ ] All nodes in one run
- [ ] One master first, then the rest
- [ ] One master and a worker first, then two more masters

## etcd snapshots with `rke2_etcd_s3: true`

- [ ] Run `sudo rke2 etcd-snapshot save` on a master, then verify the snapshot shows in `sudo rke2 etcd-snapshot list` and in the bucket's console.
- [ ] After 7 days, verify each master has no more than 28 scheduled snapshots in the bucket. Make sure the bucket is configured to allow deletion, or use a lifecycle rule to delete old snapshots.
