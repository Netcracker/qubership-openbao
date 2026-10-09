# Advanced Topics

This document collects techniques that combine several chart features:
custom server configuration, auto-unseal, plugins, sidecars, OpenShift,
air-gapped installs, upgrades and dual-stack networking.

- [1. Writing a custom server configuration](#1-writing-a-custom-server-configuration)
- [2. Auto-unseal](#2-auto-unseal)
- [3. Plugins](#3-plugins)
- [4. Sidecars](#4-sidecars)
- [5. OpenShift](#5-openshift)
- [6. Air-gapped installation](#6-air-gapped-installation)
- [7. Combining profiles and values files](#7-combining-profiles-and-values-files)
- [8. Upgrades](#8-upgrades)
- [9. Dual-stack networking](#9-dual-stack-networking)
- [10. Rendering and validating locally](#10-rendering-and-validating-locally)

> Examples in this document have not yet been checked with `helm template`
> or on a live cluster. Seal and plugin behavior depends on the OpenBao
> version; check the [OpenBao documentation](https://openbao.org/docs/) for
> the version you run.

---

## 1. Writing a custom server configuration

### 1.1 Which value to override

| Mode | Value |
|------|-------|
| standalone (including dev mode) | `server.standalone.config` |
| HA with Raft | `server.ha.raft.config` |
| HA with external storage | `server.ha.config` |

Overriding replaces the whole default. Start from the default in
`values.yaml`.

### 1.2 String or map

| Form | Rendering | Good for |
|------|-----------|----------|
| Multi-line string | Helm `tpl`, then placeholder substitution at start | Almost everything. Allows template logic and placeholders |
| YAML map | `toPrettyJson` (OpenBao reads JSON config) | Generated configs from other tools. No template logic |

### 1.3 Building blocks

Template expressions available in the string form:

| Expression | Result |
|------------|--------|
| `{{ .Values.global.tlsDisable }}` | TLS switch |
| `{{ .Values.server.tls.mountPath }}/{{ .Values.server.tls.certKey }}` | Certificate path |
| `{{ include "openbao.fullname" . }}` | Resource prefix, for example `openbao` |
| `{{ include "openbao.scheme" . }}` | `http` or `https` |
| `{{ include "openbao.namespace" . }}` | Namespace |
| `{{ .Values.server.ha.replicas }}` | Replica count |
| `{{ .Values.server.dataStorage.mountPath }}` | Data path |

Runtime placeholders (replaced by `sed` when the container starts):
`HOST_IP`, `POD_IP`, `HOSTNAME`, and, if you set the variables, `API_ADDR`,
`TRANSIT_ADDR`, `RAFT_ADDR`. See
[02-concepts.md §4](02-concepts.md#stage-4-runtime-placeholder-substitution).

### 1.4 A reusable Raft template

This config keeps the TLS conditionals of the default, generates
`retry_join` from `replicas`, and adds telemetry:

```yaml
server:
  ha:
    raft:
      config: |
        ui = true
        {{- $fn     := include "openbao.fullname" . }}
        {{- $scheme := include "openbao.scheme" . }}
        {{- $tls    := .Values.server.tls }}

        listener "tcp" {
          address         = "[::]:8200"
          cluster_address = "[::]:8201"
          {{- if .Values.global.tlsDisable }}
          tls_disable = 1
          {{- else }}
          tls_cert_file   = "{{ $tls.mountPath }}/{{ $tls.certKey }}"
          tls_key_file    = "{{ $tls.mountPath }}/{{ $tls.keyKey }}"
          tls_min_version = "{{ $tls.tlsMinVersion }}"
          {{- end }}
          telemetry {
            unauthenticated_metrics_access = "true"
          }
        }

        storage "raft" {
          path = "{{ .Values.server.dataStorage.mountPath }}"
          performance_multiplier = 1
          {{- range $i := until (int .Values.server.ha.replicas) }}
          retry_join {
            leader_api_addr = "{{ $scheme }}://{{ $fn }}-{{ $i }}.{{ $fn }}-internal:8200"
            {{- if not $.Values.global.tlsDisable }}
            leader_ca_cert_file = "{{ $tls.mountPath }}/{{ $tls.caKey }}"
            {{- end }}
          }
          {{- end }}
        }

        service_registration "kubernetes" {}

        telemetry {
          prometheus_retention_time = "30s"
          disable_hostname          = true
        }
```

### 1.5 Validating the result

```bash
helm template openbao ./charts/openbao -f values.yaml \
  --show-only templates/server-config-configmap.yaml
```

Check the config inside a running pod:

```bash
kubectl -n openbao exec openbao-0 -- cat /tmp/storageconfig.hcl
kubectl -n openbao exec openbao-0 -- bao operator validate-config /tmp/storageconfig.hcl
```

### 1.6 Secrets in the config

The config is stored in a ConfigMap, which is readable by anyone with
`configmaps/get` in the namespace. Never put passwords, tokens or keys in it.
Use one of:

- environment variables that the server reads directly
  (`BAO_PG_CONNECTION_URL`, `AWS_SECRET_ACCESS_KEY`, `BAO_TOKEN` for the
  Transit seal) through `server.extraSecretEnvironmentVars`;
- files from a Secret, mounted with `server.volumes` / `volumeMounts`, and
  referenced by path in the config.

---

## 2. Auto-unseal

With auto-unseal, OpenBao asks an external key service to decrypt its root
key on start. There is no manual unseal after a restart, which makes
`RollingUpdate` and node failures painless. `bao operator init` returns
**recovery keys** instead of unseal keys.

All examples add a `seal` stanza to your config ([§1](#1-writing-a-custom-server-configuration))
and pass credentials through the environment.

### 2.1 Transit (another OpenBao)

```yaml
server:
  extraEnvironmentVars:
    TRANSIT_ADDR: https://transit.example.com:8200
  extraSecretEnvironmentVars:
    - envName: BAO_TOKEN
      secretName: transit-unseal-token
      secretKey: token
  extraVolumes:
    - type: secret
      name: transit-ca
```

Seal stanza:

```hcl
seal "transit" {
  address         = "TRANSIT_ADDR"
  key_name        = "openbao-autounseal"
  mount_path      = "transit/"
  tls_ca_cert     = "/openbao/userconfig/transit-ca/ca.crt"
}
```

Prepare the Transit server:

```bash
bao secrets enable transit
bao write -f transit/keys/openbao-autounseal
bao policy write autounseal - <<'EOF'
path "transit/encrypt/openbao-autounseal" { capabilities = ["update"] }
path "transit/decrypt/openbao-autounseal" { capabilities = ["update"] }
EOF
bao token create -orphan -policy=autounseal -period=24h -field=token
```

Use a periodic token and renew it, or the seal fails when it expires.
`BAO_TOKEN` in the server container is also picked up by the in-pod CLI, so
`bao` commands in the pod use the Transit token unless you log in again.

### 2.2 AWS KMS

With IRSA (no static keys):

```yaml
server:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/openbao-unseal
  extraEnvironmentVars:
    AWS_REGION: eu-central-1
```

```hcl
seal "awskms" {
  kms_key_id = "arn:aws:kms:eu-central-1:123456789012:key/1234abcd-..."
}
```

The IAM role needs `kms:Encrypt`, `kms:Decrypt` and `kms:DescribeKey` on the
key.

### 2.3 GCP Cloud KMS

```yaml
server:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: openbao-unseal@my-project.iam.gserviceaccount.com
```

```hcl
seal "gcpckms" {
  project    = "my-project"
  region     = "global"
  key_ring   = "openbao"
  crypto_key = "unseal"
}
```

Without Workload Identity, mount a key file and set
`GOOGLE_APPLICATION_CREDENTIALS`. See
[04-server-workload.md §8](04-server-workload.md#example-gcp-credentials-file).

### 2.4 Azure Key Vault

```yaml
server:
  extraSecretEnvironmentVars:
    - envName: AZURE_TENANT_ID
      secretName: openbao-azure
      secretKey: tenant_id
    - envName: AZURE_CLIENT_ID
      secretName: openbao-azure
      secretKey: client_id
    - envName: AZURE_CLIENT_SECRET
      secretName: openbao-azure
      secretKey: client_secret
```

```hcl
seal "azurekeyvault" {
  vault_name = "openbao-kv"
  key_name   = "unseal"
}
```

### 2.5 PKCS#11 (HSM)

OpenBao 2.x supports a `pkcs11` seal. It needs the vendor's PKCS#11 library
inside the container: build a custom image or copy the library in with an
init container, and mount any device or network configuration. Check the
OpenBao seal documentation for the parameters.

### 2.6 Migrating from Shamir to auto-unseal

1. Add the `seal` stanza to the config and `helm upgrade`.
2. Restart the pods one at a time (standbys first).
3. Unseal each restarted pod with `-migrate` and the Shamir keys:

   ```bash
   kubectl -n openbao exec openbao-2 -- bao operator unseal -migrate <share>
   ```

4. After the leader is migrated, the cluster uses the KMS. The old unseal
   keys become recovery keys.

Test this in a non-production environment first.

---

## 3. Plugins

### 3.1 Install a plugin binary

Copy the binary into a shared `emptyDir` with an init container, then point
OpenBao to that directory.

```yaml
server:
  volumes:
    - name: plugins
      emptyDir: {}
  volumeMounts:
    - name: plugins
      mountPath: /usr/local/libexec/openbao
      readOnly: true

  extraInitContainers:
    - name: install-plugins
      image: registry.example.com/openbao-plugins:1.4.0    # contains /plugins/*
      command: [sh, -c, "cp /plugins/* /target/ && chmod 0755 /target/*"]
      volumeMounts:
        - name: plugins
          mountPath: /target
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
```

Add to the server config:

```hcl
plugin_directory = "/usr/local/libexec/openbao"
```

Building an image with the plugins is more reproducible than downloading
them at start-up. Downloads need egress (see the NetworkPolicy) and can
change between restarts.

### 3.2 Register and enable

```bash
SHA=$(kubectl -n openbao exec openbao-0 -- sha256sum /usr/local/libexec/openbao/my-plugin | cut -d' ' -f1)
kubectl -n openbao exec openbao-0 -- bao plugin register -sha256="$SHA" secret my-plugin
kubectl -n openbao exec openbao-0 -- bao secrets enable -path=my my-plugin
```

In HA, the binary must exist on **every** pod. The init container does that.

### 3.3 Declarative plugins

OpenBao 2.x also supports a `plugin` configuration block that downloads
OCI-packaged plugins (verify for your version). It removes the init container
but needs registry access from the pod.

---

## 4. Sidecars

### 4.1 Audit log shipper

```yaml
server:
  auditStorage:
    enabled: true
  extraContainers:
    - name: fluent-bit
      image: registry.example.com/fluent-bit:3.1
      args:
        - -i
        - tail
        - -p
        - path=/openbao/audit/audit.log
        - -o
        - stdout
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits:   { memory: 64Mi }
      volumeMounts:
        - name: audit
          mountPath: /openbao/audit
          readOnly: true
```

### 4.2 Certificate reload

Reload the listener certificate after cert-manager renews it, without
restarting the pod:

```yaml
server:
  shareProcessNamespace: true
  extraContainers:
    - name: tls-reloader
      image: alpine:3.20
      command:
        - sh
        - -c
        - |
          last=""
          while true; do
            cur=$(sha256sum /openbao/tls/tls.crt | cut -d' ' -f1)
            if [ -n "$last" ] && [ "$cur" != "$last" ]; then
              pkill -HUP bao && echo "sent SIGHUP"
            fi
            last=$cur
            sleep 60
          done
      volumeMounts:
        - name: tls
          mountPath: /openbao/tls
          readOnly: true
```

The volume name `tls` is defined by the chart when TLS is on. With
`shareProcessNamespace`, the sidecar can see and signal `bao`. The `pkill`
binary must exist in the sidecar image; it does in Alpine (busybox).

### 4.3 Resource and lifecycle notes

- Sidecars receive `SIGTERM` at the same time as the preStop hook runs.
  Keep them short-lived on shutdown.
- With `shareProcessNamespace: true`, every container can read the
  environment of `bao` through `/proc`, including `BAO_TOKEN` or KMS
  credentials. Only add trusted sidecars.

---

## 5. OpenShift

### 5.1 Base install

```bash
helm upgrade --install openbao ./charts/openbao -n openbao --create-namespace \
  -f charts/openbao/values.openshift.yaml \
  -f my-values.yaml
```

What `values.openshift.yaml` changes is described in
[03-global-and-identity.md §7](03-global-and-identity.md#7-globalopenshift).
In short: no security context (the SCC assigns UID and GID), the UBI image,
and an HTTP readiness probe that treats uninitialized servers as ready.

### 5.2 Exposure

Use `server.route` (see [06-services-and-exposure.md §5](06-services-and-exposure.md#5-openshift-route)).
Do not enable `server.ingress` on OpenShift; it is still rendered and
creates a second entry point.

### 5.3 SCC

The default `restricted-v2` SCC is sufficient:

- the chart does not need root, host paths or extra capabilities;
- do not set `runAsUser`, `runAsGroup` or `fsGroup` yourself;
- `server.hostNetwork` is ignored on OpenShift.

If you add `IPC_LOCK` for `mlock`, you need a custom SCC. Usually it is not
needed.

### 5.4 Monitoring

OpenShift user workload monitoring can read the chart's ServiceMonitor. The
`release: prometheus` label is harmless. Enable user workload monitoring for
the cluster, then:

```yaml
serverTelemetry:
  serviceMonitor:
    enabled: true
```

### 5.5 Image

Check that `registry.connect.redhat.com/openbao/openbao-ubi:<server.image.tag>`
exists; the overlay does not override the tag. Pull from that registry needs
a Red Hat pull secret in `global.imagePullSecrets`.

---

## 6. Air-gapped installation

### 6.1 Images to mirror

| Image | Source | Value |
|-------|--------|-------|
| Server | `quay.io/openbao/openbao:2.6.2` | `server.image.registry`, `repository`, `tag` |
| Snapshot agent (optional) | `ghcr.io/openbao/openbao-snapshot-agent:0.3.0` | `snapshotAgent.image.repository`, `tag` |
| Your init containers or sidecars | — | in `extraInitContainers` / `extraContainers` |

```bash
skopeo copy docker://quay.io/openbao/openbao:2.6.2 \
  docker://registry.internal.example.com/openbao/openbao:2.6.2
skopeo copy docker://ghcr.io/openbao/openbao-snapshot-agent:0.3.0 \
  docker://registry.internal.example.com/openbao/openbao-snapshot-agent:0.3.0
```

### 6.2 Values

```yaml
global:
  imagePullSecrets:
    - internal-registry

server:
  image:
    registry: registry.internal.example.com
    repository: openbao/openbao
    tag: "2.6.2"

snapshotAgent:
  image:
    repository: registry.internal.example.com/openbao/openbao-snapshot-agent
    tag: "0.3.0"
```

The snapshot agent does not use `global.imagePullSecrets`. Add the pull
secret to its ServiceAccount:

```bash
kubectl -n openbao patch serviceaccount openbao-snapshot \
  -p '{"imagePullSecrets":[{"name":"internal-registry"}]}'
```

### 6.3 Chart and dependencies

```bash
helm package charts/openbao                    # openbao-0.28.3.tgz
helm push openbao-0.28.3.tgz oci://registry.internal.example.com/charts
```

The chart has no chart dependencies. CRDs for cert-manager, the Gateway API
and the Prometheus Operator come from their own packages, which you must
mirror too if you use them.

### 6.4 Things that need network access

| Feature | External access | Air-gapped alternative |
|---------|-----------------|------------------------|
| `retry_join` with `auto_join` | Cloud API | Use `leader_api_addr` (default) |
| Cloud KMS seals | Cloud KMS endpoint | Transit seal against an internal OpenBao, or an HSM |
| Plugins downloaded at start | Internet | Build them into an image ([§3.1](#31-install-a-plugin-binary)) |
| Snapshot agent | S3 | Internal MinIO or Ceph RGW |

---

## 7. Combining profiles and values files

Helm merges `-f` files from left to right; later files win. Maps are merged
key by key; lists and strings are replaced.

```bash
helm upgrade --install openbao ./charts/openbao -n openbao \
  -f charts/openbao/resource-profiles/medium.yaml \  # mode + resources
  -f values/common.yaml \                             # TLS, monitoring
  -f values/prod.yaml \                               # environment specifics
  --set server.image.tag=2.6.2
```

Things to keep in mind:

- Profiles also set the mode (`ha.enabled`, `ha.raft.enabled`,
  `dev_mode.enabled`). See the table in
  [04-server-workload.md §4](04-server-workload.md#profiles).
- `server.ha.raft.config` is a single string. A later file replaces it
  completely; it is not merged.
- `--set` on list items (`--set server.extraVolumes[0].name=x`) replaces the
  whole list from earlier files.
- Inspect the merged result before applying:

  ```bash
  helm template openbao ./charts/openbao -f a.yaml -f b.yaml --show-only templates/server-statefulset.yaml
  helm get values openbao -n openbao --all       # after install
  ```

---

## 8. Upgrades

### 8.1 What can change in place

| Change | `helm upgrade` result | Pods |
|--------|-----------------------|------|
| Image tag, env, resources, probes, config | Template updated | Restart needed (`OnDelete`) |
| `server.ha.replicas` | Applied | New pods created, or removed (remove Raft peers first) |
| Service, Ingress, Route, Gateway, monitoring settings | Applied | No restart |
| `dataStorage.size`, `storageClass`, `accessMode`, PVC labels | **Fails** (immutable `volumeClaimTemplates`) | See [05-storage.md §5](05-storage.md#5-resizing-volumes) |
| `podManagementPolicy`, `serviceName` | **Fails** (immutable) | Delete the StatefulSet with `--cascade=orphan`, then upgrade |
| `nameOverride`, release name | **Fails** or new objects | Do not change on a running release |
| standalone → HA Raft | Applied; `openbao-0` keeps its Raft data, new pods join it | Requires `ha.raft.setNodeId: true`. See [09-deployment-modes.md §8.2](09-deployment-modes.md#82-standalone-to-ha-with-raft) |
| Raft ↔ external, old `file` standalone → Raft | Data does not move by itself | See [09-deployment-modes.md §8](09-deployment-modes.md#8-migrating-between-modes) |

### 8.2 Upgrading OpenBao

1. Read the OpenBao release notes and upgrade guide for every version
   between the current and the target one.
2. Take a Raft snapshot (`bao operator raft snapshot save`, standalone and HA).
3. Update `server.image.tag` and run `helm upgrade`.
4. Restart the pods:
   - standalone: delete the pod, unseal;
   - HA: standbys first, one at a time; wait for each to be unsealed and
     healthy; `bao operator step-down` on the leader; restart it last.
5. Check `bao status` (version) and `bao operator raft list-peers` on all
   nodes.

With auto-unseal and `updateStrategyType: RollingUpdate`, step 4 happens
automatically, but in reverse ordinal order (`-2`, `-1`, `-0`), which may
restart the leader before all standbys are done. Use `OnDelete` and do it by
hand if the order matters.

Downgrades are not supported by OpenBao once the storage format has been
upgraded. Restore the snapshot instead.

### 8.3 Upgrading the chart

1. Compare the old and the new `values.yaml` and the release notes.
2. Render both versions with your values and compare:

   ```bash
   helm template openbao ./old-chart -f values.yaml > old.yaml
   helm template openbao ./charts/openbao -f values.yaml > new.yaml
   diff -u old.yaml new.yaml
   ```

   Or use the `helm diff` plugin against the live release.

3. Upgrade, then restart the pods if the StatefulSet template changed.

---

## 9. Dual-stack networking

```yaml
server:
  service:
    ipFamilyPolicy: PreferDualStack
    ipFamilies: [IPv4, IPv6]
ui:
  serviceIPFamilyPolicy: PreferDualStack
  serviceIPFamilies: [IPv4, IPv6]
```

`ipFamilyPolicy` and `ipFamilies` apply to the client, headless, active and
standby Services. The UI Service has its own values.

The default listener `address = "[::]:8200"` accepts IPv4 and IPv6 on
dual-stack nodes. `BAO_API_ADDR` defaults to `$(POD_IP)`, which is the
**primary** pod IP. On an IPv6-primary cluster this is an unbracketed IPv6
address, and `http://fd00::1:8200` is not a valid URL. Set an explicit
address that works in both cases:

```yaml
server:
  ha:
    apiAddr: "http://$(HOSTNAME).openbao-internal:8200"
```

`$(HOSTNAME)` is expanded by Kubernetes because `HOSTNAME` is defined
earlier in the environment list (verify). Use `https` when TLS is on.

---

## 10. Rendering and validating locally

```bash
# Lint against the schema
helm lint ./charts/openbao -f values.yaml

# Render everything
helm template openbao ./charts/openbao -n openbao -f values.yaml > rendered.yaml

# One template
helm template openbao ./charts/openbao -f values.yaml \
  --show-only templates/server-statefulset.yaml

# Gateway API or Prometheus CRDs are checked with .Capabilities
helm template openbao ./charts/openbao -f values.yaml \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
  --api-versions gateway.networking.k8s.io/v1/BackendTLSPolicy

# Validate against a cluster without applying
helm upgrade --install openbao ./charts/openbao -n openbao -f values.yaml --dry-run=server
kubectl apply --dry-run=server -f rendered.yaml
```

Unit tests for the chart are under `test/unit/*.bats` (bats-core, `yq`,
`helm`). Run them after changing templates:

```bash
bats test/unit
```

Several unit tests still refer to upstream values that this distribution
changed (for example `server.dev.enabled` instead of
`server.dev_mode.enabled`, and an in-memory dev server without PVCs). Expect
failures there until the tests are updated. See
[14-known-issues.md](14-known-issues.md).
