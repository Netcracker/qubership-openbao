# Known Issues

This document lists differences between `values.yaml`, the templates, the
tests and the existing documentation that were found while writing this
documentation set. Each entry gives the evidence, the impact, a workaround
and a suggested fix in the chart.

All entries come from reading the source. None has been confirmed with
`helm template` or on a cluster yet. Verify each one before you change the
chart.

| Severity | Meaning |
|----------|---------|
| **High** | A documented feature does not work, or a default leads to a broken or insecure deployment |
| **Medium** | A value is ignored or behaves differently from its description |
| **Low** | Cosmetic, inconsistent naming or documentation drift |

## Summary

| # | Area | Issue | Severity |
|---|------|-------|----------|
| 1 | Modes | `.mode` is never `dev`; `dev_mode.config` is ignored | High |
| 2 | Modes | Default HA config uses Consul, which OpenBao 2.x does not provide | High |
| 3 | Examples | `examples/dev.yaml` enabled TLS with empty certificates (**fixed**) | — |
| 4 | TLS | `rawCerts` / `existingSecret` without `ca.crt` breaks the readiness probe | Medium |
| 5 | Raft | `retry_join` hard-coded to 3 replicas, no `leader_ca_cert_file` | Medium |
| 6 | Snapshot | TLS Secret mounted in external mode, where it does not exist | Medium |
| 7 | Snapshot | `snapshotAgent.config.baoAddr` is used by tests but not by the template | Medium |
| 8 | Snapshot | No `imagePullSecrets`, `concurrencyPolicy` or history limits | Medium |
| 9 | Snapshot | Default `s3Host` names a non-existent AWS region | Low |
| 10 | Gateway | `tlsRoute.apiVersion` defaults to `v1` | Medium |
| 11 | Gateway | BackendTLSPolicy: Secret CA reference, `hostname` always appended | Medium |
| 12 | Gateway | `httpRoute.matches.timeouts` is not rendered | Medium |
| 13 | PDB | `maxUnavailable: 0` is treated as unset | Medium |
| 14 | NetworkPolicy | No `metadata.namespace` | Medium |
| 15 | Route | `server-route.yaml` uses `.mode` without computing it | Medium |
| 16 | Monitoring | Grafana `extraLabel` (values) vs `extraLabels` (template) | Low |
| 17 | Values | `extraObjects` declared but never rendered | Medium |
| 18 | Values | Undeclared values used by templates | Low |
| 19 | Annotations | Different checksum annotation keys on pod and ConfigMap | Low |
| 20 | Schema | TLS source requirements checked even when TLS is off | Low |
| 21 | Profiles | `large.yaml` is standalone; docs call it HA | Low |
| 22 | Security | Default container security context does not drop capabilities | Medium |
| 23 | Security | Discovery Role grants `patch` on all pods in the namespace | Low |
| 24 | OpenShift | Ingress rendered on OpenShift despite the comment | Low |
| 25 | Versions | Version numbers differ between README, docs and values | Low |
| 26 | Docs | `installation.md` / `architecture.md` describe HA with Consul and an in-memory-like dev mode | Low |
| 27 | Tests | Unit tests use upstream value names (`server.dev.enabled`) | Medium |
| 28 | Services | `server.service.type` / `clusterIP` documented only in comments | Low |

---

## 1. `.mode` is never `dev`; `server.dev_mode.config` is ignored

**Evidence.** `openbao.mode` (`templates/_helpers.tpl:180`) sets `.mode` to
`external`, `ha`, `standalone` or `""`. It never sets `dev`. Yet several
helpers check `eq .mode "dev"`: `openbao.config` (uses `dev_mode.config`),
`openbao.volumes`, `openbao.mounts`, `openbao.volumeclaims`,
`openbao.affinity`, `openbao.tolerations`, `openbao.nodeselector`,
`openbao.topologySpreadConstraints`, the TLS templates and the
ServiceAccount annotations.

**Impact.**

- With `dev_mode.enabled: true`, the server runs with
  `server.standalone.config`. `server.dev_mode.config` has no effect.
- All `dev` branches are dead code. Affinity, tolerations, node selectors,
  TLS and ServiceAccount annotations are applied in dev mode (which is
  probably fine, but not what the code reads like).
- With `dev_mode.enabled: true` and `standalone.enabled: false`, no
  StatefulSet is rendered, but the Services and an empty ConfigMap are.
- Only the `postStart` replacement depends on `dev_mode.enabled` directly.

**Workaround.** Customize dev mode through `server.standalone.config`.

**Suggested fix.** In `openbao.mode`, add before the `standalone` branch:

```gotemplate
{{- else if eq (.Values.server.dev_mode.enabled | toString) "true" -}}
  {{- $_ := set . "mode" "dev" -}}
```

Then review every `dev` branch, because they start to take effect (for
example, TLS resources would no longer be rendered in dev mode).

---

## 2. Default HA config uses Consul

**Evidence.** `server.ha.config` in `values.yaml` contains
`storage "consul" { address = "HOST_IP:8500" }`. The OpenBao 2.6 storage
documentation lists Filesystem, In-Memory, Integrated Storage (Raft) and
PostgreSQL only.

**Impact.** `server.ha.enabled: true` without `raft.enabled: true` produces
a server that cannot start. `docs/installation.md` and `docs/architecture.md`
describe this as a supported "HA with Consul" mode.

**Workaround.** Override `server.ha.config` with a PostgreSQL config
([09-deployment-modes.md §5](09-deployment-modes.md#5-ha-with-external-storage)).

**Suggested fix.** Replace the default with a PostgreSQL example that reads
`BAO_PG_CONNECTION_URL`, or make `ha.raft.enabled: true` the default when
`ha.enabled` is set. Update the older documents.

---

## 3. `examples/dev.yaml` enabled TLS with empty certificates (fixed)

**Status.** Fixed in the examples rewrite: `examples/dev.yaml` now sets
`global.tlsDisable: true` and has no `server.tls` block.
`test/unit/examples.bats` checks that it renders without TLS objects.

**Evidence (previous version).** The file set `global.tlsDisable: false`,
`server.tls.source: rawCerts`, and PEM blocks that contained only the
`BEGIN`/`END` lines, while the comment above said "keep TLS disabled".

**Impact (previous version).** The chart rendered, the Secret was created,
and the server failed to load the certificate.

---

## 4. Missing `ca.crt` breaks the readiness probe

**Evidence.** When TLS is on, `BAO_CACERT` is always set to
`<mountPath>/<caKey>` (`server-statefulset.yaml`). The exec readiness probe
runs `bao status` without `-tls-skip-verify`. With `rawCerts` the `ca` value
is optional; with `existingSecret` the Secret may have no `ca.crt`.

**Impact.** The pod never becomes Ready. The dev bootstrap script also uses
`bao status`/`bao operator init` without `-tls-skip-verify` when TLS is on,
so dev mode never initializes.

**Workaround.** Always provide the CA, or switch the readiness probe to
`httpGet` with `server.readinessProbe.path`.

**Suggested fix.** Set `BAO_CACERT` only when a CA is known to exist, or
fail the render when `rawCerts` has no `ca`. Alternatively fall back to the
server certificate as the CA for self-signed setups.

---

## 5. Raft `retry_join` hard-coded, no CA

**Evidence.** `server.ha.raft.config` contains exactly three `retry_join`
blocks for pods `-0`, `-1`, `-2`, with `leader_api_addr` only.

**Impact.**

- With `replicas` other than 3, the list does not match the cluster.
  `docs` and profiles do not mention this.
- With TLS and a private CA, joins can fail with `x509` errors because no
  `leader_ca_cert_file` is set (verify).

**Workaround.** Use the generated config from
[12-advanced.md §1.4](12-advanced.md#14-a-reusable-raft-template).

**Suggested fix.** Generate the blocks with `range until (int
.Values.server.ha.replicas)` and add `leader_ca_cert_file` when TLS is on.

---

## 6. Snapshot agent mounts a non-existent TLS Secret in external mode

**Evidence.** `snapshotagent-cronjob.yaml` mounts `<fullname>-tls` whenever
`openbao.tlsEnabled` is true. The TLS objects are not rendered in external
mode.

**Impact.** With `global.externalBaoAddr` and `global.tlsDisable: false`,
the CronJob pods stay in `ContainerCreating`.

**Workaround.** Keep `global.tlsDisable: true` in external mode and mount the
CA through `snapshotAgent.extraVolumes` / `extraVolumeMounts` with
`BAO_CACERT` in `extraEnvironmentVars`.

**Suggested fix.** Mount the TLS Secret only when the mode is not
`external`, or add a `snapshotAgent.caSecret` value.

---

## 7. `snapshotAgent.config.baoAddr` ignored

**Evidence.** `test/acceptance/snapshot.bats` sets
`snapshotAgent.config.baoAddr`. `snapshotagent-configmap.yaml` computes
`BAO_ADDR` itself and never reads it. The value is not in `values.yaml` or
the schema.

**Impact.** Users following the test get a different address than
expected.

**Workaround.** `snapshotAgent.extraEnvironmentVars.BAO_ADDR`.

**Suggested fix.** Use `config.baoAddr` when set, and declare it in
`values.yaml` and the schema.

---

## 8. Snapshot CronJob options missing

**Evidence.** `snapshotagent-cronjob.yaml` has no `imagePullSecrets`,
`concurrencyPolicy`, `startingDeadlineSeconds`, history limits, `nodeSelector`
or `affinity`. The image has no `registry` or `pullPolicy` value.

**Impact.** Private registries need a ServiceAccount patch; slow uploads can
overlap; jobs cannot be pinned to nodes.

**Workaround.** See [11-backup-snapshot-agent.md §6.4](11-backup-snapshot-agent.md#64-avoid-overlapping-runs).

**Suggested fix.** Add the fields with sensible defaults
(`concurrencyPolicy: Forbid`) and reuse the `imagePullSecrets` helper.

---

## 9. Default `s3Host` names a non-existent region

**Evidence.** `snapshotAgent.config.s3Host: s3.eu-east-1.amazonaws.com`.
AWS has no `eu-east-1` region.

**Suggested fix.** Use an empty default and fail the render when the agent
is enabled without `s3Host`, or use `s3.amazonaws.com`.

---

## 10. TLSRoute `apiVersion` default

**Evidence.** `server.gateway.tlsRoute.apiVersion:
gateway.networking.k8s.io/v1`. TLSRoute is in the experimental channel and
is served as `v1alpha2` (and `v1alpha3` in newer releases) in most Gateway
API versions. `charts/openbao/README.md` and `docs/installation.md` say
`v1alpha3`.

**Impact.** Enabling the TLSRoute fails the render with "not served by this
cluster" on most clusters.

**Suggested fix.** Default to the version the supported Gateway API release
serves, and align the README.

---

## 11. BackendTLSPolicy validation

**Evidence.** `server-backendtlspolicy.yaml` defaults
`caCertificateRefs` to `kind: Secret` and always appends `hostname:
<fullname>` after the `validation` block, also when the user provides
`validation`.

**Impact.** Implementations are only required to support `ConfigMap` CA
references, so the default may be rejected. A user `validation` with its own
`hostname` produces a duplicate key.

**Suggested fix.** Default to a ConfigMap, or document the requirement;
render `hostname` only when `validation.hostname` is not set.

---

## 12. `httpRoute.matches.timeouts` not rendered

**Evidence.** Declared in `values.yaml` and the schema; the template renders
only `matches.path` and `filters`.

**Suggested fix.** Render `timeouts` on the rule (`rules[].timeouts`), which
is where the Gateway API expects it.

---

## 13. PDB `maxUnavailable: 0` treated as unset

**Evidence.** `openbao.pdb.maxUnavailable` uses
`else if .Values.server.ha.disruptionBudget.maxUnavailable`, and `0` is
false in Go templates. `values.yaml` sets `0` and the comment says it
defaults to `(n/2)-1`. The schema allows `null` or an integer.

**Impact.** The documented default (`0` in values) is not what is applied;
`0` cannot be used to block evictions.

**Suggested fix.** Default to `null` in `values.yaml` and check with
`kindIs "invalid"` / `hasKey` instead of truthiness.

---

## 14. NetworkPolicy without namespace

**Evidence.** `server-network-policy.yaml` has no `metadata.namespace`,
unlike every other namespaced template.

**Impact.** With `global.namespace` set to a different namespace than
`-n`, the policy is created in the wrong namespace and protects nothing.

**Suggested fix.** Add `namespace: {{ include "openbao.namespace" . }}`.

---

## 15. Route template does not compute `.mode`

**Evidence.** `server-route.yaml` reads `.mode` but does not call
`{{ template "openbao.mode" . }}`, unlike the other templates.

**Impact.** The behavior depends on whether another template set `.mode` on
the shared context earlier (verify). If it is empty, the HA check fails and
the Route targets `<fullname>` instead of `<fullname>-active`; the
`external` check also fails.

**Suggested fix.** Add `{{ template "openbao.mode" . }}` at the top.

---

## 16. Grafana `extraLabel` vs `extraLabels`

**Evidence.** `values.yaml` and the schema declare
`serverTelemetry.grafanaDashboard.extraLabel`; the template reads
`extraLabels`.

**Workaround.** Use `extraLabels`.

**Suggested fix.** Rename the value to `extraLabels` (and accept the old name
for compatibility).

---

## 17. `extraObjects` not rendered

**Evidence.** Declared in `values.yaml`, the schema and the README, with
examples. No template renders it (upstream has `extra-objects.yaml`).

**Suggested fix.** Add the template:

```gotemplate
{{- range .Values.extraObjects }}
---
{{ tpl (ternary . (toYaml .) (typeIs "string" .)) $ }}
{{- end }}
```

---

## 18. Values used by templates but not declared

| Value | Used in |
|-------|---------|
| `nameOverride`, `fullnameOverride` | `_helpers.tpl` |
| `ARTIFACT_DESCRIPTOR_VERSION` | StatefulSet label |
| `deployDescriptor` | `find_image` |
| `server.uid`, `server.gid` | server security context |
| `snapshotAgent.uid`, `snapshotAgent.gid` | snapshot security context |
| `server.service.type`, `clusterIP`, `nodePort`, `activeNodePort`, `standbyNodePort` | Services (only in comments) |
| `ui.loadBalancerIP`, `ui.loadBalancerSourceRanges` | UI Service (only in comments) |
| `serverTelemetry.grafanaDashboard.extraLabels` | dashboard ConfigMap |

**Suggested fix.** Declare them with defaults and descriptions, and add
them to the schema.

---

## 19. Checksum annotation keys differ

**Evidence.** With `server.configAnnotation: true`, the pod gets
`openbao.hashicorp.com/config-checksum` and the ConfigMap gets
`vault.hashicorp.com/config-checksum`. The comment in `values.yaml` names
`vaultproject.io/config-checksum`.

**Suggested fix.** Use one key, for example `openbao.org/config-checksum`,
on both objects and in the comment.

---

## 20. Schema checks TLS source requirements when TLS is off

**Evidence.** The `allOf` rules in `values.schema.json` require `certs.crt`
and `certs.key` for `source: rawCerts` and `secretName` for `existingSecret`
regardless of `global.tlsDisable`. The template validation, by contrast,
fails when TLS material is set while TLS is off.

**Impact.** You cannot preset `source: rawCerts` for later. Combined with
rule 1 of `openbao.tls.validate`, `source: rawCerts` and `existingSecret`
can only be set in the same change that enables TLS.

**Suggested fix.** Make the schema rules conditional on the template
validation alone, or document the behavior (done in
[07-tls.md §2](07-tls.md#2-render-time-validation)).

---

## 21. `large.yaml` profile is standalone

**Evidence.** `resource-profiles/large.yaml` sets only `dev_mode.enabled:
false` and resources. `docs/installation.md` describes the large profile as
"HA, high load" with 3 replicas and 20Gi each.

**Suggested fix.** Add `ha.enabled`, `ha.raft.enabled`, `replicas: 3`, the PDB
and `dataStorage.size: 20Gi` to the profile, or correct the document.

---

## 22. Container security context does not drop capabilities

**Evidence.** The default server container security context is only
`allowPrivilegeEscalation: false`. The snapshot agent default additionally
drops all capabilities.

**Impact.** Pods are rejected in namespaces that enforce the `restricted`
Pod Security Standard.

**Suggested fix.** Add `capabilities: { drop: [ALL] }` to the server
default.

---

## 23. Discovery Role scope

**Evidence.** `server-discovery-role.yaml` grants `get`, `watch`, `list`,
`update`, `patch` on all `pods` in the namespace.

**Impact.** A compromised OpenBao pod can relabel or modify other pods in
the namespace. This is the same as upstream.

**Suggested fix.** Document running OpenBao in a dedicated namespace (done in
[08-security-and-rbac.md §3](08-security-and-rbac.md#3-service-discovery-rbac)).
Kubernetes RBAC cannot restrict by label, so a code change is not possible.

---

## 24. Ingress rendered on OpenShift

**Evidence.** The `values.yaml` comment says the ingress block is ignored on
OpenShift. `server-ingress.yaml` does not check `global.openshift`.

**Suggested fix.** Update the comment, or skip the Ingress when
`global.openshift` is true.

---

## 25. Version numbers differ

| Source | Version |
|--------|---------|
| `Chart.yaml` | `appVersion: v2.6.2` |
| `values.yaml` | `server.image.tag: "2.6.2"` |
| `charts/openbao/README.md` | badge `v2.5.4`, `server.image.tag` `""` |
| `docs/configuration.md` | `server.image.tag` `"2.5"` |

**Suggested fix.** Regenerate the README with `helm-docs` and update
`configuration.md`.

---

## 26. Older documents are out of date

`docs/installation.md` and `docs/architecture.md`:

- describe "HA with Consul" as supported ([#2](#2-default-ha-config-uses-consul));
- list the Consul install command;
- say TLSRoute uses `v1alpha3` ([#10](#10-tlsroute-apiversion-default));
- describe the large profile as HA ([#21](#21-largeyaml-profile-is-standalone));
- say the snapshot agent calls the client Service (it calls `-active` in
  HA).

**Suggested fix.** Replace the detailed parts with links to `docs/chart/`.

---

## 27. Unit tests use upstream value names

**Evidence.** `test/unit/server-dev-statefulset.bats` sets
`server.dev.enabled` (not `server.dev_mode.enabled`), expects
`VAULT_DEV_LISTEN_ADDRESS`, and expects no `volumeClaimTemplates` in dev
mode. This distribution renders a PVC in dev mode and sets no such variable.
Tests for the injector and CSI provider remain although those components
are not deployed.

**Impact.** The unit test suite does not describe the current behavior and
likely fails.

**Suggested fix.** Update or remove the tests; add tests for the behavior
documented here (mode resolution, TLS validation, dev bootstrap).

---

## 28. Service type and cluster IP only in comments

**Evidence.** `server.service.type` and `server.service.clusterIP` are
commented out in `values.yaml`. The comment says the type "can be ClusterIP
or NodePort", but the template passes any value through, including
`LoadBalancer`.

**Suggested fix.** Declare them (`type: ClusterIP`, `clusterIP: ""`) and
update the comment.
