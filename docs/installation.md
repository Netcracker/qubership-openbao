[[_TOC_]]

## General information

You can deploy OpenBao in one of the following topologies (the mode is derived
from the switches described in [architecture.md](/docs/architecture.md#deployment-modes)):

- **Dev mode** (`server.dev_mode.enabled: true`, the shipped default) – an
  openbao server with auto unseal mode. 
  Experimentation only.
- **Standalone mode** (`server.standalone.enabled: "-"`) – a single-replica
  server using the `file` storage backend on a PVC. Not highly available.
- **HA mode with integrated Raft** (`server.ha.enabled: true` +
  `server.ha.raft.enabled: true`) – a multi-replica cluster that stores data in
  integrated Raft storage. Recommended for production.
- **HA mode with Consul** (`server.ha.enabled: true`) – a multi-replica cluster
  that uses an external Consul cluster as the storage backend.
- **External mode** (`global.externalBaoAddr` set) – no server is deployed;
  auxiliary resources target an external OpenBao address.

For component details, see the [architecture documentation](/docs/architecture.md).

## Deployment Structure

OpenBao is delivered as a single Helm chart:
- Main app: `openbao`

Depending on the selected mode, the chart deploys some of the following:
- `openbao` server StatefulSet and its config ConfigMap.
- Client, headless (`-internal`), and — in HA — active/standby Services.
- Optional UI Service, Ingress / OpenShift Route / Gateway API routes.
- Optional TLS resources (cert-manager `Certificate`/`Issuer` or a TLS secret).
- Optional observability (ServiceMonitor, PrometheusRule, Grafana dashboard).
- Optional snapshot agent CronJob for periodic Raft backups.

## Prerequisites

- **Kubernetes** >= `1.30.0` (see `charts/openbao/Chart.yaml`).
- **Helm** >= `3.x`.
- **StorageClass** – required for the `file` (standalone) and `raft` (HA)
  backends. `server.dataStorage` defaults to `10Gi`, `ReadWriteOnce`, mounted at
  `/openbao/data`.
- **cert-manager** – required only when TLS is enabled with
  `server.tls.source: certManager`.
- **Gateway API CRDs** – `TLSRoute` (`gateway.networking.k8s.io/v1alpha3`),
  `HTTPRoute` (`v1`) and `BackendTLSPolicy` (`v1`) must be installed for those
  resources to render.
- **Prometheus Operator** – its CRDs must exist before enabling
  `serverTelemetry.serviceMonitor` / `serverTelemetry.prometheusRules`.
- **Consul** – an external Consul cluster is required for HA mode without Raft.
- **OpenShift** – set `global.openshift: true` and expose the server with
  `server.route` instead of an Ingress; see `charts/openbao/values.openshift.yaml`.

## Installation

Install the chart into a namespace (examples assume the chart is available
locally under `charts/openbao`):

```bash
# Dev mode (shipped default) – experimentation only
helm install openbao ./charts/openbao -n openbao --create-namespace
```

```bash
# Standalone (file backend, single replica)
helm install openbao ./charts/openbao -n openbao --create-namespace \
  --set server.dev_mode.enabled=false \
  --set server.standalone.enabled=true
```

```bash
# HA with integrated Raft (recommended for production)
helm install openbao ./charts/openbao -n openbao --create-namespace \
  --set server.dev_mode.enabled=false \
  --set server.ha.enabled=true \
  --set server.ha.raft.enabled=true \
  --set server.ha.replicas=3
```

```bash
# HA with external Consul
helm install openbao ./charts/openbao -n openbao --create-namespace \
  --set server.dev_mode.enabled=false \
  --set server.ha.enabled=true \
  --set server.ha.replicas=3
```

```bash
# External OpenBao (no server deployed)
helm install openbao ./charts/openbao -n openbao --create-namespace \
  --set global.externalBaoAddr=https://openbao.example.com:8200
```

Ready-made value files for the common topologies are provided under
[`examples/`](/examples).

## Initialization and unseal

- **Dev mode** requires no action: the server starts unsealed using the static
  unseal-key secret `bao-static-unseal-key` (`server.dev_mode.sealToken`, random
  if empty).
- **Standalone / HA** servers start **sealed** and must be initialized and
  unsealed after install, for example:

  ```bash
  kubectl exec -n openbao openbao-0 -- bao operator init
  kubectl exec -n openbao openbao-0 -- bao operator unseal <key-share>
  # In HA, join and unseal the remaining replicas as needed.
  ```

- **Auto-unseal** can be configured by adding a `seal` stanza to
  `server.standalone.config` / `server.ha.config` (a commented GCP Cloud KMS
  example is included in `values.yaml`) or via `server.extraEnvironmentVars`.

## Kubernetes authentication

Kubernetes auth delegation is enabled by default via
`server.authDelegator.enabled: true` (binds `system:auth-delegator`) together
with `server.serviceAccount.serviceDiscovery`. This lets OpenBao validate
Kubernetes service-account tokens for the Kubernetes auth method.

## TLS Configuration

By default the chart deploys OpenBao with TLS disabled
(`global.tlsDisable: true`). Set `global.tlsDisable: false` to enable end-to-end
TLS. The server certificate is provisioned through one of three sources selected
by `server.tls.source`: `certManager`, `rawCerts` or `existingSecret`.

For the full reference (issuers, inline certs, existing secrets, SANs, TLS
version/ciphers, rotation and rollout), see
[docs/configuration.md](/docs/configuration.md).

#### Re-encrypt mode (cert-manager)

```yaml
global:
  tlsDisable: false
server:
  tls:
    source: certManager
    certManager:
      generateIssuer: true      # chart bootstraps a self-signed Issuer
  gateway:
    tlsPolicy:
      enabled: true             # BackendTLSPolicy => gateway re-encrypts to the pod
```

- cert-manager creates the certificate; the chart can bootstrap its own
  self-signed `Issuer` (`generateIssuer: true`) or use a `ClusterIssuer`
  (`certManager.clusterIssuerName`).
- The gateway terminates client TLS and opens a new TLS connection to the pod.
- Traffic flow: `Client ---HTTPS---> Gateway API ---HTTPS---> Pod`

#### Passthrough mode (rawCerts / existingSecret)

```yaml
global:
  tlsDisable: false
server:
  tls:
    source: rawCerts
    certs:
      crt: ""
      key: ""
  gateway:
    tlsRoute:
      enabled: true             # TLSRoute => gateway forwards, pod terminates TLS
```

or

```yaml
global:
  tlsDisable: false
server:
  tls:
    source: existingSecret
    secretName: my-openbao-tls
  gateway:
    tlsRoute:
      enabled: true
```

- No re-encryption; the gateway only forwards and the pod handles all TLS.
- Traffic flow: `Client ---HTTPS---> Pod`

The Gateway API resources (`TLSRoute` / `BackendTLSPolicy`) are only rendered
when the corresponding CRD is installed in the cluster.

## Web UI

The OpenBao UI is disabled by default. Enable it with `ui.enabled: true`; the
service type is controlled by `ui.serviceType` (`ClusterIP`, `NodePort` or
`LoadBalancer`) and listens on `ui.externalPort` (default `8200`).

## Monitoring

Metrics integration is disabled by default. When
`serverTelemetry.serviceMonitor.enabled: true`, the chart creates a
`ServiceMonitor` (and, optionally, `PrometheusRule` alerts and a Grafana
dashboard) for the Prometheus Operator. The OpenBao `telemetry{}` stanza must be
present in the listener config for metrics to be exposed; see the commented
examples in `values.yaml`.

## PodDisruptionBudget Configuration

In HA mode a PodDisruptionBudget keeps a quorum available during voluntary
disruptions such as node drains or cluster upgrades. It is controlled by
`server.ha.disruptionBudget.enabled` (default `true`) and
`server.ha.disruptionBudget.maxUnavailable`.

**Warning:** a PodDisruptionBudget is only meaningful in HA mode; it is not
applicable to dev or standalone (single-replica) deployments.

## OpenBao resource profiles

The profiles below are general recommendations only. Resources should be sized
and validated for each project.

### Small (dev / testing)

| Component | Replica | CPU  | RAM   | Storage |
|-----------|---------|------|-------|---------|
| openbao (dev/standalone) | 1 | 250m | 256Mi | 10Gi |
| **Total (Rounded)** | **1** | **250m** | **256Mi** | **10Gi** |

### Medium (HA)

| Component | Replica | CPU  | RAM   | Storage |
|-----------|---------|------|-------|---------|
| openbao (ha + raft) | 3 | 500m | 512Mi | 10Gi each |
| **Total (Rounded)** | **3** | **1.5** | **1.5Gi** | **30Gi** |

### Large (HA, high load)

| Component | Replica | CPU | RAM  | Storage |
|-----------|---------|-----|------|---------|
| openbao (ha + raft) | 3 | 1 | 1Gi | 20Gi each |
| **Total (Rounded)** | **3** | **3** | **3Gi** | **60Gi** |

Resource requests/limits are set via `server.resources`; storage size via
`server.dataStorage.size`. Replica count is `server.ha.replicas`.

## Storage

- **Data** – `server.dataStorage` creates the PVC used by the `file`
  (standalone) and `raft` (HA) backends. Defaults: `10Gi`, `ReadWriteOnce`,
  mounted at `/openbao/data`. Set `server.dataStorage.storageClass` to pin a
  StorageClass.
- **Audit** – `server.auditStorage` (disabled by default) creates a PVC mounted
  at `/openbao/audit` for audit logs; OpenBao must be configured to write audit
  logs there after initialization.
- **Retention** – `server.persistentVolumeClaimRetentionPolicy` controls PVC
  retention on delete/scale.
