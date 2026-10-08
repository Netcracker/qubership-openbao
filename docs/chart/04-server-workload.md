# Server Workload: StatefulSet, Pod and Container

This document describes every value that shapes the OpenBao server pod. The
template is
[`templates/server-statefulset.yaml`](/charts/openbao/templates/server-statefulset.yaml),
and most helpers are in
[`templates/_helpers.tpl`](/charts/openbao/templates/_helpers.tpl).

- [1. Image](#1-image)
- [2. StatefulSet behavior](#2-statefulset-behavior)
- [3. Logging](#3-logging)
- [4. Resources and profiles](#4-resources-and-profiles)
- [5. Readiness probe](#5-readiness-probe)
- [6. Liveness probe](#6-liveness-probe)
- [7. Lifecycle hooks and termination](#7-lifecycle-hooks-and-termination)
- [8. Environment variables](#8-environment-variables)
- [9. Extra arguments and ports](#9-extra-arguments-and-ports)
- [10. Volumes and mounts](#10-volumes-and-mounts)
- [11. Init containers and sidecars](#11-init-containers-and-sidecars)
- [12. Scheduling](#12-scheduling)
- [13. Host settings](#13-host-settings)
- [14. Pod metadata](#14-pod-metadata)

> Examples in this document have not yet been checked with `helm template`.

---

## 1. Image

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.image.registry` | string | `quay.io` | Registry host |
| `server.image.repository` | string | `openbao/openbao` | Repository path **without** the registry |
| `server.image.tag` | string (tpl) | `2.6.2` | Image tag. Rendered with `tpl` |
| `server.image.pullPolicy` | string | `IfNotPresent` | `imagePullPolicy` of the server container |

The reference is `<registry>/<repository>:<tag>`. An injected
`deployDescriptor` overrides it. See
[03-global-and-identity.md §10](03-global-and-identity.md#10-image-resolution-with-deploydescriptor).

### Examples

Internal mirror (air-gapped install):

```yaml
server:
  image:
    registry: registry.internal.example.com
    repository: mirror/openbao/openbao
    tag: "2.6.2"
global:
  imagePullSecrets:
    - mirror-creds
```

Tag from the chart `appVersion`. `tpl` makes this work, but `appVersion` is
`v2.6.2` with a `v` prefix, and the upstream image tags have no prefix:

```yaml
server:
  image:
    tag: '{{ trimPrefix "v" .Chart.AppVersion }}'
```

Use `pullPolicy: Always` with a moving tag such as `latest`.

### Pitfall

`charts/openbao/README.md` says the default tag is `""` and the appVersion is
`v2.5.4`. Older docs say `2.5`. `values.yaml` sets `2.6.2`, and that value
wins.

---

## 2. StatefulSet behavior

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.updateStrategyType` | string | `OnDelete` | `spec.updateStrategy.type` |
| `server.podManagementPolicy` | string | `OrderedReady` | `spec.podManagementPolicy` |
| `server.statefulSet.annotations` | map or string (tpl) | `{}` | Annotations on the StatefulSet object |
| `server.persistentVolumeClaimRetentionPolicy` | map | `{}` | See [05-storage.md §4](05-storage.md#4-pvc-retention-policy) |

The StatefulSet `serviceName` is always `<fullname>-internal`. Replicas are 1
in standalone mode and `server.ha.replicas` in HA mode.

### Update strategy

| Value | Behavior | When to use |
|-------|----------|-------------|
| `OnDelete` (default) | Pods are replaced only when you delete them | Production clusters that are unsealed manually. You decide the order: standbys first, then the leader |
| `RollingUpdate` | Pods are replaced in reverse ordinal order after each `helm upgrade` | Clusters with auto-unseal, where a new pod becomes Ready by itself |

With `OnDelete`:

- `helm upgrade` changes only the template. Running pods are not touched.
- `kubectl rollout status statefulset/<fullname>` does not work.
- To roll the cluster by hand:

  ```bash
  # HA: restart standbys first, then the active pod
  kubectl -n openbao get pods -l component=server -L openbao-active
  kubectl -n openbao delete pod openbao-2
  # unseal openbao-2 if needed, wait for Ready, then repeat for openbao-1
  # finally step the leader down and delete it
  kubectl -n openbao exec openbao-0 -- bao operator step-down
  kubectl -n openbao delete pod openbao-0
  ```

### Pod management policy

| Value | Behavior |
|-------|----------|
| `OrderedReady` (default) | Pod `N+1` is created only when pod `N` is Ready. Without auto-unseal, `-1` waits until you unseal `-0` |
| `Parallel` | All pods start at once. Useful for HA with manual unseal: you can unseal all pods together, and Raft `retry_join` finds the leader |

`podManagementPolicy` is immutable. Changing it on an existing release needs
`kubectl delete sts <fullname> --cascade=orphan` before `helm upgrade`.

### Example

```yaml
server:
  updateStrategyType: RollingUpdate
  podManagementPolicy: Parallel
  statefulSet:
    annotations:
      reloader.stakater.com/auto: "false"
```

---

## 3. Logging

| Key | Type | Default | Rendered as |
|-----|------|---------|-------------|
| `server.logLevel` | string | `""` | `BAO_LOG_LEVEL` (only if non-empty) |
| `server.logFormat` | string | `""` | `BAO_LOG_FORMAT` (only if non-empty) |

| `logLevel` values | `logFormat` values |
|-------------------|--------------------|
| `trace`, `debug`, `info` (OpenBao default), `warn`, `error` | `standard` (OpenBao default), `json` |

```yaml
server:
  logLevel: info
  logFormat: json     # for Loki, Elasticsearch and similar
```

`debug` and `trace` can log request details. Use them only for a short time.

---

## 4. Resources and profiles

| Key | Type | Default |
|-----|------|---------|
| `server.resources` | map | `{}` (no requests or limits) |

The value is rendered as the container `resources` block without changes.

```yaml
server:
  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { memory: 512Mi }
```

To get the `Guaranteed` QoS class, set CPU and memory limits equal to the
requests, as all the shipped profiles do. That protects the server pod from
eviction under node memory pressure.

### Profiles

The chart ships profiles in
[`charts/openbao/resource-profiles/`](/charts/openbao/resource-profiles).
Some of them **also change the deployment mode**:

| Profile | CPU / memory per pod | `dev_mode.enabled` | HA + Raft | Replicas | PDB `maxUnavailable` |
|---------|----------------------|--------------------|-----------|----------|----------------------|
| `dev.yaml` | 250m / 256Mi | `true` | - | 1 | - |
| `small.yaml` | 250m / 256Mi | `false` | - | 1 (standalone) | - |
| `medium.yaml` | 500m / 512Mi | `false` | yes | 3 | 1 |
| `large.yaml` | 1 / 1Gi | `false` | **no** (standalone) | 1 | - |
| `prod.yaml` | 250m / 256Mi | `false` | yes | 3 | 1 |

`large.yaml` does not enable HA, although `docs/installation.md` describes the
large profile as "HA, high load". Combine it with HA values if you need both.

Later `-f` files override earlier ones:

```bash
helm upgrade --install openbao ./charts/openbao -n openbao \
  -f charts/openbao/resource-profiles/medium.yaml \
  -f my-values.yaml
```

---

## 5. Readiness probe

| Key | Type | Default |
|-----|------|---------|
| `server.readinessProbe.enabled` | bool | `true` |
| `server.readinessProbe.path` | string | *(unset)* |
| `server.readinessProbe.port` | int | `8200` |
| `server.readinessProbe.failureThreshold` | int | `2` |
| `server.readinessProbe.initialDelaySeconds` | int | `5` |
| `server.readinessProbe.periodSeconds` | int | `5` |
| `server.readinessProbe.successThreshold` | int | `1` |
| `server.readinessProbe.timeoutSeconds` | int | `3` |

### Probe forms

| `path` | Rendered probe | Ready when |
|--------|----------------|------------|
| unset (default) | `exec: ["/bin/sh", "-ec", "bao status"]` (`-tls-skip-verify` added when TLS is **off**) | Exit code `0`: initialized and unsealed. Sealed returns `2`, an error returns `1` |
| set | `httpGet` on `path` and `port`, scheme `HTTP` or `HTTPS` from `global.tlsDisable` | HTTP `200` to `399` |

`port` is used only by the `httpGet` form.

With the `httpGet` form and TLS on, the kubelet does not verify the server
certificate. With the exec form, `bao status` verifies it with `BAO_CACERT`.
The certificate must then include `127.0.0.1` or `localhost`. The
chart-generated certificate includes both.

### `/v1/sys/health` status codes

| Server state | Default code | Query parameter to change it |
|--------------|--------------|------------------------------|
| Active, unsealed | 200 | `activecode` |
| Standby | 429 | `standbyok=true` (returns 200), or `standbycode` |
| Performance standby | 473 | `perfstandbyok=true` |
| Uninitialized | 501 | `uninitcode` |
| Sealed | 503 | `sealedcode` |

### Examples

Standbys are ready (HA, HTTP probe):

```yaml
server:
  readinessProbe:
    path: /v1/sys/health?standbyok=true
```

Uninitialized servers count as ready (used by `values.openshift.yaml`, so the
Route works before `bao operator init`):

```yaml
server:
  readinessProbe:
    path: /v1/sys/health?uninitcode=204
```

Sealed or uninitialized servers count as ready. This is useful when the UI
should be reachable for unsealing. Clients may then hit a sealed pod:

```yaml
server:
  readinessProbe:
    path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204
```

A slow storage backend needs more time:

```yaml
server:
  readinessProbe:
    initialDelaySeconds: 15
    timeoutSeconds: 5
    failureThreshold: 3
```

---

## 6. Liveness probe

| Key | Type | Default |
|-----|------|---------|
| `server.livenessProbe.enabled` | bool | `false` |
| `server.livenessProbe.execCommand` | list | `[]` |
| `server.livenessProbe.path` | string | `/v1/sys/health?standbyok=true` |
| `server.livenessProbe.port` | int | `8200` |
| `server.livenessProbe.failureThreshold` | int | `2` |
| `server.livenessProbe.initialDelaySeconds` | int | `60` |
| `server.livenessProbe.periodSeconds` | int | `5` |
| `server.livenessProbe.successThreshold` | int | `1` |
| `server.livenessProbe.timeoutSeconds` | int | `3` |

A non-empty `execCommand` takes precedence over `path`. Otherwise an
`httpGet` probe is rendered.

> **Pitfall: restart loops.** The default `path` returns `503` for a sealed
> server and `501` for an uninitialized one. If you unseal manually, the
> kubelet restarts the pod before you can unseal it, and the restart seals it
> again. Enable liveness only together with auto-unseal, or allow the sealed
> state:

```yaml
server:
  livenessProbe:
    enabled: true
    path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204
    initialDelaySeconds: 60
```

An exec probe with a custom script from a mounted ConfigMap:

```yaml
server:
  livenessProbe:
    enabled: true
    execCommand:
      - /bin/sh
      - -c
      - /openbao/userconfig/liveness/check.sh
  extraVolumes:
    - type: configMap
      name: liveness
```

---

## 7. Lifecycle hooks and termination

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.terminationGracePeriodSeconds` | int | `10` | Pod `terminationGracePeriodSeconds` |
| `server.preStopSleepSeconds` | int | `5` | Sleep before `SIGTERM` in the `preStop` hook |
| `server.postStart` | list | `[]` | `postStart` exec command. Ignored when `server.dev_mode.enabled: true` |

### preStop

The chart always renders:

```sh
sleep <preStopSleepSeconds> && kill -SIGTERM $(pidof bao)
```

The container runs `bao` under `/bin/sh -ec`, so `bao` does not get the
kubelet's `SIGTERM` directly. The hook first waits for endpoint removal to
propagate, then stops `bao` so it can step down and clean up. Keep
`terminationGracePeriodSeconds` larger than `preStopSleepSeconds` plus the
shutdown time:

```yaml
server:
  preStopSleepSeconds: 10
  terminationGracePeriodSeconds: 30
```

### postStart

In dev mode the chart replaces this hook with its auto-init and auto-unseal
script. See [01-quick-start.md §3](01-quick-start.md#3-verify-the-deployment).
Otherwise you can run your own command after the container starts:

```yaml
server:
  dev_mode:
    enabled: false
  postStart:
    - /bin/sh
    - -c
    - /openbao/userconfig/bootstrap/run.sh
  extraVolumes:
    - type: configMap
      name: bootstrap
```

The hook runs in parallel with the server process. It must wait for the API,
for example by polling `bao status`. A failing hook makes the kubelet kill the
container.

---

## 8. Environment variables

| Key | Type | Default |
|-----|------|---------|
| `server.extraEnvironmentVars` | map | `{}` |
| `server.extraSecretEnvironmentVars` | list of `{envName, secretName, secretKey}` | `[]` |

Rendering rules:

- `extraEnvironmentVars` keys are upper-cased and `.` becomes `_`. Values are
  quoted.
- Secret variables are rendered **before** plain variables. Both come after
  the built-in variables listed in
  [02-concepts.md §5](02-concepts.md#5-container-environment).
- If a key duplicates a built-in variable, Kubernetes uses the **last**
  definition. Overriding `BAO_ADDR`, `BAO_API_ADDR` or `BAO_CLUSTER_ADDR`
  this way works but is not recommended. Use `server.ha.apiAddr` and
  `server.ha.clusterAddr` instead.

### Example: AWS KMS auto-unseal

```yaml
server:
  extraEnvironmentVars:
    AWS_REGION: eu-central-1
  extraSecretEnvironmentVars:
    - envName: AWS_ACCESS_KEY_ID
      secretName: kms-creds
      secretKey: access_key
    - envName: AWS_SECRET_ACCESS_KEY
      secretName: kms-creds
      secretKey: secret_key
```

The HCL then only needs `seal "awskms" { kms_key_id = "..." }`.

### Example: GCP credentials file

```yaml
server:
  extraEnvironmentVars:
    google.project: my-project            # -> GOOGLE_PROJECT
    GOOGLE_APPLICATION_CREDENTIALS: /openbao/userconfig/gcp-creds/key.json
  extraVolumes:
    - type: secret
      name: gcp-creds
```

### Example: runtime placeholders

`TRANSIT_ADDR`, `API_ADDR` and `RAFT_ADDR` are substituted into the HCL only
when you set them. See
[02-concepts.md §4](02-concepts.md#stage-4-runtime-placeholder-substitution).

```yaml
server:
  extraEnvironmentVars:
    TRANSIT_ADDR: https://transit.example.com:8200
```

---

## 9. Extra arguments and ports

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.extraArgs` | string | `""` | Appended to `bao server -config=/tmp/storageconfig.hcl` |
| `server.extraPorts` | list | `[]` | Extra entries in the container `ports` list |

The fixed container ports are `8200` (`http` or `https`), `8201`
(`https-internal`) and `8202` (`http-rep` or `https-rep`).

```yaml
server:
  extraArgs: "-log-requests-level=info"
  extraPorts:
    - containerPort: 9102
      name: sidecar-metrics
  service:
    extraPorts:
      - name: sidecar-metrics
        port: 9102
        targetPort: 9102
```

`extraArgs` is inserted into a shell command without escaping. Quote values
that contain spaces or shell characters.

---

## 10. Volumes and mounts

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.volumes` | list | `null` | Added to pod `volumes` without changes (`toYaml`) |
| `server.volumeMounts` | list | `null` | Added to the server container `volumeMounts` without changes |
| `server.extraVolumes` | list of `{type, name, path, defaultMode}` | `[]` | **Deprecated.** Generated volume plus a read-only mount |

### Fixed mounts

Do not reuse these paths:

| Path | Volume | When |
|------|--------|------|
| `/openbao/config` | `config` (ConfigMap `<fullname>-config`) | Always, when a config is set |
| `/openbao/data` (`server.dataStorage.mountPath`) | `data` PVC | Standalone, HA with Raft |
| `/openbao/audit` (`server.auditStorage.mountPath`) | `audit` PVC | `server.auditStorage.enabled` |
| `/openbao/tls` (`server.tls.mountPath`) | `tls` Secret | TLS on |
| `/home/openbao` | `home` (`emptyDir`) | Always |

### `volumes` / `volumeMounts` (preferred)

Init containers and sidecars can mount these volumes by name.

```yaml
server:
  volumes:
    - name: plugins
      emptyDir: {}
    - name: corp-ca
      configMap:
        name: corp-ca-bundle
  volumeMounts:
    - name: plugins
      mountPath: /usr/local/libexec/openbao
      readOnly: true
    - name: corp-ca
      mountPath: /etc/ssl/corp
      readOnly: true
```

### `extraVolumes` (deprecated)

| Field | Required | Meaning |
|-------|----------|---------|
| `type` | yes | `secret` or `configMap` |
| `name` | yes | Name of the existing Secret or ConfigMap |
| `path` | no | Parent directory. Default `/openbao/userconfig` |
| `defaultMode` | no | File mode. Default `420` (`0644`) |

The volume is named `userconfig-<name>` and is mounted read-only at
`<path>/<name>`:

```yaml
server:
  extraVolumes:
    - type: secret
      name: kms-creds        # -> /openbao/userconfig/kms-creds/...
```

---

## 11. Init containers and sidecars

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.extraInitContainers` | list | `[]` | Pod `initContainers`. Rendered through `tpl` |
| `server.extraContainers` | list | `null` | Extra containers after `openbao`. Rendered through `tpl` |
| `server.shareProcessNamespace` | bool | `false` | Pod `shareProcessNamespace: true` |

Both lists accept template expressions:

```yaml
server:
  extraContainers:
    - name: audit-shipper
      image: "registry.example.com/fluent-bit:3.1"
      args: ["-i", "tail", "-p", "path=/openbao/audit/*.log", "-o", "stdout"]
      volumeMounts:
        - name: audit
          mountPath: /openbao/audit
          readOnly: true
      env:
        - name: RELEASE
          value: "{{ .Release.Name }}"
```

### Example: plugin installation

```yaml
server:
  volumes:
    - name: plugins
      emptyDir: {}
  volumeMounts:
    - name: plugins
      mountPath: /usr/local/libexec/openbao
      readOnly: true
  extraInitContainers:
    - name: fetch-plugin
      image: alpine:3.20
      command: [sh, -c]
      args:
        - wget -qO /plugins/my-plugin https://artifacts.example.com/my-plugin &&
          chmod +x /plugins/my-plugin
      volumeMounts:
        - name: plugins
          mountPath: /plugins
```

Add `plugin_directory = "/usr/local/libexec/openbao"` to your HCL. See
[12-advanced.md](12-advanced.md#3-plugins).

### Example: signal OpenBao from a sidecar

With `shareProcessNamespace: true` a sidecar can see the `bao` process and
send it `SIGHUP` (for example after log rotation):

```yaml
server:
  shareProcessNamespace: true
  extraContainers:
    - name: log-rotate
      image: alpine:3.20
      command: [sh, -c, "while true; do sleep 86400; pkill -HUP bao; done"]
```

---

## 12. Scheduling

| Key | Type | Default |
|-----|------|---------|
| `server.affinity` | string (tpl) or map | Required pod anti-affinity on `kubernetes.io/hostname` |
| `server.topologySpreadConstraints` | string (tpl) or list | `[]` |
| `server.tolerations` | string (tpl) or list | `[]` |
| `server.nodeSelector` | string (tpl) or map | `{}` |
| `server.priorityClassName` | string | `""` |

### Affinity

The default **requires** each server pod to run on a different node. A
3-replica HA cluster needs 3 schedulable nodes. Otherwise pods stay
`Pending`.

Single-node clusters (kind, minikube):

```yaml
server:
  affinity: ""
```

Prefer spreading instead of requiring it:

```yaml
server:
  affinity: |
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: {{ template "openbao.name" . }}
                app.kubernetes.io/instance: "{{ .Release.Name }}"
                component: server
            topologyKey: kubernetes.io/hostname
```

### Zones

```yaml
server:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: openbao
          app.kubernetes.io/instance: openbao
          component: server
```

The YAML form is not templated. Write the release name literally, or use the
string form with `{{ .Release.Name }}`.

### Dedicated nodes

```yaml
server:
  nodeSelector:
    node-role.example.com/security: "true"
  tolerations:
    - key: dedicated
      operator: Equal
      value: security
      effect: NoSchedule
  priorityClassName: system-cluster-critical
```

A priority class prevents eviction in favor of lower-priority workloads. The
class must exist, and `system-*` classes are allowed only in some namespaces.

---

## 13. Host settings

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.hostNetwork` | bool | `false` | Pod `hostNetwork`. Not rendered when `global.openshift: true` |
| `server.hostAliases` | list | `[]` | Pod `hostAliases` (entries in `/etc/hosts`) |

```yaml
server:
  hostAliases:
    - ip: 10.20.30.40
      hostnames:
        - kms.internal.example.com
```

With `hostNetwork: true` the ports 8200 to 8202 must be free on every node,
and `POD_IP` becomes the node IP. Avoid it unless your network plugin forces
it.

---

## 14. Pod metadata

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.extraLabels` | map | `{}` | Extra labels on the pod template |
| `server.annotations` | map or string (tpl) | `{}` | Extra annotations on the pod template |
| `server.configAnnotation` | bool | `false` | Adds a SHA-256 checksum of the rendered config |

```yaml
server:
  extraLabels:
    team: platform-security
  annotations: |
    prometheus.io/scrape: "false"
    release-name: {{ .Release.Name }}
  configAnnotation: true
```

With `configAnnotation: true`:

- the pod template gets `openbao.hashicorp.com/config-checksum: <sha256>`;
- the config ConfigMap gets `vault.hashicorp.com/config-checksum: <sha256>`.

The two keys differ. Use the pod key when you compare pods with the current
config. With `RollingUpdate`, a config change triggers a rollout. With
`OnDelete`, you can see which pods still run the old config:

```bash
kubectl -n openbao get pods -l component=server \
  -o custom-columns='POD:.metadata.name,CHECKSUM:.metadata.annotations.openbao\.hashicorp\.com/config-checksum'
```

`server.extraLabels` cannot override the selector labels
(`app.kubernetes.io/name`, `app.kubernetes.io/instance`, `component`). If you
duplicate them, the YAML has duplicate keys and the result is undefined.
