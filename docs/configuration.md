# Configuration

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
is provisioned through one of two sources selected by `server.tls.source`:

| `server.tls.source` | Behaviour |
| ------------------- | --------- |
| `certManager` (default) | The chart creates a cert-manager `Certificate` resource. Requires cert-manager in the cluster. |
| `existingSecret` | You supply a pre-created `kubernetes.io/tls` secret (with `tls.crt`, `tls.key`, `ca.crt`). Set `server.tls.secretName`. |

### Option A: cert-manager (recommended)

Prerequisites: [cert-manager](https://cert-manager.io/) is installed and an
`Issuer`/`ClusterIssuer` capable of signing server certificates exists.

A minimal self-signed CA issuer for testing:

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

Then install the chart with TLS enabled:

```yaml
global:
  tlsDisable: false

server:
  tls:
    source: certManager
    tlsMinVersion: tls12
    certManager:
      issuerRef:
        name: openbao-ca-issuer
        kind: Issuer
      duration: 8760h
      renewBefore: 720h
      # Extra SANs (e.g. an ingress hostname):
      extraSans:
        - vault.example.com
```

The chart creates a `Certificate` named `<release>-openbao-tls` whose SANs
already cover the client service, the headless `-internal` service, per-pod
wildcard DNS (needed for HA/Raft), and — in HA mode — the active/standby
services. cert-manager writes the signed material into the secret
`<release>-openbao-tls`, which the chart mounts into the server pod at
`server.tls.mountPath` (default `/openbao/tls`).

### Option B: existing secret

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

In this mode the chart does **not** create a cert-manager `Certificate`; it only
mounts the secret and wires up `BAO_CACERT`.

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

