# Examples

Ready-to-use values files, overlays and helper scripts for the `openbao`
chart in [`charts/openbao`](../charts/openbao). Each file starts with a
comment block that explains what it deploys, the prerequisites, how to
install it and what to do after installation.

Full documentation: [`docs/chart/`](../docs/chart/00-index.md).

## Base values files

Pick exactly one.

| File | Mode | Production | Needs |
|------|------|------------|-------|
| [`dev.yaml`](dev.yaml) | Persistent dev server, auto-init and auto-unseal, plain HTTP | No | StorageClass |
| [`standalone.yaml`](standalone.yaml) | 1 replica, `file` backend, TLS, audit volume | Limited | StorageClass, cert-manager |
| [`ha-raft.yaml`](ha-raft.yaml) | 3 replicas, integrated Raft, TLS, generated `retry_join` with CA, telemetry | **Yes** | 3 nodes, SSD StorageClass, cert-manager |
| [`ha-postgresql.yaml`](ha-postgresql.yaml) | 2 replicas, PostgreSQL backend, TLS | Yes | PostgreSQL, Secret `openbao-pg`, cert-manager |
| [`external.yaml`](external.yaml) | No server; reviewer ServiceAccount for an external OpenBao, optional snapshot agent | n/a | An external OpenBao |

## Overlays

Add after a base file with another `-f`. Later files win.

| File | Adds | Use with |
|------|------|----------|
| [`overlays/monitoring.yaml`](overlays/monitoring.yaml) | ServiceMonitor, PrometheusRule with alerts, Grafana dashboard | `ha-raft.yaml`, `ha-postgresql.yaml` (their configs enable telemetry) |
| [`overlays/snapshot-s3.yaml`](overlays/snapshot-s3.yaml) | Snapshot agent CronJob to S3 | `ha-raft.yaml` (Raft only) |
| [`overlays/openshift-route.yaml`](overlays/openshift-route.yaml) | Passthrough Route, OpenShift settings | `charts/openbao/values.openshift.yaml` + a base file |

```bash
helm upgrade --install openbao ./charts/openbao -n openbao --create-namespace \
  -f examples/ha-raft.yaml \
  -f examples/overlays/monitoring.yaml \
  -f examples/overlays/snapshot-s3.yaml
```

## Scripts

Bash 4+, `kubectl` and `jq`. Each script supports `--help`, validates its
arguments and exits with a non-zero code and a clear message on errors.

| Script | Purpose |
|--------|---------|
| [`scripts/init-unseal.sh`](scripts/init-unseal.sh) | Initialize `<fullname>-0`, store the keys in a `0600` file (never overwrites), unseal every pod, wait for Ready. Keys are sent on stdin, not as arguments |
| [`scripts/configure-snapshot-auth.sh`](scripts/configure-snapshot-auth.sh) | Idempotently create the Kubernetes auth method, the `snapshot` policy and role for the snapshot agent. Token read from `$BAO_TOKEN` |
| [`scripts/validate-examples.sh`](scripts/validate-examples.sh) | `helm lint` and `helm template` for every example and overlay combination, checks expected kinds and negative cases; `--server` adds `kubectl apply --dry-run=server` |

```bash
# HA with Raft, first start
examples/scripts/init-unseal.sh -n openbao -r openbao -p 3

# Snapshot agent prerequisites
BAO_TOKEN=<admin-token> examples/scripts/configure-snapshot-auth.sh -n openbao

# Check all examples after changing the chart
examples/scripts/validate-examples.sh
```

On Windows, run the scripts in WSL or Git Bash.

## Editor support

Every values file starts with

```yaml
# yaml-language-server: $schema=../charts/openbao/values.schema.json
```

so editors with the YAML language server (VS Code YAML extension, JetBrains)
validate keys and types against the chart schema while you edit.

## Tests

[`test/unit/examples.bats`](../test/unit/examples.bats) renders every example
and checks the important parts (TLS listener, `retry_join` count, storage
backend, CronJob address, Route). Run:

```bash
bats test/unit/examples.bats
```

## Before production

- Replace `generateIssuer: true` with `clusterIssuerName` for a real CA.
- Set `storageClass`, resources and the external host names.
- Choose manual unseal or auto-unseal ([docs](../docs/chart/12-advanced.md#2-auto-unseal)).
- Store the unseal or recovery keys away from the cluster, and revoke the
  initial root token after creating admin access.
- Read [`docs/chart/14-known-issues.md`](../docs/chart/14-known-issues.md).
