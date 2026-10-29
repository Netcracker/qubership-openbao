# OpenBao Helm Chart: Documentation Index

This documentation set describes the `openbao` Helm chart shipped in
[`charts/openbao`](/charts/openbao). It is organized from basic to advanced
topics: start with the quick start, read the concepts, and then go to the
parameter reference and the mode-specific guides.

| Item | Value |
|------|-------|
| Chart name | `openbao` |
| Chart version | `0.28.3` (`charts/openbao/Chart.yaml`) |
| Application version | `v2.6.2` (default image `quay.io/openbao/openbao:2.6.2`) |
| Upstream | [`openbao/openbao-helm`](https://github.com/openbao/openbao-helm) |
| Kubernetes | `>= 1.30.0-0` |

## What this chart is

The chart deploys the [OpenBao](https://openbao.org) server, an open-source
fork of HashiCorp Vault for secrets management and encryption as a service,
to Kubernetes or OpenShift. It is the Netcracker/Qubership distribution of
the upstream chart.

### Differences from upstream

| Area | Upstream `openbao-helm` | This distribution |
|------|-------------------------|-------------------|
| Agent Injector (mutating webhook) | Deployed | **Not deployed** (templates moved out of `templates/`) |
| Secrets Store CSI provider | Deployed | **Not deployed** |
| Default mode | Standalone | **Persistent dev mode** (`server.dev_mode.enabled: true`) with auto-init and auto-unseal |
| Dev mode storage | In-memory | Single-node integrated Raft on a PVC; data survives restarts |
| Standalone storage | `file` backend | **Single-node integrated Raft** (`storage "raft"`, node ID = pod name): Raft snapshots, snapshot agent, in-place move to HA Raft |
| TLS | Manual (`extraVolumes` plus your own HCL) | Built in: `server.tls.*` with cert-manager, inline certs or an existing secret |
| Data PVC | Optional (`dataStorage.enabled`) | **Mandatory**; there is no `enabled` switch |
| Identity labels | Standard Helm labels | Additional `SERVICE_NAME`, `APPLICATION_NAME`, `MANAGED_BY`, `DEPLOYMENT_SESSION_ID` values used by the Netcracker deployer |
| Gateway API | Routes only | Routes plus `BackendTLSPolicy`, CRD presence checks and `parentRefs` validation at render time |

## Document map

### Level 1: Basics

| Document | Contents |
|----------|----------|
| [01-quick-start.md](01-quick-start.md) | Install with defaults, verify, get the root token, open the UI, uninstall |
| [02-concepts.md](02-concepts.md) | Mode resolution, rendered resources, the configuration pipeline, ports, naming and labels |

### Level 2: Parameter reference

| Document | Contents |
|----------|----------|
| [03-global-and-identity.md](03-global-and-identity.md) | `global.*`, identity labels, naming overrides, `deployDescriptor` image override |
| [04-server-workload.md](04-server-workload.md) | Image, StatefulSet, probes, lifecycle, environment, volumes, scheduling |
| [05-storage.md](05-storage.md) | `server.dataStorage`, `server.auditStorage`, PVC retention, resizing |
| [06-services-and-exposure.md](06-services-and-exposure.md) | Services, UI, Ingress, OpenShift Route, Gateway API |
| [07-tls.md](07-tls.md) | End-to-end TLS with `certManager`, `rawCerts` or `existingSecret` |
| [08-security-and-rbac.md](08-security-and-rbac.md) | ServiceAccount, auth delegator, discovery RBAC, security contexts, NetworkPolicy |

### Level 3: Deployment modes

| Document | Contents |
|----------|----------|
| [09-deployment-modes.md](09-deployment-modes.md) | Dev, Standalone, HA with Raft, HA with external storage (PostgreSQL), External; comparison and migration between modes |

### Level 4: Advanced topics

| Document | Contents |
|----------|----------|
| [10-observability.md](10-observability.md) | Telemetry, ServiceMonitor, PrometheusRule, Grafana, logs and health checks |
| [11-backup-snapshot-agent.md](11-backup-snapshot-agent.md) | Snapshot agent CronJob, S3, restore |
| [12-advanced.md](12-advanced.md) | Custom HCL, auto-unseal, plugins, sidecars, OpenShift, air-gapped installs, upgrades, dual-stack |
| [13-troubleshooting.md](13-troubleshooting.md) | Render-time errors, runtime problems, diagnostics |
| [14-known-issues.md](14-known-issues.md) | Known gaps between values, templates, tests and docs |
| [15-test-plan.md](15-test-plan.md) | Chart test plan: test levels, environments, unit/acceptance cases, exit criteria |

## Reading paths

| Role | Recommended order |
|------|-------------------|
| Developer who needs a local OpenBao | 01 → 02 → 09 (Dev section) |
| Platform operator who deploys to staging or production | 01 → 02 → 03 → 04 → 05 → 07 → 09 (Standalone or HA Raft) → 08 |
| SRE who runs production clusters | 02 → 09 (HA Raft) → 07 → 10 → 11 → 12 → 13 |

## Compatibility and optional dependencies

The chart has no hard dependencies other than Kubernetes and a StorageClass.
The integrations below are optional. The chart renders the related resources
only when you enable them.

| Dependency | Needed for | API used by the chart | Behavior if missing |
|------------|-----------|-----------------------|---------------------|
| Kubernetes `>= 1.30` | Everything | `apps/v1`, `policy/v1`, `networking.k8s.io/v1`, `rbac.authorization.k8s.io/v1` | Helm refuses to install (`kubeVersion` constraint) |
| Helm 3 | Installation | - | - |
| Default or explicit StorageClass | Data PVC (always created when a server is deployed) | `PersistentVolumeClaim` | Pod stays `Pending` |
| cert-manager | `global.tlsDisable: false` with `server.tls.source: certManager` | `cert-manager.io/v1` `Certificate`, `Issuer` | Install fails with unknown kind |
| Gateway API CRDs | `server.gateway.httpRoute`, `tlsRoute`, `tlsPolicy` | `gateway.networking.k8s.io/v1` by default (configurable `apiVersion`) | Render fails with an explicit error message |
| Prometheus Operator | `serverTelemetry.serviceMonitor`, `serverTelemetry.prometheusRules` | `monitoring.coreos.com/v1` | Install fails with unknown kind |
| Grafana sidecar (dashboard loader) | `serverTelemetry.grafanaDashboard` | Plain `ConfigMap` with label `grafana_dashboard: "1"` | ConfigMap is created but not loaded |
| PostgreSQL | HA mode without Raft (`server.ha.enabled: true`, `raft.enabled: false`) with a custom `server.ha.config`. The default config uses Consul, which OpenBao 2.x does not support (see [09-deployment-modes.md §5](09-deployment-modes.md#5-ha-with-external-storage)) | `BAO_PG_CONNECTION_URL` | Server cannot start its storage backend |
| OpenShift | `global.openshift: true`, `server.route` | `route.openshift.io/v1` | Route is not rendered on vanilla Kubernetes |
| S3-compatible storage | `snapshotAgent` | - | Snapshot job fails |

## Conventions used in this documentation

- Parameter paths are written as `server.ha.raft.enabled` and refer to keys in
  [`values.yaml`](/charts/openbao/values.yaml).
- `<fullname>` is the resource name prefix computed by the chart. With
  `helm install openbao ...` it is `openbao`. See
  [02-concepts.md](02-concepts.md#resource-naming).
- Examples assume the release name `openbao`, the namespace `openbao` and that
  you run commands from the repository root.
- Code references use the `file:line` format, for example
  `charts/openbao/templates/_helpers.tpl:180`.
- Complete, commented values files, overlays and helper scripts are in
  [`examples/`](../../examples/README.md).
- The full auto-generated values table is in
  [`charts/openbao/README.md`](/charts/openbao/README.md). These documents
  explain the values in context.
