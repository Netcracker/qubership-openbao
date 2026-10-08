# Services and External Access

This document covers the in-cluster Services and every way to expose OpenBao
outside the cluster: the UI Service, Ingress, the OpenShift Route and the
Gateway API.

- [1. Service topology](#1-service-topology)
- [2. `server.service`](#2-serverservice)
- [3. UI Service](#3-ui-service)
- [4. Ingress](#4-ingress)
- [5. OpenShift Route](#5-openshift-route)
- [6. Gateway API](#6-gateway-api)
- [7. Choosing an exposure method](#7-choosing-an-exposure-method)

> Examples in this document have not yet been checked with `helm template`.

---

## 1. Service topology

| Service | Template | Mode | Selector (in addition to `app.kubernetes.io/name`, `component: server`) | Use it for |
|---------|----------|------|----------------------------------------------------------------------------|------------|
| `<fullname>` | `server-service.yaml` | standalone, ha | `instance` (if `instanceSelector.enabled`) | Clients in standalone; any node in HA (standbys forward to the leader) |
| `<fullname>-internal` | `server-headless-service.yaml` | standalone, ha | `instance` (always) | Stable pod DNS, Raft `retry_join`, `cluster_addr`. Headless (`clusterIP: None`) |
| `<fullname>-active` | `server-ha-active-service.yaml` | ha | `instance`, `openbao-active: "true"` | Clients in HA, Ingress, Gateway, Route, snapshot agent, metrics |
| `<fullname>-standby` | `server-ha-standby-service.yaml` | ha | `instance`, `openbao-active: "false"` | Read-heavy clients that tolerate forwarding |
| `<fullname>-ui` | `ui-service.yaml` | standalone, ha | `instance`; plus `openbao-active: "true"` if `ui.activeOpenbaoPodOnly` in HA | A separate, optionally external, Service for the UI |

All Services expose port `server.service.port` (default `8200`, named `http`
or `https`) and port `8201` (`https-internal`). The UI Service exposes only
`ui.externalPort`.

OpenBao sets the `openbao-active` label on its own pod at runtime through
`service_registration "kubernetes"`. The label exists only after the pod is
**unsealed**. Until then the active and standby Services have no endpoints.

In-cluster DNS names, for release `openbao` in namespace `openbao`:

```text
openbao.openbao.svc:8200                     # client
openbao-active.openbao.svc:8200              # HA leader
openbao-0.openbao-internal.openbao.svc:8200  # specific pod
```

---

## 2. `server.service`

### Switches

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.service.enabled` | bool | `true` | Disables **all** server Services (client, headless, active, standby) when `false` |
| `server.service.active.enabled` | bool | `true` | Active Service (HA only) |
| `server.service.standby.enabled` | bool | `true` | Standby Service (HA only) |
| `server.service.instanceSelector.enabled` | bool | `true` | Adds `app.kubernetes.io/instance` to the client, active and standby selectors |

> Do not set `server.service.enabled: false` in HA with Raft. The headless
> Service disappears, so `retry_join` and `BAO_CLUSTER_ADDR` cannot resolve.
> Ingress, Gateway routes and BackendTLSPolicy are not rendered either,
> because they require `serverServiceEnabled`.

### Type and addressing

| Key | Type | Default | Applies to |
|-----|------|---------|------------|
| `server.service.type` | string | *(unset, so `ClusterIP`)* | client, active, standby |
| `server.service.clusterIP` | string | *(unset)* | client, active, standby. `None` makes them headless |
| `server.service.ipFamilyPolicy` | string | `""` | all four. `SingleStack`, `PreferDualStack`, `RequireDualStack` |
| `server.service.ipFamilies` | list | `[]` | all four. `IPv4`, `IPv6` |
| `server.service.publishNotReadyAddresses` | bool | `true` | client, active, standby. The headless Service always uses `true` |
| `server.service.externalTrafficPolicy` | string | `Cluster` | client, active, standby. Rendered only for `NodePort` or `LoadBalancer` |

`type` and `clusterIP` are commented out in `values.yaml`. Set them
explicitly when you need them. `values.yaml` mentions only `ClusterIP` and
`NodePort`, but the template passes any value through, so `LoadBalancer`
works too.

### Ports

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.service.port` | int | `8200` | Service port |
| `server.service.targetPort` | int | `8200` | Container port |
| `server.service.nodePort` | int | *(unset)* | Client Service `nodePort` when `type: NodePort` |
| `server.service.activeNodePort` | int | *(unset)* | Active Service `nodePort` when `type: NodePort` |
| `server.service.standbyNodePort` | int | *(unset)* | Standby Service `nodePort` when `type: NodePort` |
| `server.service.extraPorts` | list | `[]` | Extra ports on client, active and standby |

The listener in the HCL always binds `8200`. Change `targetPort` only if you
also change the listener `address` in your config.

### Annotations and labels

| Key | Applies to |
|-----|------------|
| `server.service.annotations` | client, and **merged into** active, standby and headless |
| `server.service.active.annotations` | active |
| `server.service.standby.annotations` | standby |
| `server.service.headless.annotations` | headless |
| `server.service.extraLabels` | client |
| `server.service.active.extraLabels` | active |
| `server.service.standby.extraLabels` | standby |

For active, standby and headless, the specific annotations are rendered
first and the generic ones after. If both define the same key, the generic
value wins, because the later YAML key overrides the earlier one.

### Examples

NodePort for a lab cluster:

```yaml
server:
  service:
    type: NodePort
    nodePort: 30200
    activeNodePort: 30201
    standbyNodePort: 30202
```

Internal load balancer for the HA leader (cloud-specific annotation):

```yaml
server:
  service:
    type: LoadBalancer
    active:
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

All three Services (client, active, standby) get `type: LoadBalancer`. Set
`standby.enabled: false` to avoid a third load balancer.

Dual-stack:

```yaml
server:
  service:
    ipFamilyPolicy: PreferDualStack
    ipFamilies: [IPv4, IPv6]
```

The listener `address = "[::]:8200"` already accepts both families.

---

## 3. UI Service

The web UI is served by the server on the API port whenever the HCL contains
`ui = true` (the default). `ui.enabled` only creates the additional
`<fullname>-ui` Service.

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `ui.enabled` | bool or `"-"` | `false` | Create the UI Service |
| `ui.serviceType` | string | `ClusterIP` | `ClusterIP`, `NodePort` or `LoadBalancer` |
| `ui.serviceNodePort` | int or null | `null` | `nodePort` |
| `ui.externalPort` | int | `8200` | Service port |
| `ui.targetPort` | int | `8200` | Container port |
| `ui.activeOpenbaoPodOnly` | bool | `false` | In HA, select only the active pod |
| `ui.publishNotReadyAddresses` | bool | `true` | Include sealed or not-ready pods |
| `ui.serviceIPFamilyPolicy` | string | `""` | Dual-stack policy |
| `ui.serviceIPFamilies` | list | `[]` | Dual-stack families |
| `ui.externalTrafficPolicy` | string | `Cluster` | For `NodePort` and `LoadBalancer` |
| `ui.loadBalancerIP` | string | *(unset)* | For `LoadBalancer` |
| `ui.loadBalancerSourceRanges` | list | *(unset)* | For `LoadBalancer`. Allowed client CIDRs |
| `ui.annotations` | map or string (tpl) | `{}` | Service annotations |
| `ui.extraLabels` | map | `{}` | Service labels |

### Example: restricted load balancer

```yaml
ui:
  enabled: true
  serviceType: LoadBalancer
  externalPort: 443
  activeOpenbaoPodOnly: true
  externalTrafficPolicy: Local
  loadBalancerSourceRanges:
    - 10.0.0.0/8
    - 192.0.2.10/32
```

With `externalPort: 443` and TLS off, browsers would use plain HTTP on port
443. Enable TLS ([07-tls.md](07-tls.md)) when you expose the UI.

`ui.publishNotReadyAddresses: true` lets you reach a sealed server and unseal
it from the UI. Set it to `false` if users should never reach a sealed node.

---

## 4. Ingress

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.ingress.enabled` | bool | `false` | Render the Ingress |
| `server.ingress.ingressClassName` | string | `""` | `spec.ingressClassName` |
| `server.ingress.hosts` | list of `{host, paths}` | `[{host: chart-example.local, paths: []}]` | Rules. Empty `paths` becomes `["/"]` |
| `server.ingress.pathType` | string | `Prefix` | `pathType` for every generated path |
| `server.ingress.extraPaths` | list | `[]` | Raw path entries added before the generated ones, for every host |
| `server.ingress.tls` | list of `{secretName, hosts}` | `[]` | `spec.tls` |
| `server.ingress.activeService` | bool | `true` | In HA, route to `<fullname>-active` instead of `<fullname>` |
| `server.ingress.labels` | map | `{}` | Extra labels |
| `server.ingress.annotations` | map or string (tpl) | `{}` | Annotations |

The Ingress always carries the Netcracker labels
`deployment.netcracker.com/ingress-type: private-network` and
`deployment.netcracker.com/ingress-audience-type: ops-user`.

The backend port is `server.service.port`. The Ingress is rendered only when
`server.service.enabled` is true. On OpenShift it is still rendered if
enabled; use `server.route` there instead.

### Example: NGINX with TLS at the ingress, HTTP to the pod

```yaml
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
    hosts:
      - host: openbao.example.com
    tls:
      - secretName: openbao-ingress-tls
        hosts: [openbao.example.com]
```

### Example: NGINX with backend HTTPS (chart TLS on)

```yaml
global:
  tlsDisable: false
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/backend-protocol: HTTPS
      nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
      nginx.ingress.kubernetes.io/proxy-ssl-secret: openbao/openbao-tls
      nginx.ingress.kubernetes.io/proxy-ssl-name: openbao-active
    hosts:
      - host: openbao.example.com
    tls:
      - secretName: openbao-ingress-tls
        hosts: [openbao.example.com]
```

### Example: TLS passthrough with NGINX

```yaml
global:
  tlsDisable: false
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    hosts:
      - host: openbao.example.com
  tls:
    certManager:
      extraSans: [openbao.example.com]
```

Passthrough requires the controller to run with
`--enable-ssl-passthrough`. TLS certificate authentication works only with
passthrough or with a controller that forwards the client certificate.

---

## 5. OpenShift Route

Rendered only when `global.openshift: true` **and**
`server.route.enabled: true`.

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.route.enabled` | bool | `false` | Render the Route |
| `server.route.host` | string | `chart-example.local` | `spec.host` |
| `server.route.activeService` | bool | `true` | In HA, target `<fullname>-active` |
| `server.route.tls` | map | `{termination: passthrough}` | `spec.tls`, passed through |
| `server.route.labels` | map | `{}` | Extra labels |
| `server.route.annotations` | map or string (tpl) | `{}` | Annotations |

`spec.port.targetPort` is fixed to `8200`.

| `tls.termination` | Chart TLS | Notes |
|-------------------|-----------|-------|
| `passthrough` (default) | must be on | The router forwards TLS. The server certificate must include `route.host` (`certManager.extraSans`) |
| `edge` | off | The router terminates TLS and talks HTTP to the pod |
| `reencrypt` | on | The router terminates TLS and opens a new TLS connection. Supply `destinationCACertificate` |

```yaml
global:
  openshift: true
  tlsDisable: false
server:
  route:
    enabled: true
    host: openbao.apps.example.com
    tls:
      termination: reencrypt
      insecureEdgeTerminationPolicy: Redirect
      destinationCACertificate: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
```

`server-route.yaml` reads `.mode` but does not call `openbao.mode` itself.
It relies on another template having set it (verify). If the Route points at
`<fullname>` instead of `<fullname>-active` in HA, that is the cause.

---

## 6. Gateway API

The chart creates routes only. You provide the `Gateway` and its listeners.
Each resource checks at render time that its CRD is served by the cluster,
using `.Capabilities.APIVersions`:

```text
server.gateway.tlsRoute.enabled=true, but gateway.networking.k8s.io/v1/TLSRoute
is not served by this cluster. Install the Gateway API channel that provides
TLSRoute, or set server.gateway.tlsRoute.apiVersion to a version this cluster
serves.
```

`helm template` without `--api-versions` has no cluster access, so this
check fails. Pass the API explicitly when you render offline:

```bash
helm template openbao ./charts/openbao -f values.yaml \
  --api-versions gateway.networking.k8s.io/v1alpha2/TLSRoute
```

### 6.1 HTTPRoute (TLS terminated at the gateway)

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.gateway.httpRoute.enabled` | bool | `false` | Render the HTTPRoute |
| `server.gateway.httpRoute.apiVersion` | string | `gateway.networking.k8s.io/v1` | API version |
| `server.gateway.httpRoute.parentRefs` | list | `[]` | **Required** when enabled. The render fails if empty |
| `server.gateway.httpRoute.hosts` | list of string | `[chart-example.local]` | `spec.hostnames` |
| `server.gateway.httpRoute.matches.path` | map | `{type: PathPrefix, value: /}` | Path match |
| `server.gateway.httpRoute.matches.timeouts` | map | `{}` | **Not rendered** by the template |
| `server.gateway.httpRoute.filters` | list | `[]` | Rule filters |
| `server.gateway.httpRoute.activeService` | bool | `true` | In HA, target `<fullname>-active` |
| `server.gateway.httpRoute.labels`, `annotations` | map | `{}` | Metadata |

```yaml
server:
  gateway:
    httpRoute:
      enabled: true
      parentRefs:
        - name: public-gw
          namespace: gateway-system
          sectionName: https
      hosts: [openbao.example.com]
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-Forwarded-Proto
                value: https
```

When chart TLS is on and an HTTPRoute is enabled, `NOTES.txt` warns that
terminating TLS before OpenBao can break TLS certificate authentication.
Prefer the TLSRoute.

### 6.2 TLSRoute (passthrough)

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.gateway.tlsRoute.enabled` | bool | `false` | Render the TLSRoute |
| `server.gateway.tlsRoute.apiVersion` | string | `gateway.networking.k8s.io/v1` | API version. Most Gateway API releases serve TLSRoute only as `v1alpha2` or `v1alpha3`; set it to match your cluster |
| `server.gateway.tlsRoute.parentRefs` | list | `[]` | **Required** when enabled |
| `server.gateway.tlsRoute.hosts` | list of string | `[]` | SNI host names |
| `server.gateway.tlsRoute.activeService` | bool | `true` | In HA, target `<fullname>-active` |
| `server.gateway.tlsRoute.labels`, `annotations` | map | `{}` | Metadata |

```yaml
global:
  tlsDisable: false
server:
  tls:
    source: existingSecret
    secretName: openbao-public-tls
  gateway:
    tlsRoute:
      enabled: true
      apiVersion: gateway.networking.k8s.io/v1alpha2
      parentRefs:
        - name: public-gw
          namespace: gateway-system
          sectionName: tls-passthrough   # listener with protocol TLS, mode Passthrough
      hosts: [openbao.example.com]
```

The server certificate must include the public host name.

### 6.3 BackendTLSPolicy (re-encrypt)

Rendered only when `global.tlsDisable: false` **and**
`server.gateway.tlsPolicy.enabled: true`. Use it with an HTTPRoute, so the
gateway opens a verified TLS connection to the pod.

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.gateway.tlsPolicy.enabled` | bool | `false` | Render the policy |
| `server.gateway.tlsPolicy.apiVersion` | string | `gateway.networking.k8s.io/v1` | API version |
| `server.gateway.tlsPolicy.targetRefs` | list | `[]` | Default: the client or active Service, `sectionName: https` |
| `server.gateway.tlsPolicy.validation` | map | `{}` | Default: `caCertificateRefs` to the chart TLS Secret |
| `server.gateway.tlsPolicy.activeService` | bool | `true` | In HA, the default target is `<fullname>-active` |
| `server.gateway.tlsPolicy.labels`, `annotations` | map | `{}` | Metadata |

The template always adds `validation.hostname: <fullname>`. The chart's
cert-manager certificate includes this name.

The default `caCertificateRefs` points at a **Secret**. The Gateway API spec
requires implementations to support only `ConfigMap` references. If your
gateway rejects the Secret, copy the CA to a ConfigMap and override
`validation`:

```bash
kubectl -n openbao create configmap openbao-ca \
  --from-literal=ca.crt="$(kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)"
```

```yaml
global:
  tlsDisable: false
server:
  tls:
    source: certManager
    certManager:
      generateIssuer: true
  gateway:
    httpRoute:
      enabled: true
      parentRefs:
        - name: public-gw
          namespace: gateway-system
      hosts: [openbao.example.com]
    tlsPolicy:
      enabled: true
      validation:
        caCertificateRefs:
          - group: ""
            kind: ConfigMap
            name: openbao-ca
```

If you set `validation`, the template still appends
`hostname: <fullname>`. Do not include `hostname` in your own `validation`
map, or the key appears twice.

---

## 7. Choosing an exposure method

| Method | Where TLS ends | Client cert auth | Chart TLS needed | Requirements |
|--------|----------------|------------------|------------------|--------------|
| `kubectl port-forward` | pod (or none) | yes | no | none |
| UI Service `LoadBalancer` / `NodePort` | pod | yes | recommended | cloud LB or node ports |
| Ingress, TLS at the controller | controller | no | no | Ingress controller |
| Ingress, backend HTTPS | controller, then pod | no | yes | controller support for backend TLS |
| Ingress, SSL passthrough | pod | yes | yes | controller with passthrough |
| OpenShift Route `edge` | router | no | no | OpenShift |
| OpenShift Route `passthrough` | pod | yes | yes | OpenShift |
| OpenShift Route `reencrypt` | router, then pod | no | yes | OpenShift |
| Gateway HTTPRoute | gateway | no | no | Gateway API and a Gateway |
| Gateway HTTPRoute + BackendTLSPolicy | gateway, then pod | no | yes | Gateway API with BackendTLSPolicy |
| Gateway TLSRoute | pod | yes | yes | Gateway API with TLSRoute (experimental channel) |

Recommendations:

- **Production with TLS certificate auth or mTLS:** passthrough (TLSRoute,
  Route `passthrough` or Ingress SSL passthrough).
- **Production behind a corporate gateway:** re-encrypt (HTTPRoute with
  BackendTLSPolicy, Route `reencrypt`, or backend HTTPS on the Ingress).
- **Development:** `kubectl port-forward`.

In HA, every method targets `<fullname>-active` by default (`activeService:
true`), except the UI Service. This avoids an extra forwarding hop and makes
sure clients reach an unsealed leader.
