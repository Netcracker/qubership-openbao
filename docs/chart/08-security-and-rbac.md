# Security and RBAC

This document covers the server identity (ServiceAccount), the Kubernetes
RBAC objects the chart creates, pod and container security contexts, and
the NetworkPolicy.

- [1. ServiceAccount](#1-serviceaccount)
- [2. Auth delegator (Kubernetes auth method)](#2-auth-delegator-kubernetes-auth-method)
- [3. Service discovery RBAC](#3-service-discovery-rbac)
- [4. Security contexts](#4-security-contexts)
- [5. NetworkPolicy](#5-networkpolicy)
- [6. Hardening checklist](#6-hardening-checklist)

> Examples in this document have not yet been checked with `helm template`.

---

## 1. ServiceAccount

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.serviceAccount.create` | bool | `true` | Create a ServiceAccount |
| `server.serviceAccount.name` | string | `""` | Name. Empty → `<fullname>` when `create: true`, or `default` when `create: false` |
| `server.serviceAccount.createSecret` | bool | `false` | Create a long-lived token Secret `<sa-name>-token`. Requires `create: true` |
| `server.serviceAccount.annotations` | map or string (tpl) | `{}` | ServiceAccount annotations |
| `server.serviceAccount.extraLabels` | map | `{}` | ServiceAccount labels |
| `server.serviceAccount.serviceDiscovery.enabled` | bool | `true` | Create the discovery Role and RoleBinding (HA only). See [§3](#3-service-discovery-rbac) |

The ServiceAccount is created when `create: true` and either `server.enabled`
or `global.enabled` is `true`. It is also created in external mode (see
[03-global-and-identity.md §6](03-global-and-identity.md#6-globalexternalbaoaddr)).

### Note: annotations and `.mode`

The `openbao.serviceAccount.annotations` helper skips annotations when
`.mode` is `dev`. The mode helper never sets `dev`, so the annotations are
always rendered, including in dev mode.

### Examples

Cloud workload identity, for auto-unseal with a cloud KMS without static
keys:

```yaml
# AWS IRSA
server:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/openbao-kms
```

```yaml
# GCP Workload Identity
server:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: openbao-kms@my-project.iam.gserviceaccount.com
```

Use a ServiceAccount that already exists:

```yaml
server:
  serviceAccount:
    create: false
    name: platform-openbao
```

With `create: false`, the auth-delegator binding is still created for the
named ServiceAccount, as long as `name` is not empty.

### Long-lived token Secret

Since Kubernetes 1.24, ServiceAccounts no longer get token Secrets
automatically. `createSecret: true` creates one of type
`kubernetes.io/service-account-token`. You need it only when an **external**
OpenBao validates tokens from this cluster and needs a fixed reviewer JWT. An
in-cluster OpenBao uses its own projected token instead.

```yaml
server:
  serviceAccount:
    createSecret: true
```

```bash
kubectl -n openbao get secret openbao-token -o jsonpath='{.data.token}' | base64 -d
```

The token never expires. Treat it like a password, and rotate it by deleting
the Secret and running `helm upgrade`.

---

## 2. Auth delegator (Kubernetes auth method)

| Key | Type | Default |
|-----|------|---------|
| `server.authDelegator.enabled` | bool | `true` |

Creates ClusterRoleBinding `<fullname>-server-binding` to the built-in
ClusterRole `system:auth-delegator` for the server ServiceAccount. This lets
OpenBao call the `TokenReview` and `SubjectAccessReview` APIs, which the
[Kubernetes auth method](https://openbao.org/docs/auth/kubernetes/) needs to
validate pod tokens.

Rendered when all of these are true:

- `server.authDelegator.enabled: true`;
- `server.serviceAccount.create: true` **or** `server.serviceAccount.name` is
  set;
- `server.enabled: true` **or** `global.enabled: true`.

Installing the chart then needs permission to create ClusterRoleBindings.
Set `enabled: false` if you do not use the Kubernetes auth method or cannot
create cluster-scoped objects.

The binding name has no namespace in it. Two releases with the same
`<fullname>` in different namespaces conflict. Use different release names,
or `fullnameOverride`.

### Example: configure Kubernetes auth in an in-cluster server

```bash
kubectl -n openbao exec -it openbao-0 -- sh

bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443"

bao policy write app-read - <<'EOF'
path "secret/data/app/*" { capabilities = ["read"] }
EOF

bao write auth/kubernetes/role/app \
  bound_service_account_names=app \
  bound_service_account_namespaces=apps \
  policies=app-read \
  ttl=1h
```

OpenBao reads the CA and its own token from
`/var/run/secrets/kubernetes.io/serviceaccount`, so `kubernetes_ca_cert` and
`token_reviewer_jwt` are not needed. A pod in namespace `apps` with
ServiceAccount `app` can then log in:

```bash
bao write auth/kubernetes/login role=app \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
```

The snapshot agent logs in the same way, with
`snapshotAgent.config.baoAuthPath` and `baoRole`. See
[11-backup-snapshot-agent.md](11-backup-snapshot-agent.md).

---

## 3. Service discovery RBAC

Rendered only in **HA mode** when
`server.serviceAccount.serviceDiscovery.enabled: true`:

| Object | Name | Content |
|--------|------|---------|
| Role | `<fullname>-discovery-role` | `pods`: `get`, `watch`, `list`, `update`, `patch` |
| RoleBinding | `<fullname>-discovery-rolebinding` | Binds the Role to the server ServiceAccount |

The default HA configs contain `service_registration "kubernetes" {}`. With
it, each pod patches its own labels (`openbao-active`, `openbao-sealed`,
`openbao-initialized`, `openbao-perf-standby`, `openbao-version`). The active
and standby Services select on `openbao-active`.

| Situation | Result |
|-----------|--------|
| HA, discovery enabled (default) | Labels are set. Active and standby Services work |
| HA, discovery disabled, config still has `service_registration` | OpenBao logs permission errors. Active and standby Services stay empty, so Ingress, Gateway, Route and the snapshot agent have no backend |
| Standalone with `service_registration` added to the config | The Role is **not** created, so the same errors happen. Grant the permissions yourself, or remove the stanza |

Disable it only if you also remove `service_registration` from the config
and set `activeService: false` on every exposure method.

The Role allows `update` and `patch` on **all** pods in the namespace, not
only the OpenBao pods. Run OpenBao in its own namespace.

---

## 4. Security contexts

| Key | Type | Default |
|-----|------|---------|
| `server.statefulSet.securityContext.pod` | map or string (tpl) | `{}` |
| `server.statefulSet.securityContext.container` | map or string (tpl) | `{}` |
| `server.uid` | int | *(undeclared; default `100`)* |
| `server.gid` | int | *(undeclared; default `1000`)* |

When a value is empty, the chart applies defaults that depend on
`global.openshift`:

| Level | Kubernetes defaults | OpenShift defaults |
|-------|---------------------|--------------------|
| Pod | `runAsNonRoot: true`, `runAsUser: <uid>`, `runAsGroup: <gid>`, `fsGroup: <gid>`, `seccompProfile.type: RuntimeDefault` | none (the SCC decides) |
| Container | `allowPrivilegeEscalation: false` | none |

The server container does **not** drop all capabilities by default. The
snapshot agent container does. The defaults satisfy the Pod Security Standard
`baseline`, but **not** `restricted`, which also requires
`capabilities.drop: [ALL]`.

A non-empty value **replaces** the defaults completely; it does not merge
with them.

### Example: Pod Security `restricted`

```yaml
server:
  statefulSet:
    securityContext:
      pod:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      container:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
```

```bash
kubectl label namespace openbao pod-security.kubernetes.io/enforce=restricted
```

`readOnlyRootFilesystem: true` needs a writable `/tmp`. The start command
copies the config to `/tmp/storageconfig.hcl`, and the dev bootstrap writes
`/tmp/openbao.log`. `/tmp` is not a mounted volume by default, so add an
`emptyDir` for it:

```yaml
server:
  volumes:
    - name: tmp
      emptyDir: {}
  volumeMounts:
    - name: tmp
      mountPath: /tmp
```

### Memory locking

OpenBao recommends `mlock` to keep secrets out of swap. The chart sets
`SKIP_SETCAP=true` and grants no `IPC_LOCK` capability. Kubernetes nodes
normally run without swap, so this is acceptable. If your nodes use swap, add
`disable_mlock = false` to the HCL and the capability:

```yaml
server:
  statefulSet:
    securityContext:
      container:
        allowPrivilegeEscalation: false
        capabilities:
          add: [IPC_LOCK]
```

This fails under Pod Security `restricted`.

### OpenShift

With `global.openshift: true` the chart renders no security context. The
`restricted-v2` SCC assigns a UID and GID from the namespace range and
handles `fsGroup`. Do not set `runAsUser: 100` on OpenShift, or the SCC
rejects the pod.

---

## 5. NetworkPolicy

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `server.networkPolicy.enabled` | bool | `false` | Render the NetworkPolicy `<fullname>` |
| `server.networkPolicy.ingress` | list | Allow TCP `8200` and `8201` from all namespaces | `spec.ingress`, passed through |
| `server.networkPolicy.egress` | list | `[]` | `spec.egress`. Rendered only when non-empty |

The policy selects the pods by `app.kubernetes.io/name: <openbao.name>` and
`app.kubernetes.io/instance: <release>`. That includes the snapshot agent
pods.

`spec.policyTypes` is not set. Kubernetes then infers it: `Ingress` always,
`Egress` only if `egress` is non-empty. **As soon as you add an egress rule,
all other egress traffic is denied**, including DNS.

The NetworkPolicy has no `metadata.namespace`. It is created in the Helm
release namespace, which may differ from `global.namespace`.

### Example: restrict ingress

```yaml
server:
  networkPolicy:
    enabled: true
    ingress:
      # Raft and request forwarding between server pods
      - from:
          - podSelector:
              matchLabels:
                app.kubernetes.io/name: openbao
                component: server
        ports:
          - { port: 8200, protocol: TCP }
          - { port: 8201, protocol: TCP }
      # Clients and the ingress controller
      - from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: apps
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: ingress-nginx
        ports:
          - { port: 8200, protocol: TCP }
      # Prometheus
      - from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: monitoring
        ports:
          - { port: 8200, protocol: TCP }
```

The kubelet runs probes from the node and is not affected.

### Example: restrict egress

```yaml
server:
  networkPolicy:
    enabled: true
    egress:
      # DNS
      - to:
          - namespaceSelector: {}
            podSelector:
              matchLabels:
                k8s-app: kube-dns
        ports:
          - { port: 53, protocol: UDP }
          - { port: 53, protocol: TCP }
      # Other OpenBao pods (Raft, forwarding)
      - to:
          - podSelector:
              matchLabels:
                app.kubernetes.io/name: openbao
        ports:
          - { port: 8200, protocol: TCP }
          - { port: 8201, protocol: TCP }
      # Kubernetes API (TokenReview, service registration)
      - to:
          - ipBlock:
              cidr: 10.96.0.1/32
        ports:
          - { port: 443, protocol: TCP }
      # KMS and S3 endpoints
      - to:
          - ipBlock:
              cidr: 0.0.0.0/0
              except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
        ports:
          - { port: 443, protocol: TCP }
```

Check the API server address with
`kubectl get endpoints kubernetes -n default`. Some network plugins apply
policies after NAT and need the endpoint IP instead of the Service IP.
Secrets engines that connect to databases or LDAP need their own egress
rules.

---

## 6. Hardening checklist

| Item | Setting |
|------|---------|
| No dev mode in shared or production clusters | `server.dev_mode.enabled: false` |
| TLS on | `global.tlsDisable: false`, a real CA (`clusterIssuerName`) |
| TLS 1.2 or later | `server.tls.tlsMinVersion: tls12` (default) or `tls13` |
| Dedicated namespace | Limits the scope of the discovery Role and of `pods/exec` |
| Restrict `pods/exec` | Exec gives the root token in dev mode and unrestricted CLI access otherwise |
| Pod Security `restricted` | [§4 example](#example-pod-security-restricted) |
| NetworkPolicy | [§5](#5-networkpolicy) |
| Auth delegator only if needed | `server.authDelegator.enabled: false` otherwise |
| No long-lived tokens unless needed | `server.serviceAccount.createSecret: false` |
| No private keys in Helm values | Prefer `certManager` or `existingSecret` over `rawCerts` |
| Audit device | `server.auditStorage.enabled: true` and `bao audit enable` |
| Auto-unseal with KMS or Transit | Avoids storing unseal keys near the data. See [12-advanced.md](12-advanced.md#2-auto-unseal) |
| Revoke the initial root token | `bao token revoke <root-token>` after setting up admin access |
