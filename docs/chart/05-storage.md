# Persistent Storage

This document covers the data and audit volumes, their lifecycle, resizing
and file ownership. The PVCs are created by the `openbao.volumeclaims` helper
([`_helpers.tpl:323`](/charts/openbao/templates/_helpers.tpl)) as StatefulSet
`volumeClaimTemplates`.

- [1. Storage by mode](#1-storage-by-mode)
- [2. Data storage](#2-data-storage)
- [3. Audit storage](#3-audit-storage)
- [4. PVC retention policy](#4-pvc-retention-policy)
- [5. Resizing volumes](#5-resizing-volumes)
- [6. File ownership and permissions](#6-file-ownership-and-permissions)
- [7. Dev-mode files on the data volume](#7-dev-mode-files-on-the-data-volume)

> Examples in this document have not yet been checked with `helm template`.

---

## 1. Storage by mode

| Resolved mode | `data` PVC | `audit` PVC | Where the secrets live |
|---------------|-----------|-------------|------------------------|
| `standalone` (including dev mode) | Always | If `server.auditStorage.enabled` | Single-node integrated Raft on the data PVC (`vault.db`, `raft/`) |
| `ha` with `raft.enabled: true` | Always, one per replica | If enabled, one per replica | Integrated Raft on each replica's data PVC |
| `ha` with `raft.enabled: false` (external storage) | **None** | If enabled | External database (PostgreSQL). The default Consul config is not supported by OpenBao 2.x |
| `external` | None | None | External server |

PVC names follow the StatefulSet pattern `<volume>-<fullname>-<ordinal>`, for
example `data-openbao-0` and `audit-openbao-2`.

---

## 2. Data storage

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.dataStorage.size` | string | `10Gi` | `resources.requests.storage` |
| `server.dataStorage.mountPath` | string | `/openbao/data` | Mount path in the container |
| `server.dataStorage.storageClass` | string or null | `null` | `storageClassName`. `null` uses the cluster default |
| `server.dataStorage.accessMode` | string | `ReadWriteOnce` | `accessModes[0]` |
| `server.dataStorage.annotations` | map or string (tpl) | `{}` | PVC annotations |
| `server.dataStorage.labels` | map or string (tpl) | `{}` | PVC labels |

### Why there is no `enabled` switch

Upstream allows `dataStorage.enabled: false`. This distribution removes that
switch. For integrated Raft storage the data would otherwise be
written to the container's writable layer:

- every restart would lose all secrets;
- in HA with Raft, a restarted node would rejoin with no data and drop out
  of quorum.

### Pitfall: `mountPath` and the HCL path

`mountPath` changes the **mount**. The default `standalone.config` uses
`path = "{{ .Values.server.dataStorage.mountPath }}"` and follows it
automatically. The default `ha.raft.config` still hard-codes
`path = "/openbao/data"`; if you change `mountPath` in HA, change the HCL too,
or reference the value. The same applies to a custom `standalone.config`:

```yaml
server:
  dataStorage:
    mountPath: /vault/data
  standalone:
    config: |
      ui = true
      listener "tcp" {
        address     = "[::]:8200"
        tls_disable = 1
      }
      storage "raft" {
        path = "{{ .Values.server.dataStorage.mountPath }}"
      }
```

The dev-mode bootstrap script and the standalone legacy-data guard also use
`mountPath` (for `bootstrap-keys.json` and the `core/` / `vault.db` check).

### Legacy `file` data on the volume

Older chart versions ran standalone and dev mode on the `file` backend. Its
data (`core/`, `logical/`, `sys/`) cannot be read by Raft. When the container
finds `<mountPath>/core` but no `<mountPath>/vault.db`, it exits before
starting `bao server` instead of presenting an empty, uninitialized server.

| Situation | Action |
|-----------|--------|
| The data must be kept | Migrate once with `bao operator migrate`: [09-deployment-modes.md §8.5](09-deployment-modes.md#85-migrating-a-file-backed-standalone-to-raft) |
| The data can be discarded | Delete the PVC, or set `server.standalone.legacyFileDataCheck: false` |
| You run a custom `standalone.config` with `storage "file"` on purpose | The guard only applies to configs with `storage "raft"`; nothing to do |

### Access mode

OpenBao needs exclusive access to its data directory. Keep
`ReadWriteOnce`, or use `ReadWriteOncePod` on CSI drivers that support it.
`ReadWriteMany` gives no benefit, and with NFS it can corrupt Raft data
(BoltDB needs reliable file locking and `fsync`).

### Examples

Fast storage class:

```yaml
server:
  dataStorage:
    size: 20Gi
    storageClass: premium-ssd
```

Backup tool annotations and cost labels:

```yaml
server:
  dataStorage:
    annotations:
      backup.velero.io/backup-volumes: data
    labels:
      cost-center: security
```

### Sizing

| Workload | Suggested data size |
|----------|---------------------|
| Dev or test | 1 to 5Gi |
| Typical production (KV, PKI, dynamic credentials) | 10 to 20Gi |
| Heavy PKI (many stored certificates) or many leases | 50Gi or more |

Raft keeps a BoltDB file plus snapshots, so plan for about twice the live
data size. Monitor usage with `kubelet_volume_stats_used_bytes`.

---

## 3. Audit storage

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.auditStorage.enabled` | bool | `false` | Creates the `audit` PVC and mounts it |
| `server.auditStorage.size` | string | `10Gi` | PVC size |
| `server.auditStorage.mountPath` | string | `/openbao/audit` | Mount path |
| `server.auditStorage.storageClass` | string or null | `null` | StorageClass |
| `server.auditStorage.accessMode` | string | `ReadWriteOnce` | Access mode |
| `server.auditStorage.annotations` | map or string (tpl) | `{}` | PVC annotations |
| `server.auditStorage.labels` | map or string (tpl) | `{}` | PVC labels |

The chart only provides the volume. Audit logging is turned on inside
OpenBao after initialization and unseal:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao audit enable file file_path=/openbao/audit/audit.log
```

In HA, run this once. The audit configuration is replicated, and every
replica writes to its own `audit` PVC.

> **OpenBao blocks requests when no audit device can write.** If the audit
> volume fills up and it is the only audit device, every API request fails.
> Rotate and ship the logs, or add a second device (for example
> `bao audit enable -path=stdout file file_path=stdout`).

### Example: ship audit logs with a sidecar

```yaml
server:
  auditStorage:
    enabled: true
    size: 20Gi
  extraContainers:
    - name: audit-shipper
      image: registry.example.com/fluent-bit:3.1
      args: ["-i", "tail", "-p", "path=/openbao/audit/*.log", "-o", "stdout"]
      volumeMounts:
        - name: audit
          mountPath: /openbao/audit
          readOnly: true
```

To rotate the file, a sidecar moves it and sends `SIGHUP` to `bao`, which
reopens the file. This needs `server.shareProcessNamespace: true`. See
[04-server-workload.md §11](04-server-workload.md#11-init-containers-and-sidecars).

---

## 4. PVC retention policy

| Key | Type | Default |
|-----|------|---------|
| `server.persistentVolumeClaimRetentionPolicy` | map | `{}` (Kubernetes default: `Retain` / `Retain`) |

The value becomes `spec.persistentVolumeClaimRetentionPolicy` on the
StatefulSet.

| Field | `Retain` | `Delete` |
|-------|----------|----------|
| `whenDeleted` | PVCs stay after the StatefulSet is deleted (`helm uninstall`) | PVCs are deleted together with the StatefulSet |
| `whenScaled` | PVCs of removed replicas stay | PVCs of removed replicas are deleted |

| Environment | Recommended |
|-------------|-------------|
| Production | `whenDeleted: Retain`, `whenScaled: Retain` (or leave empty) |
| Short-lived CI or preview environments | `whenDeleted: Delete`, `whenScaled: Delete` |

```yaml
server:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Retain
```

When you scale an HA Raft cluster down, first remove the peer with
`bao operator raft remove-peer <node-id>`. If you keep the PVC and scale up
again, the old data rejoins under the old node ID.

---

## 5. Resizing volumes

`volumeClaimTemplates` of a StatefulSet are **immutable**. Changing
`server.dataStorage.size` and running `helm upgrade` fails with
`spec: Forbidden: updates to statefulset spec for fields other than ...`.

Procedure:

1. Check that the StorageClass allows expansion:

   ```bash
   kubectl get storageclass <name> -o jsonpath='{.allowVolumeExpansion}'
   ```

2. Expand each PVC:

   ```bash
   for i in 0 1 2; do
     kubectl -n openbao patch pvc data-openbao-$i \
       -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
   done
   ```

   PowerShell:

   ```powershell
   0..2 | ForEach-Object {
     kubectl -n openbao patch pvc "data-openbao-$_" `
       -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"20Gi\"}}}}'
   }
   ```

3. Delete the StatefulSet object but keep the pods running:

   ```bash
   kubectl -n openbao delete statefulset openbao --cascade=orphan
   ```

4. Upgrade with the new size, so the template matches the PVCs:

   ```bash
   helm upgrade openbao ./charts/openbao -n openbao -f values.yaml \
     --set server.dataStorage.size=20Gi
   ```

5. Some drivers grow the file system only when the volume is remounted.
   Restart the pods one at a time (HA: standbys first) and check:

   ```bash
   kubectl -n openbao exec openbao-0 -- df -h /openbao/data
   ```

The same steps apply to the `audit` PVC and to `storageClass` changes.
Changing the class also needs a data migration, because an existing PVC
cannot switch class. For Raft, use a snapshot and restore.

---

## 6. File ownership and permissions

| Setting | Kubernetes default | OpenShift |
|---------|--------------------|-----------|
| `runAsUser` | `100` (`server.uid`) | assigned by the SCC |
| `runAsGroup`, `fsGroup` | `1000` (`server.gid`) | assigned by the SCC |
| `SKIP_CHOWN` env | `true` | `true` |

`fsGroup` makes the kubelet set the group of the volume, so the
`openbao` user can write to it. `SKIP_CHOWN=true` stops the image entrypoint
from running `chown` itself, because that fails without root.

`server.uid` and `server.gid` are read by the helper but are not declared in
`values.yaml`.

### Troubleshooting `permission denied`

| Symptom | Cause | Fix |
|---------|-------|-----|
| `open /openbao/data/...: permission denied` | Your custom `securityContext.pod` has no `fsGroup` | Add `fsGroup: 1000` |
| Same, on hostPath or some NFS drivers | The driver ignores `fsGroup` | Use an init container that runs `chown -R 100:1000 /openbao/data` as root, or a driver with `fsGroupPolicy: File` |
| Slow pod start on a large volume | The kubelet changes ownership recursively on each mount | Set `fsGroupChangePolicy: OnRootMismatch` |

```yaml
server:
  statefulSet:
    securityContext:
      pod:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
```

A custom `securityContext.pod` replaces the defaults completely. Repeat all
the fields you need.

---

## 7. Dev-mode files on the data volume

In dev mode the bootstrap script writes `bootstrap-keys.json` to
`<server.dataStorage.mountPath>`. The file contains the only unseal key and
the root token, in plain text, next to the encrypted data:

- anyone with `pods/exec` or access to the volume can read every secret;
- volume backups (for example with Velero) contain both the data and the key
  that decrypts it.

If a dev instance holds data you want to keep before moving to standalone:

1. Copy the keys out and store them safely:

   ```bash
   kubectl -n openbao cp openbao-0:/openbao/data/bootstrap-keys.json ./bootstrap-keys.json
   ```

2. Remove the file from the volume:

   ```bash
   kubectl -n openbao exec openbao-0 -- rm /openbao/data/bootstrap-keys.json
   ```

3. Upgrade with `server.dev_mode.enabled: false` and delete the pod so it
   picks up the new template (`OnDelete` strategy). From then on you unseal
   with the saved key. Rekey with more shares:

   ```bash
   bao operator rekey -init -key-shares=5 -key-threshold=3
   ```

4. Revoke the root token once you have created a proper admin identity:

   ```bash
   bao token revoke <root-token>
   ```

Dev and standalone both use single-node Raft storage at the same path, so
the data on the PVC is reused.
