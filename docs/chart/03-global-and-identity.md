# Global Settings and Identity

This document covers the values that apply to the whole release: the
top-level identity values used by the Netcracker deployer, the `global.*`
block, naming overrides and image resolution.

- [1. Identity values](#1-identity-values)
- [2. `global.enabled`](#2-globalenabled)
- [3. `global.namespace`](#3-globalnamespace)
- [4. `global.imagePullSecrets`](#4-globalimagepullsecrets)
- [5. `global.tlsDisable`](#5-globaltlsdisable)
- [6. `global.externalBaoAddr`](#6-globalexternalbaoaddr)
- [7. `global.openshift`](#7-globalopenshift)
- [8. `global.serverTelemetry.prometheusOperator`](#8-globalservertelemetryprometheusoperator)
- [9. Naming overrides](#9-naming-overrides)
- [10. Image resolution with `deployDescriptor`](#10-image-resolution-with-deploydescriptor)

> Examples in this document have not yet been checked with `helm template`.
> Verify the rendered output with your chart version before you rely on it.

---

## 1. Identity values

These top-level values set the standard Kubernetes recommended labels and the
Netcracker session label. During an integrated Netcracker install the deploy
descriptor supplies them. The defaults keep a standalone `helm install`
consistent.

| Key | Type | Default | Rendered as | Objects |
|-----|------|---------|-------------|---------|
| `SERVICE_NAME` | string | `openbao` | `app.kubernetes.io/name` (and `name` on Services) | All chart objects except pod templates, NetworkPolicy, Route and the Grafana ConfigMap |
| `APPLICATION_NAME` | string | `openbao` | `app.kubernetes.io/part-of` | Same as above |
| `MANAGED_BY` | string | `Helm` | `app.kubernetes.io/managed-by` | Same as above |
| `DEPLOYMENT_SESSION_ID` | string | `""` | `deployment.netcracker.com/sessionId` | Same as above |
| `ARTIFACT_DESCRIPTOR_VERSION` | string | *(not defined)* | `app.kubernetes.io/version` | StatefulSet only |

`ARTIFACT_DESCRIPTOR_VERSION` is not declared in `values.yaml`. In a
standalone install the StatefulSet gets an empty `app.kubernetes.io/version: ''`
label. Set it if your tooling relies on that label.

These labels go on **object metadata only**. Pod selectors use
`openbao.name` and the release name. See
[02-concepts.md §8](02-concepts.md#8-labels-and-selectors).

### Pitfall: empty `SERVICE_NAME`

The ServiceMonitor selects Services by
`app.kubernetes.io/name: '<SERVICE_NAME>'`. Services carry the same label.
`values.yaml` requires `SERVICE_NAME` to be non-empty and warns that an empty
value stops metrics from being scraped. An empty value also makes the
selector match any Service in the namespace that has an empty
`app.kubernetes.io/name` label. Always set a non-empty, release-specific
value.

### Example: standalone install

The defaults work as is. Set the session ID if you want to trace the release:

```yaml
DEPLOYMENT_SESSION_ID: "manual-2026-10-08"
ARTIFACT_DESCRIPTOR_VERSION: "0.28.3"
```

### Example: values supplied by the deployer

```yaml
SERVICE_NAME: openbao
APPLICATION_NAME: platform-security
MANAGED_BY: argocd
DEPLOYMENT_SESSION_ID: "9f2c1d7e-..."
ARTIFACT_DESCRIPTOR_VERSION: "release-2026.4"
```

Result on the client Service:

```yaml
metadata:
  name: openbao
  labels:
    app.kubernetes.io/name: 'openbao'
    app.kubernetes.io/part-of: 'platform-security'
    app.kubernetes.io/managed-by: 'argocd'
    deployment.netcracker.com/sessionId: '9f2c1d7e-...'
```

---

## 2. `global.enabled`

| Key | Type | Default |
|-----|------|---------|
| `global.enabled` | bool | `true` |

Master switch for the tri-state values (`server.enabled`, `ui.enabled`) that
use `"-"`. See [02-concepts.md §2](02-concepts.md#2-tri-state-switches--).

| `global.enabled` | `server.enabled` | Server deployed? |
|------------------|------------------|------------------|
| `true` | `"-"` (default) | Yes |
| `true` | `false` | No (mode `external`) |
| `false` | `"-"` | No (mode `external`) |
| `false` | `true` | Yes |

Objects that have their own explicit `enabled: true/false` switch, such as
`snapshotAgent`, `serverTelemetry.*` and `server.networkPolicy`, ignore
`global.enabled`.

### Example: snapshot agent only, against an external server

```yaml
global:
  enabled: false
  externalBaoAddr: https://openbao.example.com:8200

snapshotAgent:
  enabled: true
  s3CredentialsSecret: s3-creds
```

With `global.enabled: false` and `server.enabled: "-"`, the server
ServiceAccount and the auth-delegator binding are not created either. The
snapshot agent uses its own ServiceAccount (`snapshotAgent.serviceAccount`).

---

## 3. `global.namespace`

| Key | Type | Default |
|-----|------|---------|
| `global.namespace` | string | `""` (use the Helm release namespace) |

The `openbao.namespace` helper returns `global.namespace` if set, otherwise
`.Release.Namespace`. Every namespaced object uses it.

```yaml
global:
  namespace: security
```

```bash
helm install openbao ./charts/openbao -n deploy-tools -f values.yaml
# StatefulSet, Services, ConfigMap, ... are created in "security".
# Helm stores the release record in "deploy-tools".
```

### Pitfalls

- `server-network-policy.yaml` does not set `metadata.namespace`. The
  NetworkPolicy is created in the `-n` namespace, not in `global.namespace`,
  and does not protect the pods. Keep both namespaces the same if you use
  `server.networkPolicy`.
- The ClusterRoleBinding subject and the TLS certificate SANs use
  `global.namespace`. This is correct, but changing the value on a running
  release reissues the certificate and moves every object.

---

## 4. `global.imagePullSecrets`

| Key | Type | Default |
|-----|------|---------|
| `global.imagePullSecrets` | list of string or `{name}` | `[]` |

Both formats are accepted by the `imagePullSecrets` helper:

```yaml
global:
  imagePullSecrets:
    - registry-creds          # string form
    - name: mirror-creds      # object form
```

Rendered on the server pod:

```yaml
spec:
  imagePullSecrets:
    - name: registry-creds
    - name: mirror-creds
```

The Secrets must already exist in the target namespace:

```bash
kubectl -n openbao create secret docker-registry registry-creds \
  --docker-server=registry.example.com \
  --docker-username=robot --docker-password='***'
```

### Pitfall: snapshot agent

The snapshot agent CronJob template does not render `imagePullSecrets`. If the
snapshot image comes from a private registry, attach the pull secret to the
snapshot ServiceAccount:

```bash
kubectl -n openbao patch serviceaccount openbao-snapshot \
  -p '{"imagePullSecrets":[{"name":"registry-creds"}]}'
```

---

## 5. `global.tlsDisable`

| Key | Type | Default |
|-----|------|---------|
| `global.tlsDisable` | bool | `true` (plain HTTP) |

This is the single switch for server TLS. The `server.tls.*` block takes
effect only when `global.tlsDisable: false`. The chart validates the two at
render time. Full details are in [07-tls.md](07-tls.md).

Setting `global.tlsDisable: false` changes:

| Area | `true` (default) | `false` |
|------|------------------|---------|
| Listener in default HCL | `tls_disable = 1` | `tls_cert_file`, `tls_key_file`, `tls_min_version` |
| Scheme (`openbao.scheme`) | `http` | `https` |
| Service and container port names | `http`, `http-rep` | `https`, `https-rep` |
| `BAO_ADDR`, default `BAO_API_ADDR` | `http://...` | `https://...` |
| `BAO_CACERT` | not set | `<mountPath>/<caKey>` |
| TLS Secret volume | not mounted | mounted at `server.tls.mountPath` |
| Readiness exec probe | `bao status -tls-skip-verify` | `bao status` (verifies with `BAO_CACERT`) |
| Raft `retry_join` | `http://<pod>.<fullname>-internal:8200` | `https://...` |
| ServiceMonitor | `scheme: http`, `insecureSkipVerify: true` | `scheme: https`, CA from the TLS Secret |
| Snapshot agent | `BAO_ADDR=http://...` | `https://...`, `BAO_CACERT`, TLS Secret mounted |
| TLS resources | none | Certificate, Issuer or Secret, depending on `server.tls.source` |

Changing this value on an existing release needs a pod restart. See
[07-tls.md §8](07-tls.md#8-enabling-tls-on-a-running-release).

---

## 6. `global.externalBaoAddr`

| Key | Type | Default |
|-----|------|---------|
| `global.externalBaoAddr` | string (URL) | `""` |
| `global.externalVaultAddr` | string (URL) | `""` (**deprecated**) |

A non-empty value switches the chart to `external` mode. No StatefulSet,
config ConfigMap or server Services are created. When both are set,
`externalBaoAddr` wins (`openbao.global.externalAddr` helper).

| Object | Rendered in external mode? |
|--------|----------------------------|
| StatefulSet, config ConfigMap, Services, PDB, Ingress, Gateway routes, TLS resources | No |
| ServiceAccount (`server.serviceAccount.create`) | Yes, when `server.enabled` or `global.enabled` is `true` |
| auth-delegator ClusterRoleBinding | Yes, under the same condition |
| ServiceAccount token Secret (`createSecret: true`) | Yes |
| Snapshot agent | Yes, with `BAO_ADDR=<externalBaoAddr>` |
| ServiceMonitor | Yes, if enabled, but it selects Services from this release and finds none |
| NetworkPolicy | Yes, if enabled |

### Example: Kubernetes auth for an external OpenBao

The release creates a long-lived reviewer token in the cluster. The external
OpenBao uses it to validate service account tokens.

```yaml
global:
  externalBaoAddr: https://openbao.example.com:8200

server:
  serviceAccount:
    create: true
    createSecret: true       # Secret <fullname>-token
  authDelegator:
    enabled: true
```

```bash
TOKEN=$(kubectl -n openbao get secret openbao-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n openbao get secret openbao-token -o jsonpath='{.data.ca\.crt}' | base64 -d)

bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host=https://<api-server>:6443 \
  kubernetes_ca_cert="$CA" \
  token_reviewer_jwt="$TOKEN"
```

---

## 7. `global.openshift`

| Key | Type | Default |
|-----|------|---------|
| `global.openshift` | bool | `false` |

Effects when `true`:

| Area | Kubernetes (`false`) | OpenShift (`true`) |
|------|----------------------|--------------------|
| Pod security context (when `server.statefulSet.securityContext.pod` is empty) | `runAsNonRoot`, `runAsUser: 100`, `runAsGroup: 1000`, `fsGroup: 1000`, `seccompProfile: RuntimeDefault` | not rendered; the SCC assigns UID and GID |
| Container security context (when empty) | `allowPrivilegeEscalation: false` | not rendered |
| Snapshot agent security contexts | Same defaults plus `capabilities.drop: [ALL]` | not rendered |
| `hostNetwork` field | rendered from `server.hostNetwork` | not rendered |
| `server.route` | ignored | Route is rendered when `server.route.enabled: true` |
| `server.ingress` | used | still rendered if enabled (the values comment says it is ignored, but the template does not check) |

The chart includes an OpenShift overlay:

```bash
helm install openbao ./charts/openbao -n openbao \
  -f charts/openbao/values.openshift.yaml
```

| Override in `values.openshift.yaml` | Why |
|--------------------------------------|-----|
| `global.openshift: true` | Turns on the behavior above |
| `server.image.registry: registry.connect.redhat.com`, `repository: openbao/openbao-ubi` | Certified UBI image. `tag` is not overridden, so it stays `2.6.2`. Check that this tag exists in that registry |
| `server.readinessProbe.path: /v1/sys/health?uninitcode=204` | Switches to an `httpGet` probe. An uninitialized server returns 204 and counts as ready, so the Route works before initialization |
| `injector.*` | Not used by this distribution |

### Example: OpenShift with a passthrough Route

```yaml
global:
  openshift: true
  tlsDisable: false

server:
  route:
    enabled: true
    host: openbao.apps.example.com
    tls:
      termination: passthrough
  tls:
    source: certManager
    certManager:
      clusterIssuerName: corp-ca
      extraSans:
        - openbao.apps.example.com
```

---

## 8. `global.serverTelemetry.prometheusOperator`

| Key | Type | Default |
|-----|------|---------|
| `global.serverTelemetry.prometheusOperator` | bool | `false` |

When `true`, the ServiceMonitor is rendered even if
`serverTelemetry.serviceMonitor.enabled: false`. The PrometheusRule is
rendered too, but only if `serverTelemetry.prometheusRules.rules` is not
empty. This is a convenience switch; the per-object flags are clearer.

```yaml
global:
  serverTelemetry:
    prometheusOperator: true
serverTelemetry:
  prometheusRules:
    rules:
      - alert: OpenBaoSealed
        expr: vault_core_unsealed == 0
        for: 1m
        labels: { severity: critical }
```

The Prometheus Operator CRDs must exist before you install. The server also
needs a `telemetry {}` stanza in its HCL. See [10-observability.md](10-observability.md).

---

## 9. Naming overrides

| Key | Type | Default | Declared in `values.yaml` |
|-----|------|---------|---------------------------|
| `nameOverride` | string | *(unset)* | No |
| `fullnameOverride` | string | *(unset)* | No |

Both are read by the helpers but are not listed in `values.yaml`. The
schema does not forbid them.

| Value | Affects |
|-------|---------|
| `nameOverride` | `openbao.name` (pod label `app.kubernetes.io/name`, all selectors) and `<fullname>` |
| `fullnameOverride` | `<fullname>` only: object names, PVC names, TLS SANs, `retry_join` addresses |

```yaml
fullnameOverride: vault
```

```text
StatefulSet:   vault
Pods:          vault-0, vault-1, vault-2
Services:      vault, vault-internal, vault-active, vault-standby
PVCs:          data-vault-0, ...
```

> **Do not change these on a running release.** New names mean new PVCs, so
> the pods start with empty storage. Changing `nameOverride` also changes the
> StatefulSet selector, which is immutable. `helm upgrade` then fails.

---

## 10. Image resolution with `deployDescriptor`

The server image reference is computed by the `find_image` helper
([`_helpers.tpl:39`](/charts/openbao/templates/_helpers.tpl)):

1. If `deployDescriptor.openbao.image` exists, use it.
2. Otherwise, if `deployDescriptor.<SERVICE_NAME>.image` exists, use it.
3. Otherwise, use `<server.image.registry>/<server.image.repository>:<server.image.tag>`.

`deployDescriptor` is not declared in `values.yaml`. The Netcracker deployer
injects it.

```yaml
# Supplied by the deployer
deployDescriptor:
  openbao:
    image: artifactory.example.com/qubership/openbao:2.6.2-nc1
```

Rendered:

```yaml
containers:
  - name: openbao
    image: "artifactory.example.com/qubership/openbao:2.6.2-nc1"
```

`deployDescriptor` overrides only the server image. The snapshot agent image
always comes from `snapshotAgent.image.repository:tag`.

For manual installs, set `server.image.*` instead. See
[04-server-workload.md §1](04-server-workload.md#1-image).
