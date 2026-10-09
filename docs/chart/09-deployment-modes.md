# Deployment Modes

This document is the practical guide to every topology the chart supports.
For each mode it gives a complete values file, the objects that are created,
the rendered server configuration, the first-start procedure, day-2
operations and the limitations. The last sections compare the modes and
describe how to move from one to another.

- [1. Overview](#1-overview)
- [2. Dev mode](#2-dev-mode)
- [3. Standalone mode](#3-standalone-mode)
- [4. HA with integrated Raft](#4-ha-with-integrated-raft)
- [5. HA with external storage](#5-ha-with-external-storage)
- [6. External mode](#6-external-mode)
- [7. Mode comparison](#7-mode-comparison)
- [8. Migrating between modes](#8-migrating-between-modes)
  - [8.2 Standalone to HA with Raft](#82-standalone-to-ha-with-raft)
  - [8.5 Migrating a file-backed standalone to Raft](#85-migrating-a-file-backed-standalone-to-raft)

> Examples in this document have not yet been checked with `helm template`
> or on a live cluster. Statements marked "(verify)" depend on OpenBao
> runtime behavior that should be confirmed for your version.

Every mode section uses the same structure:

1. **Purpose**: what the mode is for and when to choose it.
2. **Values**: a minimal and a production-oriented values file.
3. **Rendered objects**: what the chart creates.
4. **Server configuration**: the HCL the server receives.
5. **First start**: initialization and unseal.
6. **Operations**: upgrades, scaling, backups.
7. **Limitations**.

The mode is derived from several switches. If you have not read it yet, see
[02-concepts.md §1](02-concepts.md#1-deployment-mode-resolution).

---

## 1. Overview

| Mode | Switches | Replicas | Storage | Unseal | Production |
|------|----------|----------|---------|--------|------------|
| [Dev](#2-dev-mode) | `dev_mode.enabled: true` (**default**) | 1 | Single-node integrated Raft on a PVC | Automatic (key on the PVC) | No |
| [Standalone](#3-standalone-mode) | `dev_mode.enabled: false`, `standalone.enabled: true` or `"-"` | 1 | Single-node integrated Raft on a PVC | Manual or auto-unseal | Limited |
| [HA + Raft](#4-ha-with-integrated-raft) | `dev_mode.enabled: false`, `ha.enabled: true`, `ha.raft.enabled: true` | 3 (or 5) | Integrated Raft, one PVC per pod | Manual or auto-unseal | **Yes** (recommended) |
| [HA + external storage](#5-ha-with-external-storage) | `dev_mode.enabled: false`, `ha.enabled: true`, `ha.raft.enabled: false` | 2 or more | External database (PostgreSQL) | Manual or auto-unseal | Yes |
| [External](#6-external-mode) | `global.externalBaoAddr` set | 0 | Outside the cluster | n/a | n/a |

```mermaid
flowchart LR
  start([Choose a mode]) --> q1{Need a server<br/>in this cluster?}
  q1 -- no --> ext[External]
  q1 -- yes --> q2{Production data?}
  q2 -- no --> dev[Dev]
  q2 -- yes --> q3{Need high availability?}
  q3 -- no --> sa[Standalone<br/>with auto-unseal]
  q3 -- yes --> q4{Existing PostgreSQL<br/>cluster you trust?}
  q4 -- yes --> hapg[HA + PostgreSQL]
  q4 -- no --> haraft[HA + Raft]
```

---

## 2. Dev mode

### 2.1 Purpose

A single, self-bootstrapping OpenBao for development, demos and CI. It needs
no manual steps: the server initializes itself on first start and unseals
itself on every restart. Data is stored on a PVC, so it survives restarts.

Choose it when the data has no value and convenience matters more than
security.

### 2.2 Values

The chart defaults already give dev mode. The shipped example
[`examples/dev.yaml`](../../examples/dev.yaml) adds small resources, a 1Gi
PVC that is deleted with the StatefulSet, and no anti-affinity:

```bash
helm upgrade --install openbao ./charts/openbao -n openbao --create-namespace \
  -f examples/dev.yaml
```

Or with the shipped profile:

```bash
helm upgrade --install openbao ./charts/openbao -n openbao --create-namespace \
  -f charts/openbao/resource-profiles/dev.yaml
```

Dev mode with TLS, for testing TLS clients. Because the resolved mode is
`standalone`, the TLS Secret is mounted and the listener uses it (see
[§2.4](#24-server-configuration)):

```yaml
global:
  tlsDisable: false
server:
  dev_mode:
    enabled: true
  tls:
    source: certManager
    certManager:
      generateIssuer: true
```

Dev mode with TLS needs a CA that the in-pod CLI trusts: the bootstrap
script and the readiness probe run `bao status` with `BAO_CACERT` (see
[14-known-issues.md](14-known-issues.md) #4). The cert-manager source
provides `ca.crt`.

### 2.3 Rendered objects

Dev mode resolves to the `standalone` mode internally. It renders the same
objects as [standalone](#33-rendered-objects), and in addition replaces the
`postStart` hook with the bootstrap script.

### 2.4 Server configuration

The `server.dev_mode.config` value is **not used**. The `openbao.mode` helper
never returns `dev`, so the config ConfigMap is built from
`server.standalone.config`. The rendered HCL with TLS off:

```hcl
ui = true

listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_disable = 1
}

# Single-node integrated Raft storage. node_id comes from BAO_RAFT_NODE_ID
# (the pod name), cluster_addr from BAO_CLUSTER_ADDR.
storage "raft" {
  path = "/openbao/data"
}
```

To customize the dev server, edit `server.standalone.config`, not
`server.dev_mode.config`.

### 2.5 First start

No action is needed. The bootstrap script in the `postStart` hook:

1. waits up to 60 seconds for the API;
2. on the first start, runs `bao operator init -key-shares=1 -key-threshold=1`
   and stores the output in `<dataStorage.mountPath>/bootstrap-keys.json`;
3. on every start, unseals the server with the key from that file.

Read the root token:

```bash
kubectl -n openbao exec openbao-0 -- cat /openbao/data/bootstrap-keys.json
```

Bootstrap log:

```bash
kubectl -n openbao exec openbao-0 -- cat /tmp/openbao.log
```

The script uses `set -e`. If initialization fails (for example, the API does
not come up within 60 seconds), the hook fails, and the kubelet kills and
restarts the container.

### 2.6 Operations

| Task | How |
|------|-----|
| Restart | `kubectl -n openbao delete pod openbao-0`. The pod comes back unsealed |
| Upgrade the chart or OpenBao | `helm upgrade ...`, then delete the pod (`OnDelete` strategy) |
| Reset all data | `helm uninstall`, `kubectl delete pvc data-openbao-0`, install again |
| Move to standalone and keep the data | [§8.1](#81-dev-to-standalone) |

### 2.7 Limitations

- **Insecure by design.** The only unseal key and the root token are stored
  in plain text on the data volume. Anyone with `pods/exec` or access to the
  volume or its backups has full access.
- Single replica only. `dev_mode.enabled: true` together with
  `ha.enabled: true` fails the render.
- `server.postStart` is ignored.
- Uses the same single-node Raft storage as standalone. A dev volume created
  by an older chart version (with the `file` backend) is refused at start by
  the legacy-data guard; see [§8.5](#85-migrating-a-file-backed-standalone-to-raft).
- With `dev_mode.enabled: true` and `standalone.enabled: false`, no server
  pod is deployed at all.

---

## 3. Standalone mode

### 3.1 Purpose

A single OpenBao server that **you** initialize and unseal, or that unseals
itself through an external key management service. It is the simplest
non-dev topology.

Standalone runs on **integrated storage (Raft consensus)** as a one-node
cluster. The node is a voter, holds a quorum of 1 out of 1, and becomes the
leader as soon as it is unsealed. Compared with the `file` backend used by
older chart versions, this gives you:

| Capability | Old standalone (`file`) | Standalone (single-node Raft) |
|------------|-------------------------|-------------------------------|
| Storage engine | `file`, not transactional, no locking | Integrated Raft (BoltDB, transactional), the engine OpenBao recommends |
| Online backups | No (stop the pod, copy the volume) | `bao operator raft snapshot save/restore`, snapshot agent |
| Growing to HA | Offline `bao operator migrate` (file → raft) | In-place: change values, new pods join through `retry_join` ([§8.2](#82-standalone-to-ha-with-raft)) |
| Cluster health | — | `bao operator raft list-peers`, `bao operator raft autopilot state` |
| Availability | Single pod | Single pod (unchanged: **not** HA) |

Choose it for small internal installations where an outage during a pod
restart or node failure is acceptable, ideally with auto-unseal, and that may
need to grow into HA later.

How the chart wires the single node:

| Setting | Value in standalone | Source |
|---------|---------------------|--------|
| `storage "raft" { path }` | `server.dataStorage.mountPath` (default `/openbao/data`) | `server.standalone.config` |
| Raft node ID | pod name (`openbao-0`) | `BAO_RAFT_NODE_ID`, always set in standalone |
| Cluster address | `https://openbao-0.openbao-internal:8201` | `BAO_CLUSTER_ADDR` (`server.ha.clusterAddr` overrides) |
| API address | `<scheme>://$(POD_IP):8200` | `BAO_API_ADDR` (`server.ha.apiAddr` overrides) |
| `retry_join` | none, a single node never joins anyone | — |
| `service_registration` | none (no discovery RBAC in standalone) | — |
| Replicas | always `1` | `openbao.replicas` helper |

The node ID is pinned to the pod name so that it stays stable across
restarts and is identical to the ID the pod gets after a move to HA with
`ha.raft.setNodeId: true`.

### 3.2 Values

Minimal:

```yaml
# Minimal standalone values (TLS off). The shipped examples/standalone.yaml
# adds TLS, an audit volume and hardening.
server:
  dev_mode:
    enabled: false
  standalone:
    enabled: true
  dataStorage:
    size: 10Gi
```

Production-oriented, with TLS, an audit volume, Transit auto-unseal, Raft
tuning and telemetry:

```yaml
global:
  tlsDisable: false

server:
  dev_mode:
    enabled: false
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        address = "[::]:8200"
        cluster_address = "[::]:8201"
        {{- if .Values.global.tlsDisable }}
        tls_disable = 1
        {{- else }}
        tls_cert_file = "{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.certKey }}"
        tls_key_file  = "{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.keyKey }}"
        tls_min_version = "{{ .Values.server.tls.tlsMinVersion }}"
        {{- end }}
        telemetry {
          unauthenticated_metrics_access = "true"
        }
      }

      # Single-node integrated storage. Keep `path` equal to
      # server.dataStorage.mountPath. No retry_join: there is nobody to join.
      storage "raft" {
        path = "{{ .Values.server.dataStorage.mountPath }}"
        # 1 = production timing. The default (0, i.e. 5) is tuned for
        # minimal hardware.
        performance_multiplier = 1
      }

      seal "transit" {
        address    = "TRANSIT_ADDR"
        key_name   = "openbao-autounseal"
        mount_path = "transit/"
      }

      telemetry {
        prometheus_retention_time = "30s"
        disable_hostname = true
      }

  extraEnvironmentVars:
    TRANSIT_ADDR: https://transit.example.com:8200
  extraSecretEnvironmentVars:
    - envName: BAO_TOKEN
      secretName: transit-unseal-token
      secretKey: token

  tls:
    source: certManager
    certManager:
      clusterIssuerName: corp-ca

  dataStorage:
    size: 10Gi
    storageClass: premium-ssd     # Raft fsyncs every write: use SSDs
  auditStorage:
    enabled: true
    size: 10Gi

  resources:
    requests: { cpu: 250m, memory: 256Mi }
    limits:   { cpu: 250m, memory: 256Mi }

  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain

  # With auto-unseal a restart needs no operator, so let the
  # StatefulSet controller replace the pod on upgrades.
  updateStrategyType: RollingUpdate

serverTelemetry:
  serviceMonitor:
    enabled: true

# Raft storage makes scheduled snapshots possible in standalone.
snapshotAgent:
  enabled: true
  schedule: "0 */6 * * *"
  s3CredentialsSecret: openbao-snapshot-s3
```

Rules for a custom `server.standalone.config`:

- Keep a `storage "raft"` block whose `path` equals
  `server.dataStorage.mountPath`. Using the template expression above keeps
  them in sync.
- Do not add `retry_join` blocks. A standalone node that joins another
  cluster is no longer standalone, and the chart does not render the HA
  Services and PDB for it.
- Do not add `service_registration "kubernetes"`. Standalone renders no
  discovery Role, so the server logs permission errors
  ([08-security-and-rbac.md](08-security-and-rbac.md)).
- Do not set `node_id` in the config. `BAO_RAFT_NODE_ID` already sets it to
  the pod name; a different value breaks the in-place move to HA.
- A YAML map is also accepted (rendered as JSON):

  ```yaml
  server:
    standalone:
      config:
        ui: true
        listener:
          tcp:
            address: "[::]:8200"
            cluster_address: "[::]:8201"
            tls_disable: 1
        storage:
          raft:
            path: /openbao/data
  ```

| Value | Default | Description |
|-------|---------|-------------|
| `server.standalone.enabled` | `"-"` | `true` or `"-"` selects standalone when HA is off |
| `server.standalone.config` | single-node Raft HCL | Server configuration (string HCL with `tpl`, or a map) |
| `server.standalone.legacyFileDataCheck` | `true` | Refuse to start when the data volume still holds `file` backend data ([§8.5](#85-migrating-a-file-backed-standalone-to-raft)) |

The shipped profile `resource-profiles/small.yaml` sets the same mode and
resources (`-f charts/openbao/resource-profiles/small.yaml`). The profile
`large.yaml` is also standalone, with 1 CPU and 1Gi.

### 3.3 Rendered objects

| Object | Name |
|--------|------|
| StatefulSet (1 replica) | `openbao` |
| ConfigMap | `openbao-config` |
| PVC | `data-openbao-0` (plus `audit-openbao-0` if enabled) |
| Services | `openbao`, `openbao-internal` |
| ServiceAccount, ClusterRoleBinding | `openbao`, `openbao-server-binding` |
| TLS objects | when TLS is on ([07-tls.md](07-tls.md)) |
| Snapshot agent CronJob | when `snapshotAgent.enabled`; `BAO_ADDR` is `openbao.<ns>.svc` |

No PodDisruptionBudget, no active or standby Services, and no discovery Role.

### 3.4 Server configuration

The default `server.standalone.config` with TLS on:

```hcl
ui = true

listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_disable = 0
  tls_cert_file = "/openbao/tls/tls.crt"
  tls_key_file  = "/openbao/tls/tls.key"
  tls_min_version = "tls12"
}

# Single-node integrated Raft storage. node_id comes from BAO_RAFT_NODE_ID
# (the pod name), cluster_addr from BAO_CLUSTER_ADDR.
storage "raft" {
  path = "/openbao/data"
}
```

The default config contains commented-out examples for a `gcpckms` seal and
a `telemetry` block.

Environment added by the StatefulSet:

| Variable | Value |
|----------|-------|
| `BAO_RAFT_NODE_ID` | pod name (`metadata.name`) |
| `BAO_CLUSTER_ADDR` | `https://$(HOSTNAME).openbao-internal:8201` |
| `BAO_API_ADDR` | `<scheme>://$(POD_IP):8200` |

Before `bao server` starts, the container command checks the data volume.
If `<mountPath>/core/` exists but `<mountPath>/vault.db` does not, the volume
was written by the old `file` backend and the container exits with:

```text
ERROR: /openbao/data contains data of the legacy 'file' storage backend, but standalone mode now uses integrated Raft storage.
ERROR: Starting would expose an empty, uninitialized OpenBao. Migrate the data with 'bao operator migrate' ...
```

Without this guard the pod would start an empty, uninitialized Raft node
next to the old data, and the next `bao operator init` would create a new,
empty OpenBao. Migrate as described in
[§8.5](#85-migrating-a-file-backed-standalone-to-raft).

Data layout on `data-openbao-0` after the first start:

```text
/openbao/data/
├── vault.db            # Raft FSM (BoltDB): the encrypted key/value data
└── raft/
    ├── raft.db         # Raft log and stable store
    └── snapshots/      # internal Raft snapshots (log compaction)
```

### 3.5 First start

The pod starts **uninitialized and sealed**. With the default exec readiness
probe it stays `Running` but not Ready (`0/1`) until it is unsealed.

```bash
kubectl -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=180s
kubectl -n openbao exec openbao-0 -- bao status        # Initialized: false, Sealed: true, Storage Type: raft
```

Initialize with 5 key shares and a threshold of 3:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao operator init -key-shares=5 -key-threshold=3 -format=json > openbao-init.json
```

`openbao-init.json` now contains all unseal keys and the root token. Give
each share to a different key holder, store them in separate secure places
and delete the file.

Unseal with 3 of the 5 shares:

```bash
kubectl -n openbao exec openbao-0 -- bao operator unseal <share-1>
kubectl -n openbao exec openbao-0 -- bao operator unseal <share-2>
kubectl -n openbao exec openbao-0 -- bao operator unseal <share-3>
kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=60s
```

The same in one step with the shipped script (keys go to the pod on stdin):

```bash
examples/scripts/init-unseal.sh -n openbao -r openbao
```

With auto-unseal (KMS or Transit), `bao operator init` returns **recovery
keys** instead, and the server unseals itself on every start:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao operator init -recovery-shares=5 -recovery-threshold=3
```

Then log in, check the one-node Raft cluster and turn on auditing:

```bash
kubectl -n openbao exec -it openbao-0 -- bao login
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers
kubectl -n openbao exec openbao-0 -- bao audit enable file file_path=/openbao/audit/audit.log
```

```text
Node         Address                            State     Voter
----         -------                            -----     -----
openbao-0    openbao-0.openbao-internal:8201    leader    true
```

`bao status` now shows `HA Enabled: true`, `HA Mode: active` and
`Raft Committed Index`. HA here only means the Raft machinery is on; with a
single node there is no standby to fail over to.

### 3.6 Operations

| Task | How |
|------|-----|
| Restart or upgrade | `helm upgrade`, delete the pod, unseal again (unless auto-unseal). With auto-unseal, `updateStrategyType: RollingUpdate` is safe |
| Health | `bao operator raft list-peers`, `bao operator raft autopilot state` (needs a token) |
| Back up (manual) | `bao operator raft snapshot save` on the running server, see below |
| Back up (scheduled) | Snapshot agent to S3: `-f examples/overlays/snapshot-s3.yaml` ([11-backup-snapshot-agent.md](11-backup-snapshot-agent.md)) |
| Restore | `bao operator raft snapshot restore`, see below |
| Resize the volume | [05-storage.md §5](05-storage.md#5-resizing-volumes) |
| Move to HA | In place, [§8.2](#82-standalone-to-ha-with-raft) |

Online backup, without stopping the server:

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot save /tmp/bao.snap
kubectl -n openbao cp openbao-0:/tmp/bao.snap ./bao-$(date +%F).snap
kubectl -n openbao exec openbao-0 -- rm /tmp/bao.snap
```

Restore into the same server (same unseal keys):

```bash
kubectl -n openbao cp ./bao-2026-10-01.snap openbao-0:/tmp/restore.snap
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot restore /tmp/restore.snap
```

Restore into a freshly installed server that was initialized with other
keys (disaster recovery, new namespace or cluster):

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot restore -force /tmp/restore.snap
# From now on the server uses the unseal keys (or KMS key) of the SNAPSHOT.
# If it is sealed after the restore or after the next restart, unseal it
# with the old shares:
kubectl -n openbao exec openbao-0 -- bao operator unseal <old-share-1>   # ... threshold times
```

Snapshot policy for a non-root operator token:

```hcl
path "sys/storage/raft/snapshot"       { capabilities = ["read", "update"] }
path "sys/storage/raft/snapshot-force" { capabilities = ["update"] }
path "sys/storage/raft/configuration"  { capabilities = ["read"] }
```

Without auto-unseal, every restart (node drain, eviction, OOM kill, upgrade)
leaves OpenBao sealed until a key holder acts. Plan for that, or use
auto-unseal.

### 3.7 Limitations

- One replica. Do not scale the StatefulSet with `kubectl scale`. A second
  pod would get its own empty PVC and its own separate, uninitialized
  one-node cluster (there is no `retry_join`). To add nodes, switch to HA as
  in [§8.2](#82-standalone-to-ha-with-raft).
- Downtime on every restart; a lost node means downtime until the pod is
  rescheduled and its volume is attached again.
- Raft writes with `fsync`. Slow network storage increases request latency.
- Snapshots are encrypted with the barrier key. Keep the unseal or recovery
  keys (or the KMS key) with the backups.
- Volumes from chart versions with the `file` backend need a one-time
  migration ([§8.5](#85-migrating-a-file-backed-standalone-to-raft)).

---

## 4. HA with integrated Raft

### 4.1 Purpose

A highly available cluster of 3 or 5 OpenBao servers. Each server keeps a
full copy of the data in integrated Raft storage on its own PVC. One server
is the active leader; the others are standbys that forward requests to it
and take over if it fails. This is the **recommended production topology**.

Raft needs a majority (quorum) of voters to work:

| Replicas | Quorum | Tolerated failures |
|----------|--------|--------------------|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |

Use an odd number. 4 replicas tolerate only 1 failure, like 3.

### 4.2 Values

Minimal:

```yaml
# Minimal HA Raft values (TLS off). The shipped examples/ha-raft.yaml is the
# production-oriented version below, without auto-unseal.
server:
  dev_mode:
    enabled: false
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
```

The shipped profiles `medium.yaml` (500m, 512Mi) and `prod.yaml` (250m,
256Mi) both set HA with Raft, 3 replicas and a PDB with
`maxUnavailable: 1`.

Production-oriented, with TLS, zone spreading, auto-unseal and monitoring:

```yaml
global:
  tlsDisable: false

server:
  dev_mode:
    enabled: false

  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true

        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.certKey }}"
          tls_key_file  = "{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.keyKey }}"
          tls_min_version = "{{ .Values.server.tls.tlsMinVersion }}"
          telemetry {
            unauthenticated_metrics_access = "true"
          }
        }

        storage "raft" {
          path = "{{ .Values.server.dataStorage.mountPath }}"
          performance_multiplier = 1
          {{- $fullname := include "openbao.fullname" . }}
          {{- range $i := until (int .Values.server.ha.replicas) }}
          retry_join {
            leader_api_addr     = "https://{{ $fullname }}-{{ $i }}.{{ $fullname }}-internal:8200"
            leader_ca_cert_file = "{{ $.Values.server.tls.mountPath }}/{{ $.Values.server.tls.caKey }}"
          }
          {{- end }}
        }

        seal "transit" {
          address    = "TRANSIT_ADDR"
          key_name   = "openbao-autounseal"
          mount_path = "transit/"
        }

        service_registration "kubernetes" {}

        telemetry {
          prometheus_retention_time = "30s"
          disable_hostname = true
        }
    disruptionBudget:
      enabled: true
      maxUnavailable: 1

  extraEnvironmentVars:
    TRANSIT_ADDR: https://transit.example.com:8200
  extraSecretEnvironmentVars:
    - envName: BAO_TOKEN
      secretName: transit-unseal-token
      secretKey: token

  tls:
    source: certManager
    certManager:
      clusterIssuerName: corp-ca
      extraSans:
        - openbao.example.com

  dataStorage:
    size: 20Gi
    storageClass: premium-ssd
  auditStorage:
    enabled: true

  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { cpu: 500m, memory: 512Mi }

  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: openbao
          app.kubernetes.io/instance: openbao
          component: server

  updateStrategyType: RollingUpdate     # safe only with auto-unseal

serverTelemetry:
  serviceMonitor:
    enabled: true

snapshotAgent:
  enabled: true
  schedule: "0 */6 * * *"
  s3CredentialsSecret: openbao-snapshot-s3
```

Notes on the custom Raft config above:

- `retry_join` blocks are **generated from `server.ha.replicas`**. The default
  config hard-codes exactly three blocks (`-0`, `-1`, `-2`).
- `leader_ca_cert_file` lets a joining node verify the leader's certificate.
  The default config does not set it. With a CA that is not in the image's
  system trust store (for example `generateIssuer: true`), joins over HTTPS
  can fail with `x509: certificate signed by unknown authority` (verify for
  your version).
- `performance_multiplier = 1` is the setting OpenBao recommends for
  production servers. The default (`0`, equivalent to `5`) is tuned for
  minimal servers.
- Remove the `seal` block and the `TRANSIT_ADDR` and `BAO_TOKEN` variables
  if you unseal manually. Then also keep `updateStrategyType: OnDelete`.

### 4.3 Rendered objects

| Object | Name |
|--------|------|
| StatefulSet (`server.ha.replicas`) | `openbao` |
| ConfigMap | `openbao-config` |
| PVCs | `data-openbao-0` to `-N` (plus `audit-*` if enabled) |
| Services | `openbao`, `openbao-internal`, `openbao-active`, `openbao-standby` |
| PodDisruptionBudget | `openbao` |
| Role and RoleBinding | `openbao-discovery-role`, `openbao-discovery-rolebinding` |
| ServiceAccount, ClusterRoleBinding | `openbao`, `openbao-server-binding` |
| TLS objects | when TLS is on. SANs include `-active` and `-standby` |

### 4.4 Server configuration

The default `server.ha.raft.config`, TLS off, release `openbao`:

```hcl
ui = true

listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_disable = 1
}
storage "raft" {
  path = "/openbao/data"
  retry_join {
    leader_api_addr = "http://openbao-0.openbao-internal:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-1.openbao-internal:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-2.openbao-internal:8200"
  }
}

service_registration "kubernetes" {}
```

The environment adds the HA addresses:

| Variable | Default value | Override |
|----------|---------------|----------|
| `BAO_API_ADDR` | `<scheme>://$(POD_IP):8200` | `server.ha.apiAddr` |
| `BAO_CLUSTER_ADDR` | `https://$(HOSTNAME).openbao-internal:8201` | `server.ha.clusterAddr` |
| `BAO_RAFT_NODE_ID` | pod name, only with `raft.setNodeId: true` | — |

Without `setNodeId`, OpenBao generates a random node ID and stores it on the
data volume. With `setNodeId: true`, `bao operator raft list-peers` shows
pod names, which makes operations much easier. Decide before the first
start; changing it later on an existing cluster changes the node identity
(verify).

### 4.5 First start

With the default `podManagementPolicy: OrderedReady`, only `openbao-0` is
created at first. `openbao-1` starts after `openbao-0` is Ready, which
requires it to be initialized and unsealed.

```mermaid
sequenceDiagram
    participant Op as Operator
    participant P0 as openbao-0
    participant P1 as openbao-1
    participant P2 as openbao-2
    Op->>P0: bao operator init
    Op->>P0: bao operator unseal (x threshold)
    Note over P0: leader, Ready
    P1->>P0: retry_join
    Op->>P1: bao operator unseal (x threshold)
    Note over P1: follower, Ready
    P2->>P0: retry_join
    Op->>P2: bao operator unseal (x threshold)
    Note over P2: follower, Ready
```

**Step 1.** Initialize the first pod:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao operator init -key-shares=5 -key-threshold=3 -format=json > openbao-init.json
```

**Step 2.** Unseal `openbao-0`:

```bash
for k in <share-1> <share-2> <share-3>; do
  kubectl -n openbao exec openbao-0 -- bao operator unseal "$k"
done
kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=120s
```

**Step 3.** Wait for `openbao-1` to be created. It joins the leader through
`retry_join`. Unseal it with the **same** keys:

```bash
kubectl -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-1 --timeout=180s
for k in <share-1> <share-2> <share-3>; do
  kubectl -n openbao exec openbao-1 -- bao operator unseal "$k"
done
```

If the node does not join by itself (check its logs for `retry_join`
errors), join it explicitly before unsealing:

```bash
kubectl -n openbao exec openbao-1 -- \
  bao operator raft join http://openbao-0.openbao-internal:8200
```

With TLS on, add `-leader-ca-cert="$(cat ca.crt)"` or set
`leader_ca_cert_file` in the config.

**Step 4.** Repeat step 3 for `openbao-2`.

**Step 5.** Check the cluster:

```bash
kubectl -n openbao exec -it openbao-0 -- bao login
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers
```

```text
Node         Address                            State       Voter
----         -------                            -----       -----
openbao-0    openbao-0.openbao-internal:8201    leader      true
openbao-1    openbao-1.openbao-internal:8201    follower    true
openbao-2    openbao-2.openbao-internal:8201    follower    true
```

```bash
kubectl -n openbao get pods -l component=server -L openbao-active
kubectl -n openbao get endpoints openbao-active openbao-standby
```

Faster bootstrap: with `server.podManagementPolicy: Parallel`, all pods start
at once and you can unseal them in any order after `openbao-0` is
initialized. With auto-unseal, only `bao operator init` on `openbao-0` is
needed; the other pods join and unseal by themselves.

### 4.6 Operations

#### Rolling restart and upgrades

With manual unseal, keep `updateStrategyType: OnDelete` and replace pods one
at a time, followers first:

```bash
# 1. Find the leader
kubectl -n openbao get pods -l component=server -L openbao-active

# 2. For each follower: delete, unseal, check
kubectl -n openbao delete pod openbao-2
#    ... unseal openbao-2 ...
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers

# 3. Leader last: step down first, then delete
kubectl -n openbao exec openbao-0 -- bao operator step-down
kubectl -n openbao delete pod openbao-0
#    ... unseal openbao-0 ...
```

Wait until every node shows as a healthy voter before you continue. Check
with `bao operator raft autopilot state` (verify availability in your
version).

With auto-unseal, `updateStrategyType: RollingUpdate` replaces the pods
automatically in reverse ordinal order and waits for each one to become
Ready.

#### PodDisruptionBudget

| Key | Default | Effect |
|-----|---------|--------|
| `server.ha.disruptionBudget.enabled` | `true` | Create the PDB |
| `server.ha.disruptionBudget.maxUnavailable` | `0` in `values.yaml` | Override. **`0` counts as unset** and the computed value is used |

The computed value is `(replicas / 2) - 1`, rounded down: `0` for 1 or 2
replicas, `1` for 3, `2` for 5. This always leaves a quorum during a node
drain. You cannot set `maxUnavailable: 0` to block all voluntary evictions;
the chart replaces `0` with the computed value.

#### Scaling

Scaling up from 3 to 5:

```bash
helm upgrade openbao ./charts/openbao -n openbao -f values.yaml \
  --set server.ha.replicas=5
```

`replicas` is not affected by the `OnDelete` strategy, so the new pods
`openbao-3` and `openbao-4` are created. They join through the `retry_join`
blocks and must be unsealed. If your config has only the three default
`retry_join` blocks, joining works only while one of `openbao-0` to
`openbao-2` is reachable (verify). Generate the blocks from `replicas`, as in
[§4.2](#42-values).

Scaling down from 5 to 3. Remove the peers **before** you delete the pods,
otherwise the cluster counts them as failed voters and may lose quorum:

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft remove-peer openbao-4
kubectl -n openbao exec openbao-0 -- bao operator raft remove-peer openbao-3
helm upgrade openbao ./charts/openbao -n openbao -f values.yaml \
  --set server.ha.replicas=3
```

With the default retention policy the PVCs `data-openbao-3` and `-4` stay.
Delete them, or the old data rejoins under the old node IDs when you scale up
again.

#### Backups

Take Raft snapshots from the active node:

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot save /tmp/raft.snap
kubectl -n openbao cp openbao-0:/tmp/raft.snap ./raft-$(date +%F).snap
```

Or enable the snapshot agent (`snapshotAgent.enabled: true`) for scheduled
snapshots to S3. See [11-backup-snapshot-agent.md](11-backup-snapshot-agent.md).

Restore into the same cluster:

```bash
kubectl -n openbao cp ./raft.snap openbao-0:/tmp/raft.snap
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot restore /tmp/raft.snap
```

Restore into a new cluster initialized with different keys:

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot restore -force /tmp/raft.snap
```

After a forced restore, the cluster uses the unseal keys (or KMS key) of the
**snapshot**. Keep them with the backup.

#### Losing quorum

If a majority of nodes is permanently lost, the cluster cannot elect a
leader. Recovery requires writing a `peers.json` file on a surviving node
(the standard Raft recovery procedure) or restoring a snapshot into a new
cluster. Practice it before you need it.

### 4.7 Limitations

- Needs at least 3 schedulable nodes with the default **required** pod
  anti-affinity.
- The default `retry_join` list is hard-coded for 3 replicas.
- The default config sets no `leader_ca_cert_file`. Joins over HTTPS with a
  private CA may fail.
- Raft is sensitive to disk and network latency. Use SSD storage and avoid
  burstable CPU.
- Manual unseal of every pod after every restart, unless auto-unseal is set.
- Cannot be combined with dev mode.

---

## 5. HA with external storage

### 5.1 Purpose

Several OpenBao servers that share one external storage backend that
supports HA locking. Only one server is active; the others are standbys.
There are no data PVCs in the cluster.

Choose it if your organization already runs a managed, backed-up PostgreSQL
cluster and prefers it to operating Raft.

### 5.2 The default Consul config does not work with OpenBao 2.x

Setting `server.ha.enabled: true` with `raft.enabled: false` uses
`server.ha.config`, which by default contains:

```hcl
storage "consul" {
  path = "openbao"
  address = "HOST_IP:8500"
}
```

The chart default is inherited from the Vault chart. OpenBao 2.x does **not**
ship a Consul storage backend. The OpenBao 2.6 documentation lists only
Filesystem, In-Memory, Integrated Storage (Raft) and PostgreSQL. With the
default config the server fails to start with an unknown storage type.

`docs/installation.md` and `docs/architecture.md` still describe "HA with
Consul". Treat that mode as **unsupported** and override `server.ha.config`.

### 5.3 Values: HA with PostgreSQL

Create the connection Secret:

```bash
kubectl -n openbao create secret generic openbao-pg \
  --from-literal=url='postgres://openbao:<password>@pg.example.com:5432/openbao?sslmode=verify-full'
```

```yaml
global:
  tlsDisable: false

server:
  dev_mode:
    enabled: false
  ha:
    enabled: true
    replicas: 2
    raft:
      enabled: false
    config: |
      ui = true

      listener "tcp" {
        address = "[::]:8200"
        cluster_address = "[::]:8201"
        tls_cert_file = "{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.certKey }}"
        tls_key_file  = "{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.keyKey }}"
        tls_min_version = "{{ .Values.server.tls.tlsMinVersion }}"
      }

      storage "postgresql" {
        ha_enabled          = "true"
        max_connect_retries = 0
      }

      service_registration "kubernetes" {}
    disruptionBudget:
      enabled: true
      maxUnavailable: 1

  extraSecretEnvironmentVars:
    - envName: BAO_PG_CONNECTION_URL
      secretName: openbao-pg
      secretKey: url

  tls:
    source: certManager
    certManager:
      clusterIssuerName: corp-ca
```

Points to note:

- `connection_url` is not in the config. OpenBao reads it from
  `BAO_PG_CONNECTION_URL`, so the password stays out of the ConfigMap.
- `max_connect_retries = 0` retries forever while the database is
  unavailable. The default (`1`) makes the server exit almost immediately.
- OpenBao creates the tables `openbao_kv_store` and `openbao_ha_locks` on
  first start unless `skip_create_table = "true"`. The database user then
  needs the `CREATE` privilege.
- For 2 replicas the computed `maxUnavailable` is `0`, which would block node
  drains. Set `maxUnavailable: 1` explicitly as above. With external storage
  there is no quorum among the OpenBao pods, so one standby is enough.
- The default `server.affinity` still places each replica on a separate
  node.

### 5.4 Rendered objects

As for [HA with Raft](#43-rendered-objects), but **without data PVCs**
(`audit` PVCs are still created if enabled).

### 5.5 First start

Initialize once; all servers share the storage:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao operator init -key-shares=5 -key-threshold=3 -format=json > openbao-init.json
```

Unseal **each** pod with the threshold of keys. There is no `raft join` step.
With `OrderedReady`, `openbao-1` is created after `openbao-0` is Ready.

### 5.6 Operations

| Task | How |
|------|-----|
| Restart or upgrade | As for Raft: followers first, `bao operator step-down` on the leader |
| Scale | Change `server.ha.replicas`. New pods only need to be unsealed |
| Back up | Database backups (`pg_dump`, PITR). The Raft snapshot agent does not work |
| Restore | Restore the database while all OpenBao pods are stopped (`kubectl scale sts openbao --replicas=0`) |

### 5.7 Limitations

- Availability depends on the database. A database outage stops OpenBao.
- One more system to secure, monitor and back up.
- Not covered by the shipped profiles or examples.

---

## 6. External mode

### 6.1 Purpose

No OpenBao server is deployed. The release provides supporting objects for
an OpenBao server that runs elsewhere: another namespace or cluster, a VM or
a managed service.

Use it to:

- give an external server a reviewer ServiceAccount and the auth-delegator
  binding for the Kubernetes auth method;
- run the snapshot agent against an external Raft cluster.

### 6.2 Values

```yaml
global:
  externalBaoAddr: https://openbao.example.com:8200

server:
  serviceAccount:
    create: true
    createSecret: true
  authDelegator:
    enabled: true
```

Snapshot agent against an external cluster:

```yaml
global:
  externalBaoAddr: https://openbao.example.com:8200

snapshotAgent:
  enabled: true
  schedule: "0 */6 * * *"
  s3CredentialsSecret: openbao-snapshot-s3
  config:
    s3Bucket: openbao-snapshots
    s3Uri: s3://openbao-snapshots
    baoAuthPath: kubernetes-prod
    baoRole: snapshot
  extraEnvironmentVars:
    BAO_CACERT: /openbao/userconfig/ca/ca.crt
  extraVolumes:
    - name: ca
      configMap:
        name: external-openbao-ca
  extraVolumeMounts:
    - name: ca
      mountPath: /openbao/userconfig/ca
      readOnly: true
```

With `global.tlsDisable: false`, the snapshot agent mounts the chart's TLS
Secret `<fullname>-tls`. No template creates that Secret in external mode,
so the CronJob pods fail to start. Keep `global.tlsDisable: true` in
external mode and provide the CA through `extraVolumes`, as above.

### 6.3 Rendered objects

| Object | Rendered |
|--------|----------|
| StatefulSet, ConfigMap, Services, PDB, discovery RBAC, Ingress, Route, Gateway, TLS objects | No |
| ServiceAccount, token Secret, auth-delegator binding | Yes, when enabled and `server.enabled` or `global.enabled` is true |
| Snapshot agent CronJob, ConfigMap, ServiceAccount | Yes, if enabled. `BAO_ADDR` is the external address |
| ServiceMonitor | Yes, if enabled, but it finds no Services. Disable it |
| NetworkPolicy | Yes, if enabled. It selects no server pods |

### 6.4 Setup

See [03-global-and-identity.md §6](03-global-and-identity.md#6-globalexternalbaoaddr)
for the Kubernetes auth configuration on the external server.

### 6.5 Limitations

- The deprecated `global.externalVaultAddr` still works, but
  `global.externalBaoAddr` takes precedence.
- Do not switch a release that runs a server to external mode while you
  still need its data. The StatefulSet is deleted. The PVCs remain (see
  [05-storage.md §4](05-storage.md#4-pvc-retention-policy)), but nothing
  mounts them.

---

## 7. Mode comparison

| | Dev | Standalone | HA + Raft | HA + PostgreSQL | External |
|---|---|---|---|---|---|
| Pods | 1 | 1 | 3 or 5 | 2 or more | 0 |
| Storage | single-node Raft, PVC | single-node Raft, PVC | Raft, PVC per pod | PostgreSQL | external |
| Survives a pod restart | yes, auto-unseal | data yes; sealed until unsealed | yes; other nodes keep serving | yes; other nodes keep serving | n/a |
| Survives a node failure | after rescheduling (if the volume can move) | after rescheduling, sealed | yes, with 1 (3 nodes) or 2 (5 nodes) failures | yes, as long as the database is up | n/a |
| Unseal | automatic, key on the PVC | manual or auto-unseal | manual on every pod, or auto-unseal | manual on every pod, or auto-unseal | n/a |
| Backups | Raft snapshots | Raft snapshots, snapshot agent | Raft snapshots, snapshot agent | database backups | external |
| Grow to HA | via standalone | in place ([§8.2](#82-standalone-to-ha-with-raft)) | scale `replicas` | scale `replicas` | n/a |
| Active/standby Services | no | no | yes | yes | no |
| PDB | no | no | yes | yes | no |
| Minimum nodes (default affinity) | 1 | 1 | 3 | 2 | 0 |
| Shipped profile | `dev.yaml` | `small.yaml`, `large.yaml` | `medium.yaml`, `prod.yaml` | — | — |
| Shipped example | `examples/dev.yaml` | `examples/standalone.yaml` | `examples/ha-raft.yaml` | `examples/ha-postgresql.yaml` | `examples/external.yaml` |
| Production | no | limited | **recommended** | yes | n/a |

---

## 8. Migrating between modes

| From → To | Method | Downtime |
|-----------|--------|----------|
| Dev → Standalone | Change values; same Raft data on the same PVC | One restart |
| Standalone → HA + Raft | In place: switch values, new pods join the existing one-node cluster | One restart of `openbao-0` |
| Standalone (old `file` backend) → Standalone (Raft) | `bao operator migrate` (file → raft), offline, once | Yes, for the migration |
| HA + Raft → Standalone | Remove peers down to one voter, switch values | One restart |
| HA + Raft → HA + Raft (new cluster) | Raft snapshot and `restore -force` | Yes, for the cut-over |
| HA + Raft → HA + PostgreSQL | `bao operator migrate` (raft → postgresql), offline | Yes |
| Any → External | Move the data to the external server first, then change values | Yes |

Always take a snapshot (or a copy of the data) and keep the unseal keys
before a migration.

### 8.1 Dev to standalone

Both modes use single-node Raft and the PVC stays `data-<fullname>-0`, so
the data is reused.

1. Save the bootstrap keys and remove them from the volume. See
   [05-storage.md §7](05-storage.md#7-dev-mode-files-on-the-data-volume).
2. Upgrade:

   ```bash
   helm upgrade openbao ./charts/openbao -n openbao -f values.yaml \
     --set server.dev_mode.enabled=false \
     --set server.standalone.enabled=true
   kubectl -n openbao delete pod openbao-0
   ```

3. Unseal with the saved key, then rekey and revoke the root token:

   ```bash
   kubectl -n openbao exec openbao-0 -- bao operator unseal <key>
   kubectl -n openbao exec -it openbao-0 -- bao operator rekey -init -key-shares=5 -key-threshold=3
   ```

### 8.2 Standalone to HA with Raft

Because standalone already is a one-node Raft cluster with node ID
`openbao-0` and cluster address `https://openbao-0.openbao-internal:8201`,
moving to HA needs **no data migration**. `openbao-0` keeps its data and
stays the leader; the new pods start empty and join it through `retry_join`.

```mermaid
sequenceDiagram
    participant Op as Operator
    participant P0 as openbao-0 (data)
    participant P1 as openbao-1 (new)
    participant P2 as openbao-2 (new)
    Op->>P0: raft snapshot save (backup)
    Op->>P0: helm upgrade (ha.enabled, raft.enabled, setNodeId)
    Op->>P0: delete pod, unseal
    Note over P0: leader of a 1-node cluster
    P1->>P0: retry_join
    Op->>P1: unseal
    P2->>P0: retry_join
    Op->>P2: unseal
    Note over P0,P2: 3 voters, quorum 2
```

**1. Back up** with a snapshot (the server keeps running):

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot save /tmp/pre-ha.snap
kubectl -n openbao cp openbao-0:/tmp/pre-ha.snap ./pre-ha.snap
```

**2. Check the prerequisites** for HA: at least 3 schedulable nodes (default
required anti-affinity), and, with TLS, a certificate whose SANs cover the
`-internal` names (always included by the chart) and that the joining pods
can verify (`leader_ca_cert_file`).

**3. Upgrade to HA with Raft.** `raft.setNodeId: true` is required: it keeps
the node ID `openbao-0` that standalone used. Without it `openbao-0` would
start with a new random ID that is not in its stored Raft configuration and
would not become leader. `standalone.enabled` can stay
as it is; `ha.enabled: true` takes precedence.

```yaml
# ha-values.yaml (merge with your standalone values, or use examples/ha-raft.yaml)
server:
  dev_mode:
    enabled: false
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true       # required: keeps node ID openbao-0
```

```bash
helm upgrade openbao ./charts/openbao -n openbao -f values.yaml -f ha-values.yaml
# or simply: -f examples/ha-raft.yaml
```

The StatefulSet selector, `serviceName` and `volumeClaimTemplates` are the
same in both modes, so the upgrade is accepted. The PDB, the active and
standby Services and the discovery RBAC are added, and `replicas` becomes 3.

If you overrode `server.standalone.config` with settings you need
(seal, telemetry, `performance_multiplier`), copy them into
`server.ha.raft.config`. The Raft `path` must stay the same.

**4. Restart and unseal `openbao-0`** so it picks up the new config
(`OnDelete` strategy):

```bash
kubectl -n openbao delete pod openbao-0
kubectl -n openbao exec openbao-0 -- bao operator unseal <share-1>   # ... threshold times
```

**5. Unseal the new pods** after they have joined, as in
[§4.5](#45-first-start) steps 3 and 4, or with the script, which skips the
already initialized `openbao-0`:

```bash
examples/scripts/init-unseal.sh -n openbao -r openbao -p 3 -k ./openbao-init.json
```

**6. Verify:**

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers
kubectl -n openbao exec openbao-0 -- bao operator raft autopilot state
kubectl -n openbao get pods -l component=server -L openbao-active
```

Rollback before step 5: scale back with `helm upgrade` to the standalone
values. Once other peers have joined, first remove them
(`bao operator raft remove-peer openbao-2`, `... openbao-1`) so the single
remaining node keeps its quorum, then switch the values (§8.2.1).

#### 8.2.1 HA with Raft back to standalone

1. Make `openbao-0` the leader (`bao operator step-down` on the current
   leader until `openbao-0` is active).
2. Remove the other peers **before** deleting their pods:

   ```bash
   kubectl -n openbao exec openbao-0 -- bao operator raft remove-peer openbao-2
   kubectl -n openbao exec openbao-0 -- bao operator raft remove-peer openbao-1
   kubectl -n openbao exec openbao-0 -- bao operator raft list-peers   # only openbao-0
   ```

3. Switch to the standalone values (`ha.enabled: false`) and
   `helm upgrade`. The StatefulSet scales to 1.
4. Delete `data-openbao-1` and `data-openbao-2`, otherwise the old data
   rejoins under the old node IDs if you scale up again.
5. Delete `openbao-0` so it loads the standalone config (no `retry_join`, no
   `service_registration`), then unseal.

### 8.3 Raft cluster to a new Raft cluster

Use this to move to a new namespace, cluster or release name.

```bash
# Old cluster
kubectl -n old exec openbao-0 -- bao operator raft snapshot save /tmp/raft.snap
kubectl -n old cp openbao-0:/tmp/raft.snap ./raft.snap

# New cluster: install, init (temporary keys), unseal openbao-0 only
kubectl -n new cp ./raft.snap openbao-0:/tmp/raft.snap
kubectl -n new exec openbao-0 -- bao login <temporary-root-token>
kubectl -n new exec openbao-0 -- bao operator raft snapshot restore -force /tmp/raft.snap
```

After the restore the new cluster uses the **old** unseal keys or KMS key.
Unseal the other nodes with the old keys. Point clients to the new address,
then remove the old cluster.

### 8.4 Raft to PostgreSQL

Stop all pods, then run `bao operator migrate` in a temporary pod that mounts
`data-openbao-0`, as in [§8.5](#85-migrating-a-file-backed-standalone-to-raft),
with:

```hcl
storage_source "raft" {
  path    = "/openbao/data"
  node_id = "openbao-0"
}
storage_destination "postgresql" {
  connection_url = "postgres://openbao:<password>@pg.example.com:5432/openbao?sslmode=verify-full"
}
cluster_addr = "https://openbao-0.openbao-internal:8201"
```

Migrate from the volume of the last leader. Then upgrade the release to the
[PostgreSQL values](#53-values-ha-with-postgresql). Changing from Raft to
external storage removes the data PVCs from the StatefulSet template, and
`volumeClaimTemplates` cannot change. Delete the StatefulSet with
`--cascade=orphan` before `helm upgrade` (the pods are already stopped).

### 8.5 Migrating a file-backed standalone to Raft

Chart versions before the Raft-based standalone stored standalone and dev
data with the `file` backend directly in `/openbao/data` (`core/`,
`logical/`, `sys/`). After the upgrade the container refuses to start and
logs the `legacy 'file' storage backend` error from [§3.4](#34-server-configuration).
Migrate once, offline. `bao operator migrate` copies the encrypted entries
without decrypting them, so the unseal keys and the root token stay the same.

```mermaid
flowchart LR
  a[Old pod<br/>file backend] -->|1. tar backup| b[(backup.tgz)]
  a -->|2. scale to 0| c[Migration pod]
  c -->|3. file → raft<br/>into /openbao/data/raft-migrated| d[(data-openbao-0)]
  d -->|4. move file data away,<br/>promote raft files| e[New pod<br/>single-node Raft]
```

**1. Back up** the volume while the old pod still runs the old chart
version:

```bash
kubectl -n openbao exec openbao-0 -- tar czf /tmp/file-backup.tgz -C /openbao/data .
kubectl -n openbao cp openbao-0:/tmp/file-backup.tgz ./file-backup.tgz
```

If you already upgraded and the pod is in `CrashLoopBackOff`, take the
backup from the migration pod in step 3 instead (add a `tar` before
`bao operator migrate`).

**2. Stop the server:**

```bash
kubectl -n openbao scale statefulset openbao --replicas=0
kubectl -n openbao wait --for=delete pod/openbao-0 --timeout=120s
```

**3. Run the migration** in a temporary pod that mounts the data volume.
Raft is written to a temporary sub-directory first, then moved to the root
of the volume, where the new default config expects it:

```yaml
# migrate-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: openbao-migrate
  namespace: openbao
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 1000
    fsGroup: 1000
  containers:
    - name: migrate
      image: quay.io/openbao/openbao:2.6.2     # same version as the server
      command: ["/bin/sh", "-ec"]
      args:
        - |
          D=/openbao/data
          test -d "$D/core"           || { echo "no file backend data in $D"; exit 1; }
          test ! -e "$D/vault.db"     || { echo "$D already contains Raft data"; exit 1; }
          mkdir -p "$D/raft-migrated"
          cat > /tmp/migrate.hcl <<'EOF'
          storage_source "file" {
            path = "/openbao/data"
          }
          storage_destination "raft" {
            path    = "/openbao/data/raft-migrated"
            node_id = "openbao-0"
          }
          cluster_addr = "https://openbao-0.openbao-internal:8201"
          EOF
          bao operator migrate -config /tmp/migrate.hcl
          # Keep the old file data on the volume until the new server is verified.
          mkdir -p "$D/file-backend-legacy"
          for x in core logical sys; do
            [ -e "$D/$x" ] && mv "$D/$x" "$D/file-backend-legacy/"
          done
          # Promote the Raft files to the configured path.
          mv "$D/raft-migrated/vault.db" "$D/vault.db"
          mv "$D/raft-migrated/raft"     "$D/raft"
          rmdir "$D/raft-migrated" 2>/dev/null || true
          ls -la "$D"
      volumeMounts:
        - name: data
          mountPath: /openbao/data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-openbao-0
```

```bash
kubectl apply -f migrate-pod.yaml
kubectl -n openbao logs -f openbao-migrate
kubectl -n openbao delete pod openbao-migrate
```

`node_id` must be `openbao-0`, the pod name, because standalone sets
`BAO_RAFT_NODE_ID` to it. For another release name use `<fullname>-0` in
`node_id` and `cluster_addr`. On OpenShift drop the `securityContext` IDs
and let the SCC assign them.

**4. Start the server** with the new chart version and unseal it with the
existing keys:

```bash
helm upgrade openbao ./charts/openbao -n openbao -f values.yaml
kubectl -n openbao scale statefulset openbao --replicas=1   # if helm did not restore it
kubectl -n openbao exec openbao-0 -- bao operator unseal <share-1>   # ... threshold times
kubectl -n openbao exec openbao-0 -- bao status          # Storage Type: raft
```

**5. Verify** that the old data is there (`bao secrets list`, read a known
secret, `bao operator raft list-peers`), take a first snapshot, then remove
`/openbao/data/file-backend-legacy`.

If you intentionally want to discard the old data and start fresh, set
`server.standalone.legacyFileDataCheck: false` (or delete the PVC) instead.
