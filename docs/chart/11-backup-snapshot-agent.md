# Backups with the Snapshot Agent

This document describes the optional snapshot agent: a Kubernetes CronJob
that takes Raft snapshots of OpenBao on a schedule and uploads them to
S3-compatible storage. It also covers the OpenBao-side setup and how to
restore.

- [1. How it works](#1-how-it-works)
- [2. Requirements](#2-requirements)
- [3. Parameters](#3-parameters)
- [4. Rendered objects](#4-rendered-objects)
- [5. Step-by-step setup](#5-step-by-step-setup)
- [6. Examples](#6-examples)
- [7. Restoring a snapshot](#7-restoring-a-snapshot)
- [8. Operations](#8-operations)
- [9. Troubleshooting](#9-troubleshooting)

> Examples in this document have not yet been checked with `helm template`
> or on a live cluster. The agent image is
> [`openbao/openbao-snapshot-agent`](https://github.com/openbao/openbao-snapshot-agent);
> check its documentation for the version you deploy.

---

## 1. How it works

```mermaid
sequenceDiagram
    participant CJ as CronJob pod<br/>(&lt;fullname&gt;-snapshot SA)
    participant OB as OpenBao<br/>(BAO_ADDR)
    participant S3 as S3 bucket
    CJ->>OB: auth/<BAO_AUTH_PATH>/login role=<BAO_ROLE><br/>jwt = ServiceAccount token
    OB-->>CJ: client token (policy: snapshot)
    CJ->>OB: GET sys/storage/raft/snapshot
    OB-->>CJ: snapshot file
    CJ->>S3: s3cmd put → S3_URI
    CJ->>S3: delete objects older than S3_EXPIRE_DAYS
```

1. The CronJob pod runs as the snapshot ServiceAccount
   (`<fullname>-snapshot` by default).
2. It logs in to OpenBao with the Kubernetes auth method, using its
   projected ServiceAccount token.
3. It downloads a Raft snapshot through `sys/storage/raft/snapshot`.
4. It uploads the file with `s3cmd` and deletes older snapshots.

The snapshot is written to an `emptyDir` (`/bao-snapshots`) and removed with
the pod.

---

## 2. Requirements

| Requirement | Why |
|-------------|-----|
| **Integrated Raft storage**: standalone (single-node Raft, the default), HA with `server.ha.raft.enabled: true`, or an external Raft cluster | `sys/storage/raft/snapshot` exists only for Raft. PostgreSQL and custom `file` configs are not supported |
| Kubernetes auth method enabled and configured in OpenBao | The agent logs in with its ServiceAccount token |
| An OpenBao policy and role for the agent | [§5.2](#52-create-the-policy-and-role) |
| S3-compatible bucket and credentials | Upload target |
| A Secret with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` | Hard-coded key names in the CronJob |
| OpenBao unsealed, with an elected leader | Snapshots are served by the active node |

The CronJob is rendered whenever `snapshotAgent.enabled: true`, in any mode.
The chart does not check that the backend is Raft.

In standalone mode the agent talks to the client Service
(`<fullname>.<namespace>.svc`), which always selects the single leader pod:

```bash
helm upgrade --install openbao ./charts/openbao -n openbao \
  -f examples/standalone.yaml -f examples/overlays/snapshot-s3.yaml
```

---

## 3. Parameters

### 3.1 Job

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `snapshotAgent.enabled` | bool | `false` | Render the CronJob, its ConfigMap and ServiceAccount |
| `snapshotAgent.schedule` | string | `*/15 * * * *` | CronJob schedule (cluster time zone, usually UTC) |
| `snapshotAgent.restartPolicy` | string | `OnFailure` | Pod `restartPolicy`. `OnFailure` or `Never` |
| `snapshotAgent.annotations` | map or string (tpl) | `{}` | Annotations on the CronJob object |
| `snapshotAgent.resources` | map | `{}` | Container resources |
| `snapshotAgent.tolerations` | list or string (tpl) | `[]` | Pod tolerations |
| `snapshotAgent.securityContext.pod` | map or string (tpl) | `{}` | Pod security context. Empty → non-root defaults (Kubernetes) |
| `snapshotAgent.securityContext.container` | map or string (tpl) | `{}` | Container security context. Empty → no privilege escalation, `drop: [ALL]` |
| `snapshotAgent.uid` / `snapshotAgent.gid` | int | *(undeclared; 100 / 1000)* | Used by the default pod security context |

The CronJob has no `concurrencyPolicy`, `successfulJobsHistoryLimit`,
`failedJobsHistoryLimit` or `startingDeadlineSeconds` settings. Kubernetes
defaults apply: concurrent jobs are **allowed**, 3 successful and 1 failed
job are kept.

### 3.2 Image

| Key | Type | Default |
|-----|------|---------|
| `snapshotAgent.image.repository` | string | `ghcr.io/openbao/openbao-snapshot-agent` |
| `snapshotAgent.image.tag` | string | `0.3.0` |

The image reference is `<repository>:<tag>`. There is no `registry` key and
no `pullPolicy` key (`IfNotPresent` is fixed). `global.imagePullSecrets` and
`deployDescriptor` are **not** applied. For a private registry, set
`repository` to the full path and attach the pull secret to the snapshot
ServiceAccount.

### 3.3 ServiceAccount

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `snapshotAgent.serviceAccount.create` | bool | `true` | Create a ServiceAccount |
| `snapshotAgent.serviceAccount.name` | string | `""` | Name. Empty → `<fullname>-snapshot` (or `default` when `create: false`) |
| `snapshotAgent.serviceAccount.annotations` | map or string (tpl) | `{}` | Annotations (for example IRSA) |
| `snapshotAgent.serviceAccount.extraLabels` | map | `{}` | Labels |

The ServiceAccount name and namespace must match the OpenBao role's
`bound_service_account_names` and `bound_service_account_namespaces`.

### 3.4 Agent configuration

These values are rendered into ConfigMap `<fullname>-snapshot` and loaded
into the container with `envFrom`.

| Key | Env variable | Default | Meaning |
|-----|--------------|---------|---------|
| `snapshotAgent.config.s3Host` | `S3_HOST` | `s3.eu-east-1.amazonaws.com` | S3 endpoint host (and port) |
| `snapshotAgent.config.s3Bucket` | `S3_BUCKET` | `openbao-snapshots` | Bucket name |
| `snapshotAgent.config.s3Uri` | `S3_URI` | `s3://openbao-snapshots` | Upload URI. Can contain a prefix: `s3://bucket/prod/` |
| `snapshotAgent.config.s3ExpireDays` | `S3_EXPIRE_DAYS` | `"14"` | Delete snapshots older than this |
| `snapshotAgent.config.s3cmdExtraFlag` | `S3CMD_EXTRA_FLAG` | `-v` | Extra `s3cmd` flags. Omitted when empty |
| `snapshotAgent.config.baoAuthPath` | `BAO_AUTH_PATH` | `kubernetes` | Kubernetes auth mount path |
| `snapshotAgent.config.baoRole` | `BAO_ROLE` | `snapshot` | Kubernetes auth role |
| *(computed)* | `BAO_ADDR` | see below | OpenBao address |
| *(computed, TLS on)* | `BAO_CACERT` | `<server.tls.mountPath>/<caKey>` | CA used to verify OpenBao |

`s3Host` defaults to `s3.eu-east-1.amazonaws.com`. AWS has no `eu-east-1`
region. Always set it, for example `s3.eu-central-1.amazonaws.com`.

`BAO_ADDR` is computed:

| Condition | `BAO_ADDR` |
|-----------|------------|
| `global.externalBaoAddr` (or `externalVaultAddr`) set | that address |
| HA mode and `server.service.active.enabled` | `<scheme>://<fullname>-active.<ns>.svc:<port>` |
| otherwise | `<scheme>://<fullname>.<ns>.svc:<port>` |

There is no `baoAddr` value. Setting `snapshotAgent.config.baoAddr` has no
effect (the acceptance test `test/acceptance/snapshot.bats` sets it, but the
template ignores it). To override the address, use
`snapshotAgent.extraEnvironmentVars.BAO_ADDR`; `env` entries take precedence
over `envFrom`.

The agent also understands `BAO_NAMESPACE`, `BAO_AUTH_NAMESPACE`,
`BAO_SECRET_PATH` (read S3 credentials from OpenBao instead of a Secret) and
`TOKEN_PATH`. The chart does not expose them; set them with
`extraEnvironmentVars`.

### 3.5 S3 credentials

| Key | Type | Default |
|-----|------|---------|
| `snapshotAgent.s3CredentialsSecret` | string | `my-s3-credentials` |

The Secret must contain exactly the keys `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`. The CronJob always references them. Without the
Secret, the pod stays in `CreateContainerConfigError`.

### 3.6 Extra environment and volumes

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `snapshotAgent.extraEnvironmentVars` | map | `{}` | Extra `env`. Keys are upper-cased and `.` becomes `_` |
| `snapshotAgent.extraSecretEnvironmentVars` | list of `{envName, secretName, secretKey}` | `[]` | Extra `env` from Secrets |
| `snapshotAgent.extraVolumes` | list | `[]` | Pod volumes (raw YAML) |
| `snapshotAgent.extraVolumeMounts` | list | `[]` | Container mounts (raw YAML) |

When `global.tlsDisable: false`, the chart already mounts the server TLS
Secret at `server.tls.mountPath` in the agent and sets `BAO_CACERT`. Do not
add the same mount again with `extraVolumeMounts`, as the commented example
in `values.yaml` suggests; it duplicates the mount path.

---

## 4. Rendered objects

| Object | Name | Notes |
|--------|------|-------|
| CronJob | `<fullname>-snapshot` | Container `bao-snapshot` |
| ConfigMap | `<fullname>-snapshot` | Agent configuration |
| ServiceAccount | `<fullname>-snapshot` | When `serviceAccount.create: true` |

Job pods carry `app.kubernetes.io/name: <openbao.name>`,
`app.kubernetes.io/instance: <release>`, `component: snapshot-agent`. They
match the chart NetworkPolicy's pod selector, so its rules apply to them
too.

---

## 5. Step-by-step setup

The steps assume HA with Raft, release `openbao` in namespace `openbao`, TLS
off, and a root or admin token.

### 5.1 Enable Kubernetes auth

```bash
kubectl -n openbao exec -it openbao-0 -- sh
bao login
bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"
```

The server uses its own ServiceAccount to call `TokenReview`. This needs
`server.authDelegator.enabled: true` (default).

### 5.2 Create the policy and role

```bash
bao policy write snapshot - <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/snapshot \
  bound_service_account_names=openbao-snapshot \
  bound_service_account_namespaces=openbao \
  policies=snapshot \
  ttl=15m
```

### 5.3 Create the bucket and the credentials Secret

```bash
kubectl -n openbao create secret generic openbao-snapshot-s3 \
  --from-literal=AWS_ACCESS_KEY_ID=<access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret-key>
```

Give the S3 user only `s3:PutObject`, `s3:ListBucket`, `s3:GetObject` and
`s3:DeleteObject` on that bucket.

### 5.4 Enable the agent

```yaml
snapshotAgent:
  enabled: true
  schedule: "0 */6 * * *"
  s3CredentialsSecret: openbao-snapshot-s3
  config:
    s3Host: s3.eu-central-1.amazonaws.com
    s3Bucket: acme-openbao-snapshots
    s3Uri: s3://acme-openbao-snapshots/prod/
    s3ExpireDays: "30"
    s3cmdExtraFlag: ""
    baoAuthPath: kubernetes
    baoRole: snapshot
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { memory: 256Mi }
```

```bash
helm upgrade openbao ./charts/openbao -n openbao -f values.yaml -f snapshot.yaml
```

### 5.5 Test it now

```bash
kubectl -n openbao create job snapshot-test --from=cronjob/openbao-snapshot
kubectl -n openbao wait --for=condition=complete job/snapshot-test --timeout=120s
kubectl -n openbao logs job/snapshot-test
kubectl -n openbao delete job snapshot-test
```

Check the bucket:

```bash
aws s3 ls s3://acme-openbao-snapshots/prod/
```

---

## 6. Examples

### 6.1 MinIO (in-cluster, self-signed)

```yaml
snapshotAgent:
  enabled: true
  s3CredentialsSecret: minio-openbao
  config:
    s3Host: minio.minio.svc:9000
    s3Bucket: openbao
    s3Uri: s3://openbao
    s3cmdExtraFlag: "--no-ssl"          # MinIO over plain HTTP
```

With MinIO over HTTPS and a private CA, use `--ca-certs=<file>` and mount
the CA:

```yaml
snapshotAgent:
  config:
    s3cmdExtraFlag: "--ca-certs=/etc/s3-ca/ca.crt"
  extraVolumes:
    - name: s3-ca
      configMap:
        name: minio-ca
  extraVolumeMounts:
    - name: s3-ca
      mountPath: /etc/s3-ca
      readOnly: true
```

`--no-check-certificate` disables verification and is suitable only for
tests.

### 6.2 TLS on the OpenBao side

```yaml
global:
  tlsDisable: false
snapshotAgent:
  enabled: true
  s3CredentialsSecret: openbao-snapshot-s3
```

The chart mounts the TLS Secret and sets `BAO_CACERT`. `BAO_ADDR` points to
`https://openbao-active.openbao.svc:8200`. The certificate must contain that
name. The chart-generated certificate does.

### 6.3 External OpenBao

See [09-deployment-modes.md §6.2](09-deployment-modes.md#62-values). Keep
`global.tlsDisable: true` in external mode and provide the CA yourself;
otherwise the agent mounts a TLS Secret that does not exist.

### 6.4 Avoid overlapping runs

The CronJob template does not expose `concurrencyPolicy`. A slow upload can
overlap with the next run. Choose a schedule with enough margin, or patch the
CronJob after installation:

```bash
kubectl -n openbao patch cronjob openbao-snapshot \
  -p '{"spec":{"concurrencyPolicy":"Forbid","startingDeadlineSeconds":300}}'
```

`helm upgrade` resets the patch.

---

## 7. Restoring a snapshot

A restore **replaces all data** in the cluster. Practice it in a test
environment.

### 7.1 Download the snapshot

```bash
aws s3 cp s3://acme-openbao-snapshots/prod/<file> ./raft.snap
```

### 7.2 Restore into the same cluster

The cluster is unsealed and has the same keys as when the snapshot was
taken:

```bash
kubectl -n openbao cp ./raft.snap openbao-0:/tmp/raft.snap
kubectl -n openbao exec -it openbao-0 -- bao login
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot restore /tmp/raft.snap
```

Run the command against the leader. The standbys follow.

### 7.3 Restore into a new cluster

1. Install a new HA Raft release (see
   [09-deployment-modes.md §4](09-deployment-modes.md#4-ha-with-integrated-raft)).
2. Initialize **only** `openbao-0` with temporary keys and unseal it. Do not
   join the other pods yet.
3. Restore with `-force`, because the snapshot was taken with different
   keys:

   ```bash
   kubectl -n openbao cp ./raft.snap openbao-0:/tmp/raft.snap
   kubectl -n openbao exec openbao-0 -- bao login <temporary-root-token>
   kubectl -n openbao exec openbao-0 -- bao operator raft snapshot restore -force /tmp/raft.snap
   ```

4. `openbao-0` seals itself. Unseal it with the **original** keys from the
   snapshot (or let auto-unseal use the original KMS key).
5. Let `openbao-1` and `openbao-2` join and unseal them with the original
   keys.

Keep the unseal or recovery keys and the KMS key **with** every backup. A
snapshot without them cannot be decrypted.

---

## 8. Operations

| Task | How |
|------|-----|
| Change the schedule | `snapshotAgent.schedule`, then `helm upgrade` |
| Run a snapshot now | `kubectl create job --from=cronjob/<fullname>-snapshot <name>` |
| Pause backups | `kubectl patch cronjob <fullname>-snapshot -p '{"spec":{"suspend":true}}'` (reset by `helm upgrade`) |
| Check recent runs | `kubectl get jobs -l component=snapshot-agent` and `kubectl logs job/<name>` |
| Alert on failures | `kube_job_status_failed{job_name=~"openbao-snapshot.*"} > 0` from kube-state-metrics |
| Alert on missing backups | `time() - kube_cronjob_status_last_successful_time{cronjob="openbao-snapshot"} > 2 * <interval>` |
| Retention | `s3ExpireDays`, or an S3 lifecycle rule (more reliable: it also works when the agent stops running) |
| Encryption at rest | Snapshots are encrypted by OpenBao's barrier key. Enable bucket encryption as well |
| Off-site copies | Bucket replication to another region or account |

Choosing a schedule: the default `*/15 * * * *` makes 96 snapshots a day.
With `s3ExpireDays: "14"` that is about 1,350 files. Every 1 to 6 hours is
enough for most installations.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod `CreateContainerConfigError` | `s3CredentialsSecret` missing, or keys not named `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Create the Secret with these exact keys |
| Pod `ContainerCreating`, `secret "<fullname>-tls" not found` | TLS on in external mode, or the TLS Secret is not issued yet | See [§6.3](#63-external-openbao) and [07-tls.md](07-tls.md) |
| `ErrImagePull` | Private registry without pull secret | Patch the snapshot ServiceAccount with `imagePullSecrets` |
| Login fails: `permission denied` or `service account name not authorized` | Role bound to a different ServiceAccount or namespace | Match `bound_service_account_names` to `<fullname>-snapshot` |
| Login fails: `invalid role name` | `baoRole` does not exist | Create the role, or set `config.baoRole` |
| Login fails: `no handler for route "auth/kubernetes/login"` | Wrong `baoAuthPath` or method not enabled | Enable the method, set `config.baoAuthPath` |
| Snapshot fails: `unsupported path` | Storage backend is not Raft | Snapshots require Raft |
| Snapshot fails: `503`, `Vault is sealed` | Leader sealed or no leader | Unseal; check `bao operator raft list-peers` |
| `connection refused` to `<fullname>-active` | No active pod (sealed, or `service_registration` missing) | Unseal; check the active Service endpoints |
| `x509` errors to OpenBao | CA missing or SANs missing | Provide `ca.crt`; the certificate must contain `<fullname>-active.<ns>.svc` |
| `s3cmd` `SSL certificate verify failed` | Private CA on the S3 side | `--ca-certs` ([§6.1](#61-minio-in-cluster-self-signed)) |
| Upload works, old files are never deleted | `s3ExpireDays` vs. object timestamps, or the S3 user cannot delete | Grant `s3:DeleteObject`, or use a lifecycle rule |
| Job pods blocked by NetworkPolicy | The policy also selects the snapshot pods and you added egress rules | Allow egress to OpenBao, the Kubernetes API, DNS and S3 |
