# Installation

## TLS Configuration

By default the chart deploys OpenBao with TLS disabled (`global.tlsDisable: true`).
Set `global.tlsDisable: false` to enable end-to-end TLS. The server certificate
is provisioned through one of three sources selected by `server.tls.source`:
`certManager`, `rawCerts` or `existingSecret`.

For the full reference (issuers, inline certs, existing secrets, SANs, TLS
version/ciphers, rotation and rollout), see [docs/configuration.md](docs/configuration.md).

### cert-manager (re-encrypt at the gateway)

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

### rawCerts / existingSecret (passthrough at the gateway)

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
