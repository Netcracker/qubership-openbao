[[_TOC_]]

## OpenBao Helm Chart Parameters

Ready-made value files are provided in the [examples](/examples) directory. The
full, auto-generated values table lives in
[`charts/openbao/README.md`](/charts/openbao/README.md); the table below covers
the most commonly used parameters.

| Key | Description | Default Value |
|-----|-------------|---------------|
| `global.enabled` | Master switch enabling/disabling all chart components | `true` |
| `global.namespace` | Namespace to deploy to (defaults to the Helm namespace) | `""` |
| `global.imagePullSecrets` | Image pull secrets for private registries | `[]` |
| `global.tlsDisable` | Disable end-to-end TLS transport (set `false` to enable TLS) | `true` |
| `global.externalBaoAddr` | External OpenBao address; setting it disables the server (external mode) | `""` |
| `global.openshift` | Deploy to OpenShift (use `server.route` for exposure) | `false` |
| `global.psp.enable` | Create a PodSecurityPolicy for pods | `false` |
| `global.serverTelemetry.prometheusOperator` | Enable Prometheus Operator integration | `false` |
| `server.enabled` | Install the OpenBao server (`"-"` follows `global.enabled`) | `"-"` |
| `server.image.registry` | Server image registry | `"quay.io"` |
| `server.image.repository` | Server image repository | `"quay.io/openbao/openbao"` |
| `server.image.tag` | Server image tag | `"2.5"` |
| `server.image.pullPolicy` | Server image pull policy | `IfNotPresent` |
| `server.updateStrategyType` | StatefulSet update strategy | `"OnDelete"` |
| `server.podManagementPolicy` | StatefulSet pod management policy | `"OrderedReady"` |
| `server.logLevel` | Server log level (trace/debug/info/warn/error) | `""` |
| `server.logFormat` | Server log format (standard/json) | `""` |
| `server.resources` | Resource requests/limits for server pods | `{}` |
| `server.configAnnotation` | Add a config-checksum annotation to trigger rollout on config change | `false` |
| `server.ingress.enabled` | Create a Kubernetes Ingress | `false` |
| `server.route.enabled` | Create an OpenShift Route (OpenShift only) | `false` |
| `server.route.tls.termination` | OpenShift Route TLS termination | `passthrough` |
| `server.gateway.httpRoute.enabled` | Create a Gateway API HTTPRoute | `false` |
| `server.gateway.tlsRoute.enabled` | Create a Gateway API TLSRoute (passthrough) | `false` |
| `server.gateway.tlsPolicy.enabled` | Create a Gateway API BackendTLSPolicy (re-encrypt) | `false` |
| `server.authDelegator.enabled` | Bind `system:auth-delegator` for Kubernetes auth | `true` |
| `server.tls.source` | TLS certificate source: `certManager`, `rawCerts`, `existingSecret` | `certManager` |
| `server.tls.secretName` | Name of the TLS secret (defaults to `<fullname>-tls`) | `""` |
| `server.tls.tlsMinVersion` | Minimum TLS version (tls10/tls11/tls12/tls13) | `tls12` |
| `server.tls.certManager.generateIssuer` | Chart creates a self-signed Issuer | `false` |
| `server.tls.certManager.clusterIssuerName` | Use an existing ClusterIssuer | `""` |
| `server.service.enabled` | Create the client Service | `true` |
| `server.service.port` | Client Service port | `8200` |
| `server.dataStorage.enabled` | Create the data PVC (file/raft backends) | `true` |
| `server.dataStorage.size` | Data PVC size | `10Gi` |
| `server.dataStorage.mountPath` | Data mount path | `/openbao/data` |
| `server.dataStorage.storageClass` | Data PVC StorageClass (null = default) | `null` |
| `server.auditStorage.enabled` | Create the audit-log PVC | `false` |
| `server.auditStorage.size` | Audit PVC size | `10Gi` |
| `server.dev_mode.enabled` | Run in persistent dev mode (file backend on the data PVC, auto-init/auto-unseal) — shipped default | `true` |
| `server.dev_mode.sealToken` | Static unseal key stored in `bao-static-unseal-key` (random if empty) | `""` |
| `server.dev_mode.devRootToken` | Root token used by the dev bootstrap | `"root"` |
| `server.dev_mode.config` | HCL config for the persistent dev server (file backend) | *(multi-line)* |
| `server.standalone.enabled` | Run in standalone mode (file backend) | `"-"` |
| `server.ha.enabled` | Run in HA mode | `false` |
| `server.ha.replicas` | HA replica count | `3` |
| `server.ha.raft.enabled` | Use integrated Raft storage in HA | `false` |
| `server.ha.disruptionBudget.enabled` | Create a PodDisruptionBudget in HA | `true` |
| `server.serviceAccount.create` | Create a ServiceAccount for the server | `true` |
| `ui.enabled` | Enable the OpenBao web UI service | `false` |
| `ui.serviceType` | UI Service type (ClusterIP/NodePort/LoadBalancer) | `"ClusterIP"` |
| `ui.externalPort` | UI Service port | `8200` |
| `serverTelemetry.serviceMonitor.enabled` | Create a Prometheus ServiceMonitor | `false` |
| `serverTelemetry.prometheusRules.enabled` | Create PrometheusRule alerts | `false` |
| `serverTelemetry.grafanaDashboard.enabled` | Create the Grafana dashboard ConfigMap | `false` |
| `snapshotAgent.enabled` | Enable the Raft snapshot backup CronJob | `false` |
| `snapshotAgent.schedule` | Snapshot CronJob schedule | `"*/15 * * * *"` |

## End-to-end TLS

By default the chart deploys OpenBao with TLS disabled (`global.tlsDisable: true`)
and the server listener uses plain HTTP. This section describes how to enable
end-to-end TLS so that:

- the server listener serves HTTPS (`tls_cert_file` / `tls_key_file`);
- a minimum TLS version (and optionally cipher suites) is enforced;
- in-cluster clients and the readiness/liveness probes verify the server
  certificate against the CA (`BAO_CACERT`), instead of skipping verification;
- HA / Raft peer and replication traffic (ports `8201` / `8202`) run over TLS;
- the Prometheus `ServiceMonitor` and the snapshot agent trust the same CA.

TLS is turned on by setting `global.tlsDisable: false`. The server certificate
is provisioned through one of three sources selected by `server.tls.source`:

| `server.tls.source` | Behaviour |
| ------------------- | --------- |
| `certManager` (default) | The chart creates a cert-manager `Certificate` resource. It can also bootstrap its own self-signed `Issuer` (`certManager.generateIssuer: true`) or use a `ClusterIssuer` (`certManager.clusterIssuerName`). Requires cert-manager in the cluster. |
| `rawCerts` | You supply the certificate and key inline via `server.tls.certs.crt` / `server.tls.certs.key` (optionally `certs.ca`); the chart creates a `kubernetes.io/tls` secret from them via Helm hooks. |
| `existingSecret` | You supply a pre-created `kubernetes.io/tls` secret (with `tls.crt`, `tls.key`, `ca.crt`). Set `server.tls.secretName`. |

In every mode the resulting secret is named `<release>-openbao-tls` by default (or
`server.tls.secretName` when set) and is mounted into the server pod at
`server.tls.mountPath` (default `/openbao/tls`).

### Option A: cert-manager (recommended)

Prerequisites: [cert-manager](https://cert-manager.io/) is installed.

The simplest setup lets the chart create its own self-signed `Issuer`
(mirroring the seaweedfs pattern), so no `Issuer`/`ClusterIssuer` has to be
created by hand:

```yaml
global:
  tlsDisable: false

server:
  tls:
    source: certManager
    certManager:
      generateIssuer: true      # chart creates <release>-openbao-issuer (selfSigned)
      durationDays: 365
```

To sign with an existing cluster-wide issuer instead, set
`clusterIssuerName` (it takes precedence over `generateIssuer` and `issuerRef`):

```yaml
server:
  tls:
    source: certManager
    certManager:
      clusterIssuerName: my-cluster-ca
```

Or reference a namespaced `Issuer`/`ClusterIssuer` you manage yourself (the
original behaviour) by leaving both `generateIssuer` and `clusterIssuerName`
unset and configuring `issuerRef`:

```yaml
server:
  tls:
    source: certManager
    certManager:
      issuerRef:
        name: openbao-ca-issuer
        kind: Issuer
```

A minimal self-signed CA issuer for the `issuerRef` approach:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-ca
spec:
  isCA: true
  commonName: openbao-ca
  secretName: openbao-ca-tls
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: Issuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openbao-ca-issuer
spec:
  ca:
    secretName: openbao-ca-tls
```

The certificate duration is taken from `certManager.duration` when set,
otherwise from `certManager.durationDays` (`durationDays * 24h`, seaweedfs
convention). Extra SANs can be supplied either via `certManager.extraSans` /
`certManager.extraIpSans` (lists) or the seaweedfs-compatible
`certManager.subjectAlternativeName.additionalDnsNames` /
`additionalIpAddresses`; all of them are merged into the certificate.

```yaml
global:
  tlsDisable: false

server:
  tls:
    source: certManager
    tlsMinVersion: tls12
    certManager:
      generateIssuer: true
      durationDays: 365
      renewBefore: 720h
      # Extra SANs (e.g. an ingress hostname):
      extraSans:
        - vault.example.com
      subjectAlternativeName:
        additionalDnsNames:
          - vault.internal.example.com
```

The chart creates a `Certificate` named `<release>-openbao-tls` whose SANs
already cover the client service, the headless `-internal` service, per-pod
wildcard DNS (needed for HA/Raft), and — in HA mode — the active/standby
services. cert-manager writes the signed material into the secret
`<release>-openbao-tls`, which the chart mounts into the server pod at
`server.tls.mountPath` (default `/openbao/tls`).

> Note on the private key: OpenBao defaults to `ECDSA`/`256`, which is a
> deliberate deviation from the seaweedfs chart (RSA 2048). Set
> `server.tls.certManager.privateKey` to `{algorithm: RSA, encoding: PKCS1,
> size: 2048}` if strict parity with seaweedfs is required.

### Option B: inline certificate (rawCerts)

Supply PEM material directly. The chart creates a `kubernetes.io/tls` secret
(via Helm `pre-install`/`pre-upgrade` hooks) named `<release>-openbao-tls`:

```yaml
global:
  tlsDisable: false

server:
  tls:
    source: rawCerts
    certs:
      crt: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
      key: |
        -----BEGIN PRIVATE KEY-----
        ...
        -----END PRIVATE KEY-----
      # Optional: provide the CA so BAO_CACERT/probes/metrics can verify it.
      ca: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
```

If `certs.ca` is omitted, there is no `ca.crt` for verification; set
`serverTelemetry.serviceMonitor.insecureSkipVerify: true` for metrics scraping
in that case.

### Option C: existing secret

If you manage certificates yourself, create a `kubernetes.io/tls` secret that
also carries the CA under `ca.crt`, and reference it:

```yaml
global:
  tlsDisable: false

server:
  tls:
    source: existingSecret
    secretName: my-openbao-tls
    # Adjust these if your secret uses different keys:
    certKey: tls.crt
    keyKey: tls.key
    caKey: ca.crt
```

In this mode the chart does **not** create a cert-manager `Certificate` or a
secret; it only mounts the existing secret and wires up `BAO_CACERT`.

### Gateway API: re-encrypt vs passthrough

When exposing OpenBao through the Gateway API, the two TLS termination modes
follow the same convention as seaweedfs:

- **Re-encrypt** — the gateway terminates the client TLS and opens a fresh TLS
  connection to the pod. Enable it with `server.gateway.tlsPolicy.enabled: true`
  (a `BackendTLSPolicy` is created). By default the policy validates the pod
  certificate against the CA in the chart's TLS secret (`<release>-openbao-tls`,
  key `ca.crt`); override with `server.gateway.tlsPolicy.validation`. Use this
  with `source: certManager`.

  ```text
  Client ---HTTPS---> Gateway API ---HTTPS---> Pod
  ```

- **Passthrough** — the gateway forwards the encrypted stream unchanged and
  OpenBao terminates TLS. Enable it with `server.gateway.tlsRoute.enabled: true`
  (a `TLSRoute` is created). Use this with `source: rawCerts` or
  `existingSecret`.

  ```text
  Client ---HTTPS---> Pod
  ```

Both resources are only rendered when the corresponding Gateway API CRD
(`TLSRoute` / `BackendTLSPolicy`) is installed in the cluster.


### TLS version and cipher suites

```yaml
server:
  tls:
    tlsMinVersion: tls12          # tls10 | tls11 | tls12 | tls13
    tlsCipherSuites: ""           # comma-separated Go/OpenSSL names, TLS 1.2 only
```

`tls_min_version` is rendered into every listener block (standalone, HA and
Raft). `tls_cipher_suites` is only emitted when set and only affects TLS 1.2;
TLS 1.3 cipher suites are fixed by the runtime.

### Metrics scraping

When TLS is enabled and `serverTelemetry.serviceMonitor.tlsConfig` is left
empty, the `ServiceMonitor` verifies the metrics endpoint against the server
CA (from the TLS secret) using the release name as `serverName`. Set
`serverTelemetry.serviceMonitor.insecureSkipVerify: true` to skip verification,
or provide a full `tlsConfig` to override completely.

### Certificate rotation

With cert-manager, rotation is automatic based on `duration` / `renewBefore`.
cert-manager updates the TLS secret in place; OpenBao reloads the certificate
on the next handshake. The requested certificate `privateKey.rotationPolicy`
defaults to `Always`, so each renewal produces a fresh key.

### Enabling TLS on an existing release (rollout)

Switching `global.tlsDisable` from `true` to `false` on an already-installed
release changes both the server ConfigMap (the listener starts serving HTTPS)
and the pod template (the TLS secret is mounted and `BAO_CACERT` is set).

The chart defaults to `server.updateStrategyType: OnDelete` and
`server.configAnnotation: false`. With those defaults the StatefulSet controller
does **not** restart running pods automatically and there is no config-checksum
annotation to trigger a rollout, so the running pods keep serving plaintext
until they are recreated — while clients, probes and metrics have already been
reconfigured for HTTPS. This leaves the release in an inconsistent state.

When enabling (or disabling) TLS on an existing release, force a rolling
restart of the server pods, using one of:

- delete the pods one by one so each restarts with the new config:
  `kubectl delete pod <release>-openbao-0` (repeat per replica); or
- set `server.configAnnotation: true` so a config-checksum annotation change
  can drive pod recreation; and/or
- set `server.updateStrategyType: RollingUpdate` for an automatic rollout.

Fresh installs are unaffected: the pods come up with TLS already configured.

