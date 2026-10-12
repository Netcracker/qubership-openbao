# Troubleshooting

This document lists the errors you can get when rendering the chart and the
most common runtime problems, with causes and fixes. It ends with a set of
diagnostic commands.

- [1. Render-time errors](#1-render-time-errors)
- [2. Install-time errors](#2-install-time-errors)
- [3. Pod does not start](#3-pod-does-not-start)
- [4. Pod runs but is not Ready](#4-pod-runs-but-is-not-ready)
- [5. HA and Raft problems](#5-ha-and-raft-problems)
- [6. Networking and exposure](#6-networking-and-exposure)
- [7. TLS problems](#7-tls-problems)
- [8. Upgrade problems](#8-upgrade-problems)
- [9. Diagnostic toolkit](#9-diagnostic-toolkit)

---

## 1. Render-time errors

These come from `fail` calls in the templates or from `values.schema.json`.
They stop `helm template`, `helm install` and `helm upgrade` before anything
is applied.

| Error message (start) | Source | Cause | Fix |
|-----------------------|--------|-------|-----|
| `server.dev_mode.enabled and server.ha.enabled are mutually exclusive` | `_helpers.tpl` `openbao.mode` | Both are `true`. `dev_mode.enabled` is `true` by default | Set `server.dev_mode.enabled: false` when you enable HA |
| `server.tls material is set ... but global.tlsDisable is true` | `openbao.tls.validate` | `server.tls.certs.*` or `server.tls.secretName` set while TLS is off | Set `global.tlsDisable: false`, or clear the TLS values |
| `server.tls.source=rawCerts with global.tlsDisable=false requires both server.tls.certs.crt and server.tls.certs.key` | `openbao.tls.validate` | `rawCerts` without certificate or key | Pass them with `--set-file` |
| `server.tls.source=existingSecret ... requires server.tls.secretName` | `openbao.tls.validate` | `existingSecret` without a name | Set `server.tls.secretName` |
| `server.gateway.httpRoute.enabled=true, but gateway.networking.k8s.io/v1/HTTPRoute is not served by this cluster` | `server-httproute.yaml` | CRD missing, or `helm template` without cluster access | Install the Gateway API CRDs; offline: `--api-versions gateway.networking.k8s.io/v1/HTTPRoute` |
| `... v1/TLSRoute is not served by this cluster` | `server-tlsroute.yaml` | Default `apiVersion: v1`, but most clusters serve TLSRoute only as `v1alpha2` or `v1alpha3` | Set `server.gateway.tlsRoute.apiVersion` to what `kubectl api-resources \| grep -i tlsroute` shows |
| `... v1/BackendTLSPolicy is not served by this cluster` | `server-backendtlspolicy.yaml` | CRD missing or a different version | Install it, or set `server.gateway.tlsPolicy.apiVersion` |
| `server.gateway.httpRoute.enabled is true but server.gateway.httpRoute.parentRefs is empty` | `server-httproute.yaml` | No Gateway referenced | Set `parentRefs` |
| `server.gateway.tlsRoute.enabled is true but server.gateway.tlsRoute.parentRefs is empty` | `server-tlsroute.yaml` | No Gateway referenced | Set `parentRefs` |
| `values don't meet the specifications of the schema ... certs ... minLength` | `values.schema.json` | `source: rawCerts` with empty `crt`/`key` (checked even when TLS is off) | Provide them, or use another `source` |
| `values don't meet ... secretName ... minLength` | `values.schema.json` | `source: existingSecret` with empty `secretName` (checked even when TLS is off) | Set it, or use another `source` |
| `values don't meet ... source ... must be one of` | `values.schema.json` | Typo in `server.tls.source` | `certManager`, `rawCerts` or `existingSecret` |
| `... Invalid type. Expected: integer, given: string` | `values.schema.json` | `--set` of a number as a string, for example `--set-string server.ha.replicas=3` | Use `--set` (not `--set-string`) for numbers |
| `error converting YAML to JSON` / `mapping values are not allowed` | template output | Indentation error in a string value (`affinity`, `annotations`, config) | Render with `--debug` and check the indentation of your multi-line string |
| `template: ... function "..." not defined` | `tpl` in a value | Bad template syntax inside `config`, `affinity`, `annotations` | Fix the template; escape literal `{{` as `{{"{{"}}` |

Use `helm template --debug` to see the partially rendered output when a
template fails.

---

## 2. Install-time errors

The render succeeded, but the Kubernetes API rejects an object.

| Error | Cause | Fix |
|-------|-------|-----|
| `no matches for kind "Certificate" in version "cert-manager.io/v1"` | TLS with `source: certManager` and no cert-manager | Install cert-manager, or use `rawCerts` / `existingSecret` |
| `no matches for kind "ServiceMonitor"` / `"PrometheusRule"` | Prometheus Operator CRDs missing | Install them, or disable `serverTelemetry.*` |
| `clusterrolebindings.rbac.authorization.k8s.io is forbidden` | Installer has no cluster-scope rights | `server.authDelegator.enabled: false`, or ask a cluster admin |
| `ClusterRoleBinding "<fullname>-server-binding" exists and cannot be imported` | Same release name in another namespace | Use a different release name or `fullnameOverride` |
| `Service "<name>" is invalid: spec.ports[0].nodePort: Invalid value: ... provided port is already allocated` | Fixed `nodePort` already in use | Choose another port, or leave it empty |
| `violates PodSecurity "restricted:latest"` | Default container security context does not drop all capabilities | [08-security-and-rbac.md §4](08-security-and-rbac.md#example-pod-security-restricted) |
| `exceeded quota` | Namespace ResourceQuota requires requests and limits | Set `server.resources` and `snapshotAgent.resources` |

---

## 3. Pod does not start

| Pod status / event | Cause | Fix |
|--------------------|-------|-----|
| `Pending`, `0/N nodes are available: N node(s) didn't match pod anti-affinity rules` | Default **required** anti-affinity, fewer nodes than replicas | Add nodes, or use preferred anti-affinity ([04 §12](04-server-workload.md#12-scheduling)) |
| `Pending`, `pod has unbound immediate PersistentVolumeClaims` | No default StorageClass, or the class cannot provision | `kubectl get sc`; set `server.dataStorage.storageClass` |
| `Pending`, `volume node affinity conflict` | Zonal volume, pod rescheduled to another zone | Use topology-aware storage classes; keep the pod in the volume's zone |
| `ContainerCreating`, `secret "<fullname>-tls" not found` | Certificate not issued yet, issuer missing, or `existingSecret` missing | `kubectl describe certificate <fullname>-tls`; create the issuer or Secret |
| `ContainerCreating`, `configmap "<name>" not found` | `extraVolumes` / `volumes` reference a missing ConfigMap | Create it |
| `CreateContainerConfigError`, `secret "<name>" not found` or `key ... not found` | `extraSecretEnvironmentVars` reference | Create the Secret with the right key |
| `ErrImagePull` / `ImagePullBackOff` | Wrong registry, tag or missing pull secret | Check `server.image.*` and `global.imagePullSecrets` |
| `CrashLoopBackOff`, log `Error parsing config` | Invalid HCL | `kubectl logs`; render the ConfigMap and check it ([12 §1.5](12-advanced.md#15-validating-the-result)) |
| `CrashLoopBackOff`, log `unknown storage type consul` (or similar) | Default HA config without Raft uses Consul, which OpenBao 2.x does not provide | [09-deployment-modes.md §5](09-deployment-modes.md#5-ha-with-external-storage) |
| `CrashLoopBackOff`, `open /openbao/tls/tls.crt: no such file` | Custom Secret key names | Set `server.tls.certKey` / `keyKey` |
| `CrashLoopBackOff`, `permission denied` on `/openbao/data` | Volume ownership | [05-storage.md §6](05-storage.md#6-file-ownership-and-permissions) |
| `CrashLoopBackOff`, `bind: address already in use` | `hostNetwork: true`, port taken on the node | Disable `hostNetwork` |
| `CrashLoopBackOff`, `read-only file system` on `/tmp` | `readOnlyRootFilesystem: true` | Mount an `emptyDir` at `/tmp` ([08 §4](08-security-and-rbac.md#4-security-contexts)) |
| `PostStartHookError` in dev mode | Bootstrap script failed (`set -e`), for example API not up within 60s, or TLS errors | `kubectl describe pod`; check `/tmp/openbao.log` before the restart; see [§4](#4-pod-runs-but-is-not-ready) |
| Container restarts every ~70 seconds | Liveness probe on a sealed or uninitialized server | Unseal, or allow sealed state in the probe ([04 §6](04-server-workload.md#6-liveness-probe)) |
| No StatefulSet at all | Resolved mode is `""` (`standalone.enabled: false` without HA) or `external` | [02-concepts.md §1](02-concepts.md#1-deployment-mode-resolution) |
| `CrashLoopBackOff` in standalone/dev after a chart upgrade, log `contains data of the legacy 'file' storage backend` | The data PVC still holds `file` backend data; standalone now uses single-node Raft | Migrate with `bao operator migrate` ([09 §8.5](09-deployment-modes.md#85-migrating-a-file-backed-standalone-to-raft)), or set `server.standalone.legacyFileDataCheck: false` to discard it |
| Standalone log `failed to join raft cluster` / `retry_join` errors | A custom `standalone.config` contains `retry_join` | Remove `retry_join` from `standalone.config`; use HA mode for multiple nodes |
| Standalone log `permission denied` for `pods` / `service_registration` | `service_registration "kubernetes"` in `standalone.config`, but no discovery Role in standalone | Remove the stanza ([08-security-and-rbac.md](08-security-and-rbac.md)) |
| Second standalone pod with its own empty cluster | StatefulSet scaled manually (`kubectl scale`) | Scale back to 1; to add nodes switch to HA ([09 §8.2](09-deployment-modes.md#82-standalone-to-ha-with-raft)) |

---

## 4. Pod runs but is not Ready

The default readiness probe runs `bao status`, which succeeds only when the
server is **initialized and unsealed**.

```bash
kubectl -n openbao exec openbao-0 -- bao status
```

| `bao status` shows | Meaning | Fix |
|--------------------|---------|-----|
| `Initialized false` | New server | `bao operator init` ([09 §3.5](09-deployment-modes.md#35-first-start)) |
| `Sealed true` | Restarted without auto-unseal | `bao operator unseal` with the threshold of keys |
| `Sealed true`, seal type `transit`/`awskms`/... | Auto-unseal cannot reach the KMS | `kubectl logs`; check credentials, network, NetworkPolicy egress |
| `x509: certificate signed by unknown authority` | `BAO_CACERT` file missing or wrong (TLS on) | Provide `ca.crt` in the TLS Secret, or use an `httpGet` readiness probe |
| `x509: certificate is valid for ..., not 127.0.0.1` | Custom certificate without `127.0.0.1` | Add the IP SAN |
| `connection refused` | Server not listening yet, or crashed | `kubectl logs openbao-0` |
| `Client sent an HTTP request to an HTTPS server` | Listener has TLS but `BAO_ADDR` is `http` (pod template and config out of sync) | Restart the pod after changing `global.tlsDisable` |
| Works, but the pod is still not Ready | Readiness `httpGet` with a path that returns 429 or 503 | Adjust `server.readinessProbe.path` ([04 §5](04-server-workload.md#5-readiness-probe)) |

### Dev mode specific

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod `Running 0/1` after upgrade from standalone | `bootstrap-keys.json` missing: the server was initialized without the dev script | Unseal manually, or reinitialize on an empty PVC |
| `bootstrap-keys.json` empty, server initialized | `bao operator init` output lost (crash during init) | Data is unrecoverable; delete the PVC and start again |
| Pod `Running 0/1` with TLS on | The dev script uses `bao status` without `-tls-skip-verify` when TLS is on, and the CA is missing | Provide a CA, or disable TLS in dev mode |

---

## 5. HA and Raft problems

| Symptom | Cause | Fix |
|---------|-------|-----|
| Only `openbao-0` exists | `OrderedReady`: `-1` waits for `-0` to be Ready | Initialize and unseal `-0`, or use `podManagementPolicy: Parallel` |
| Follower logs `failed to retry join raft cluster` | Leader not reachable at the `retry_join` address | Check `<pod>.<fullname>-internal` DNS and port 8200; `server.service.enabled` must be `true` |
| Same, with `x509` errors | Joining over HTTPS without `leader_ca_cert_file` and a CA not in the system store | Add `leader_ca_cert_file` to each `retry_join` ([09 §4.2](09-deployment-modes.md#42-values)) |
| New pod `openbao-3` never joins | Default config has `retry_join` only for `-0` to `-2`, and none of them is reachable | Generate `retry_join` from `replicas` |
| `list-peers` shows random UUIDs | `raft.setNodeId: false` | Accept it, or set it before the first start |
| `list-peers` shows a removed pod as voter | Scaled down without `remove-peer` | `bao operator raft remove-peer <id>` |
| Cluster has no leader, writes fail | Quorum lost (majority of voters down) | Bring nodes back; otherwise follow the Raft `peers.json` recovery or restore a snapshot |
| `openbao-active` Service has no endpoints | No unsealed leader, or the pod cannot set its labels | Unseal; check discovery RBAC ([08 §3](08-security-and-rbac.md#3-service-discovery-rbac)); the config must contain `service_registration "kubernetes"` |
| Logs `pods "openbao-0" is forbidden: User "system:serviceaccount:..." cannot patch resource "pods"` | `serviceDiscovery.enabled: false` or a custom ServiceAccount without the Role | Enable it, or bind the Role yourself |
| Leader changes very often | Slow disks, CPU throttling, or network latency | SSD storage, CPU limits equal to requests or no CPU limit, `performance_multiplier` |
| Node drain blocked | PDB `maxUnavailable` computed as `0` (1 or 2 replicas) | Set `server.ha.disruptionBudget.maxUnavailable: 1` |
| PDB allows more disruptions than expected | `maxUnavailable: 0` is treated as unset | Use the computed value or an explicit `1` |

---

## 6. Networking and exposure

| Symptom | Cause | Fix |
|---------|-------|-----|
| Ingress returns 503 | HA: `activeService: true` and no leader; or `server.service.enabled: false` | Unseal; keep services enabled |
| Ingress returns 502 with TLS on | Controller talks HTTP to an HTTPS backend | Set the backend protocol annotation ([06 §4](06-services-and-exposure.md#4-ingress)) |
| Ingress 400 `The plain HTTP request was sent to HTTPS port` | Same as above | Same |
| Requests reach a sealed node and get 503 | `publishNotReadyAddresses: true` keeps sealed pods behind the client Service | Use `<fullname>-active`, or set `server.service.publishNotReadyAddresses: false` (the headless Service is not affected) |
| HTTPRoute accepted but traffic fails with TLS | No BackendTLSPolicy, gateway sends HTTP | Enable `server.gateway.tlsPolicy` |
| BackendTLSPolicy `ResolvedRefs=False` | Gateway does not support Secret CA references | Use a ConfigMap ([06 §6.3](06-services-and-exposure.md#63-backendtlspolicy-re-encrypt)) |
| TLSRoute not attached | Listener is not `protocol: TLS, mode: Passthrough`, or `sectionName` wrong | Check the Gateway status and listener |
| Route created on plain Kubernetes | Not possible: the Route template needs `global.openshift: true` | — |
| Ingress created on OpenShift | `server.ingress.enabled: true` is not checked against OpenShift | Disable it and use `server.route` |
| NetworkPolicy blocks everything | Egress rules added: all other egress is denied, including DNS | Add DNS, Kubernetes API and peer rules ([08 §5](08-security-and-rbac.md#5-networkpolicy)) |
| NetworkPolicy has no effect | Created in the Helm namespace while pods are in `global.namespace`; or the CNI does not enforce policies | Use the same namespace; check the CNI |
| UI shows 404 | `ui = true` missing in a custom config | Add it |

---

## 7. TLS problems

See [07-tls.md §10](07-tls.md#10-pitfalls) for the full table. The most
frequent:

| Symptom | Fix |
|---------|-----|
| `Certificate` `Ready=False`, `issuer not found` | Default `issuerRef.name: openbao-ca-issuer` does not exist. Use `generateIssuer: true`, `clusterIssuerName`, or create the issuer |
| Clients fail after renewal with `generateIssuer: true` | Each renewal creates a new self-signed CA. Clients must reload `ca.crt`; use a real CA in production |
| Old certificate still served after renewal | OpenBao reads the certificate at start; send `SIGHUP` or restart ([07 §9](07-tls.md#9-certificate-rotation)) |
| `rawCerts` Secret left after `helm uninstall` | Hook resources are not deleted by Helm. Delete the Secret by hand |

---

## 8. Upgrade problems

| Error or symptom | Cause | Fix |
|------------------|-------|-----|
| `StatefulSet.apps "openbao" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden` | Changed PVC size, class, labels, `podManagementPolicy`, or switched between Raft and external storage | `kubectl delete sts <fullname> --cascade=orphan`, then `helm upgrade` ([05 §5](05-storage.md#5-resizing-volumes)) |
| `field is immutable` on the StatefulSet selector | `nameOverride` changed | Revert it |
| Pods do not pick up the new version or config | `updateStrategyType: OnDelete` | Delete the pods ([04 §2](04-server-workload.md#2-statefulset-behavior)) |
| `kubectl rollout status` returns an error | Not supported with `OnDelete` | Use `kubectl wait --for=condition=Ready pod/<name>` |
| After switching dev → standalone the pod is sealed | Expected; the dev script no longer runs | Unseal with the key from `bootstrap-keys.json` ([09 §8.1](09-deployment-modes.md#81-dev-to-standalone)) |
| After enabling TLS, clients and probes fail | Pods still run the old (HTTP) config | Restart the pods ([07 §8](07-tls.md#8-enabling-tls-on-a-running-release)) |
| Helm `another operation (install/upgrade/rollback) is in progress` | A previous operation was interrupted | `helm history openbao -n openbao`; `helm rollback` to the last good revision |

---

## 9. Diagnostic toolkit

### Render and compare

```bash
helm template openbao ./charts/openbao -n openbao -f values.yaml --debug > rendered.yaml
helm get values openbao -n openbao --all
helm get manifest openbao -n openbao > live.yaml
diff -u live.yaml rendered.yaml
```

Show the resolved mode quickly (which config was rendered):

```bash
helm template openbao ./charts/openbao -f values.yaml \
  --show-only templates/server-config-configmap.yaml | grep -E 'storage "|seal "'
```

### Pods and events

```bash
kubectl -n openbao get pods -l component=server -o wide \
  -L openbao-active,openbao-sealed,openbao-initialized
kubectl -n openbao describe pod openbao-0
kubectl -n openbao get events --sort-by=.lastTimestamp | tail -30
kubectl -n openbao logs openbao-0 --previous
```

### Server state

```bash
kubectl -n openbao exec openbao-0 -- bao status
kubectl -n openbao exec openbao-0 -- cat /tmp/storageconfig.hcl
kubectl -n openbao exec openbao-0 -- env | grep -E '^BAO_|^HOSTNAME|^POD_IP'
kubectl -n openbao exec openbao-0 -- cat /tmp/openbao.log           # dev mode
```

With a token:

```bash
kubectl -n openbao exec -it openbao-0 -- bao login
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers
kubectl -n openbao exec openbao-0 -- bao operator raft autopilot state
kubectl -n openbao exec openbao-0 -- bao operator members
```

### Networking

```bash
kubectl -n openbao get svc,endpoints -l app.kubernetes.io/instance=openbao
kubectl -n openbao run net-debug --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'nslookup openbao-0.openbao-internal; wget -qO- http://openbao-active:8200/v1/sys/health'
```

### TLS

```bash
kubectl -n openbao get certificate,certificaterequest,issuer
kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

### Collect a debug bundle

```bash
kubectl -n openbao exec -it openbao-0 -- bao login
kubectl -n openbao exec openbao-0 -- bao debug -duration=2m -output=/tmp/bao-debug.tar.gz
kubectl -n openbao cp openbao-0:/tmp/bao-debug.tar.gz ./bao-debug.tar.gz
```

`bao debug` collects server state, metrics, and logs for the given duration.
Check the bundle for sensitive data before you share it.
