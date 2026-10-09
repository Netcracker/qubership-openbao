# Quick Start

This guide installs OpenBao with the chart defaults, checks that it works,
stores and reads a secret, opens the web UI and removes the release. It takes
about five minutes on a cluster with a default StorageClass.

> **Scope.** The defaults give a single-replica **persistent development
> server**. It initializes and unseals itself, and it stores the unseal key
> and root token **in plain text on its own data volume**. Use it only for
> development and testing. For production, see the HA with Raft mode in
> [09-deployment-modes.md](09-deployment-modes.md#4-ha-with-integrated-raft).

## 1. Prerequisites

| Requirement | How to check |
|-------------|--------------|
| Kubernetes `>= 1.30` | `kubectl version` |
| Helm 3 | `helm version` |
| A default StorageClass (or set `server.dataStorage.storageClass`) | `kubectl get storageclass` (look for `(default)`) |
| Permission to create a `ClusterRoleBinding` | `kubectl auth can-i create clusterrolebindings` |

The `ClusterRoleBinding` permission is needed because
`server.authDelegator.enabled` is `true` by default. If you lack cluster-admin
rights, add `--set server.authDelegator.enabled=false`.

## 2. Install with defaults

```bash
helm install openbao ./charts/openbao \
  --namespace openbao --create-namespace
```

The default install creates these resources:

| Kind | Name | Purpose |
|------|------|---------|
| `StatefulSet` | `openbao` | One server pod, `openbao-0` |
| `PersistentVolumeClaim` | `data-openbao-0` | 10Gi single-node integrated Raft storage at `/openbao/data` |
| `ConfigMap` | `openbao-config` | Rendered server HCL configuration |
| `Service` | `openbao` | Client endpoint on port `8200` (plus `8201`) |
| `Service` | `openbao-internal` | Headless service for stable pod DNS |
| `ServiceAccount` | `openbao` | Pod identity |
| `ClusterRoleBinding` | `openbao-server-binding` | Binds `system:auth-delegator` for the Kubernetes auth method |

TLS is disabled by default (`global.tlsDisable: true`). The API is served over
plain HTTP on port `8200`.

## 3. Verify the deployment

Wait for the pod to become ready:

```bash
kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=180s
kubectl -n openbao get pods
```

`kubectl rollout status` does not work here. The StatefulSet uses the
`OnDelete` update strategy, and `rollout status` supports only
`RollingUpdate`.

```text
NAME        READY   STATUS    RESTARTS   AGE
openbao-0   1/1     Running   0          40s
```

The readiness probe runs `bao status` inside the container. `bao status`
exits with code `0` only when the server is unsealed, so `READY 1/1` means the
automatic bootstrap succeeded.

Check the server status:

```bash
kubectl -n openbao exec openbao-0 -- bao status
```

Example output (abbreviated):

```text
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
Storage Type    raft
HA Enabled      true
HA Mode         active
```

`HA Enabled true` only means the Raft machinery is on: the single pod is the
leader of a one-node Raft cluster. There is no standby.

`bao` CLI calls inside the pod need no extra flags. The chart sets
`BAO_ADDR=http://127.0.0.1:8200` in the container environment.

### What happened on first start

The chart starts the server with single-node integrated storage (Raft). A new
OpenBao
server always starts **uninitialized and sealed**. Because
`server.dev_mode.enabled` is `true`, the chart adds a `postStart` hook to the
container
([`server-statefulset.yaml:221`](/charts/openbao/templates/server-statefulset.yaml)).
The hook does the following:

1. Polls `bao status` for up to 60 seconds until the API responds.
2. On first boot only, runs `bao operator init -key-shares=1 -key-threshold=1`
   and writes the result to `/openbao/data/bootstrap-keys.json`.
3. On every start, reads the unseal key from that file and runs
   `bao operator unseal` if the server is sealed.

Because the keys and the data are both on the PVC, the server survives pod
restarts and comes back unsealed. The hook writes its progress to
`/tmp/openbao.log` inside the container:

```bash
kubectl -n openbao exec openbao-0 -- cat /tmp/openbao.log
```

## 4. Get the root token

The root token and the unseal key are in the bootstrap file:

```bash
kubectl -n openbao exec openbao-0 -- cat /openbao/data/bootstrap-keys.json
```

```json
{
  "unseal_keys_b64": ["<base64-unseal-key>"],
  "unseal_keys_hex": ["<hex-unseal-key>"],
  "unseal_shares": 1,
  "unseal_threshold": 1,
  "root_token": "<root-token>"
}
```

To extract only the token:

```bash
ROOT_TOKEN=$(kubectl -n openbao exec openbao-0 -- \
  sh -c 'grep -o "\"root_token\":[^,}]*" /openbao/data/bootstrap-keys.json | cut -d\" -f4')
echo "$ROOT_TOKEN"
```

PowerShell equivalent:

```powershell
$json = kubectl -n openbao exec openbao-0 -- cat /openbao/data/bootstrap-keys.json | ConvertFrom-Json
$ROOT_TOKEN = $json.root_token
```

> Anyone who can `exec` into the pod or read the PVC gets full root access.
> Restrict `pods/exec` RBAC in shared namespaces, even in development.

## 5. Store and read a secret

Log in inside the pod. The token is cached in `/home/openbao`, an `emptyDir`
that lasts until the pod restarts:

```bash
kubectl -n openbao exec openbao-0 -- bao login "$ROOT_TOKEN"
```

Enable a KV v2 secrets engine, then write and read a secret:

```bash
kubectl -n openbao exec openbao-0 -- bao secrets enable -path=secret kv-v2
kubectl -n openbao exec openbao-0 -- bao kv put secret/demo username=app password=s3cr3t
kubectl -n openbao exec openbao-0 -- bao kv get secret/demo
```

Restart the pod to confirm that the data persists and the server unseals
itself:

```bash
kubectl -n openbao delete pod openbao-0
kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=180s
kubectl -n openbao exec openbao-0 -- bao login "$ROOT_TOKEN"
kubectl -n openbao exec openbao-0 -- bao kv get secret/demo
```

## 6. Access the API and the UI from your workstation

The server HCL contains `ui = true`, so the web UI is served on the same port
as the API. Forward the client service:

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200
```

- UI: <http://127.0.0.1:8200/ui>. Sign in with the **Token** method and the
  root token.
- API: `curl http://127.0.0.1:8200/v1/sys/health`

Use a local `bao` CLI against the forwarded port:

```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN="$ROOT_TOKEN"
bao kv get secret/demo
```

`ui.enabled: true` does not turn the UI on. It only creates a separate
`openbao-ui` Service (for example a `LoadBalancer` or `NodePort`). See
[06-services-and-exposure.md](06-services-and-exposure.md).

## 7. Common first customizations

Put overrides in a file and pass it with `-f`. The example below changes
storage, sets resource limits, enables JSON logs and exposes the UI service:

```yaml
# my-values.yaml
server:
  dataStorage:
    size: 5Gi
    storageClass: standard        # omit to use the cluster default
  resources:
    requests: { cpu: 250m, memory: 256Mi }
    limits:   { cpu: 250m, memory: 256Mi }
  logLevel: info                  # trace | debug | info | warn | error
  logFormat: json                 # standard | json

ui:
  enabled: true
  serviceType: ClusterIP
```

```bash
helm upgrade --install openbao ./charts/openbao -n openbao -f my-values.yaml
```

The chart ships ready-made resource profiles under
[`charts/openbao/resource-profiles/`](/charts/openbao/resource-profiles). The
dev profile matches this guide:

```bash
helm upgrade --install openbao ./charts/openbao -n openbao \
  -f charts/openbao/resource-profiles/dev.yaml
```

### Applying changes to a running pod

The StatefulSet uses `server.updateStrategyType: OnDelete`. After
`helm upgrade`, Kubernetes **does not restart** the pod. Restart it yourself
to pick up the new pod template or configuration:

```bash
kubectl -n openbao delete pod openbao-0
```

> Ready-made values files for every mode are in [`examples/`](../../examples/README.md).
> `examples/dev.yaml` matches this guide, with smaller resources and a PVC
> that is deleted together with the StatefulSet.

## 8. Uninstall

```bash
helm uninstall openbao -n openbao
```

Helm **does not delete** the data PVC. StatefulSet `volumeClaimTemplates` are
not owned by the release. The PVC still holds your data and
`bootstrap-keys.json`. If you reinstall with the same release name, the new
pod reuses the PVC and unseals with the existing keys.

To remove everything:

```bash
kubectl -n openbao delete pvc data-openbao-0
kubectl delete namespace openbao
```

To have Kubernetes delete PVCs together with the StatefulSet, set:

```yaml
server:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Retain
```

## Next steps

- Read [02-concepts.md](02-concepts.md) to learn how the chart selects the
  deployment mode and how the server configuration is built.
- Move to a production topology (HA with integrated Raft) with
  [09-deployment-modes.md](09-deployment-modes.md).
- Enable TLS with [07-tls.md](07-tls.md).
