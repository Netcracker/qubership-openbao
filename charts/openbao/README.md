# openbao

![Version: 0.28.3](https://img.shields.io/badge/Version-0.28.3-informational?style=flat-square) ![AppVersion: v2.5.4](https://img.shields.io/badge/AppVersion-v2.5.4-informational?style=flat-square)

Official OpenBao Chart

**Homepage:** <https://github.com/openbao/openbao-helm>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| OpenBao | <openbao-security@lists.openssf.org> | <https://openbao.org> |

## Source Code

* <https://github.com/openbao/openbao-helm>

## Requirements

Kubernetes: `>= 1.30.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| extraObjects | list | `[]` |  |
| global.enabled | bool | `true` | enabled is the master enabled switch. Setting this to true or false will enable or disable all the components within this chart by default. |
| global.externalBaoAddr | string | `""` | External openbao server address for the injector and CSI provider to use. Setting this will disable deployment of an OpenBao server. |
| global.externalVaultAddr | string | `""` | Deprecated: Please use global.externalBaoAddr instead. |
| global.imagePullSecrets | list | `[]` | Image pull secret to use for registry authentication. Alternatively, the value may be specified as an array of strings. |
| global.namespace | string | `""` | The namespace to deploy to. Defaults to the `helm` installation namespace. |
| global.openshift | bool | `false` | If deploying to OpenShift |
| global.psp | object | `{"annotations":"seccomp.security.alpha.kubernetes.io/allowedProfileNames: docker/default,runtime/default\napparmor.security.beta.kubernetes.io/allowedProfileNames: runtime/default\nseccomp.security.alpha.kubernetes.io/defaultProfileName:  runtime/default\napparmor.security.beta.kubernetes.io/defaultProfileName:  runtime/default\n","enable":false}` | Create PodSecurityPolicy for pods |
| global.psp.annotations | string | `"seccomp.security.alpha.kubernetes.io/allowedProfileNames: docker/default,runtime/default\napparmor.security.beta.kubernetes.io/allowedProfileNames: runtime/default\nseccomp.security.alpha.kubernetes.io/defaultProfileName:  runtime/default\napparmor.security.beta.kubernetes.io/defaultProfileName:  runtime/default\n"` | Annotation for PodSecurityPolicy. This is a multi-line templated string map, and can also be set as YAML. |
| global.serverTelemetry.prometheusOperator | bool | `false` | Enable integration with the Prometheus Operator See the top level serverTelemetry section below before enabling this feature. |
| global.tlsDisable | bool | `true` | TLS for end-to-end encrypted transport |
| server.affinity | string | `"podAntiAffinity:\n  requiredDuringSchedulingIgnoredDuringExecution:\n    - labelSelector:\n        matchLabels:\n          app.kubernetes.io/name: {{ template \"openbao.name\" . }}\n          app.kubernetes.io/instance: \"{{ .Release.Name }}\"\n          component: server\n      topologyKey: kubernetes.io/hostname\n"` |  |
| server.annotations | object | `{}` |  |
| server.auditStorage.accessMode | string | `"ReadWriteOnce"` |  |
| server.auditStorage.annotations | object | `{}` |  |
| server.auditStorage.enabled | bool | `false` |  |
| server.auditStorage.labels | object | `{}` |  |
| server.auditStorage.mountPath | string | `"/openbao/audit"` |  |
| server.auditStorage.size | string | `"10Gi"` |  |
| server.auditStorage.storageClass | string | `nil` |  |
| server.authDelegator.enabled | bool | `true` |  |
| server.configAnnotation | bool | `false` |  |
| server.dataStorage.accessMode | string | `"ReadWriteOnce"` |  |
| server.dataStorage.annotations | object | `{}` |  |
| server.dataStorage.enabled | bool | `true` |  |
| server.dataStorage.labels | object | `{}` |  |
| server.dataStorage.mountPath | string | `"/openbao/data"` |  |
| server.dataStorage.size | string | `"10Gi"` |  |
| server.dataStorage.storageClass | string | `nil` |  |
| server.dev_mode.sealToken | string | `""` | Dev-mode static unseal key stored in the `bao-static-unseal-key` secret. If empty, a random key is generated. |
| server.dev_mode.devRootToken | string | `"root"` | Root token used by the dev-mode bootstrap. |
| server.dev_mode.config | string | *(multi-line)* | HCL config for the persistent dev server (file storage backend on the data PVC). |
| server.dev_mode.enabled | bool | `true` | Run OpenBao in persistent dev mode (file backend on the data PVC, auto-init and auto-unseal). Shipped default; development/testing only. |
| server.enabled | string | `"-"` |  |
| server.extraArgs | string | `""` | extraArgs is a string containing additional OpenBao server arguments. |
| server.extraContainers | string | `nil` |  |
| server.extraEnvironmentVars | object | `{}` |  |
| server.extraInitContainers | list | `[]` | extraInitContainers is a list of init containers. Specified as a YAML list. This is useful if you need to run a script to provision TLS certificates or write out configuration files in a dynamic way. |
| server.extraLabels | object | `{}` |  |
| server.extraPorts | list | `[]` | extraPorts is a list of extra ports. Specified as a YAML list. This is useful if you need to add additional ports to the statefulset in dynamic way. |
| server.extraSecretEnvironmentVars | list | `[]` |  |
| server.extraVolumes | list | `[]` |  |
| server.gateway.httpRoute.activeService | bool | `true` |  |
| server.gateway.httpRoute.annotations | object | `{}` |  |
| server.gateway.httpRoute.apiVersion | string | `"gateway.networking.k8s.io/v1"` |  |
| server.gateway.httpRoute.enabled | bool | `false` |  |
| server.gateway.httpRoute.filters | list | `[]` |  |
| server.gateway.httpRoute.hosts[0] | string | `"chart-example.local"` |  |
| server.gateway.httpRoute.labels | object | `{}` |  |
| server.gateway.httpRoute.matches.path.type | string | `"PathPrefix"` |  |
| server.gateway.httpRoute.matches.path.value | string | `"/"` |  |
| server.gateway.httpRoute.matches.timeouts | object | `{}` |  |
| server.gateway.httpRoute.parentRefs | list | `[]` |  |
| server.gateway.tlsPolicy.activeService | bool | `true` |  |
| server.gateway.tlsPolicy.annotations | object | `{}` |  |
| server.gateway.tlsPolicy.apiVersion | string | `"gateway.networking.k8s.io/v1"` |  |
| server.gateway.tlsPolicy.enabled | bool | `false` |  |
| server.gateway.tlsPolicy.labels | object | `{}` |  |
| server.gateway.tlsPolicy.targetRefs | list | `[]` |  |
| server.gateway.tlsPolicy.validation | object | `{}` |  |
| server.gateway.tlsRoute.activeService | bool | `true` |  |
| server.gateway.tlsRoute.annotations | object | `{}` |  |
| server.gateway.tlsRoute.apiVersion | string | `"gateway.networking.k8s.io/v1alpha3"` |  |
| server.gateway.tlsRoute.enabled | bool | `false` |  |
| server.gateway.tlsRoute.hosts | list | `[]` |  |
| server.gateway.tlsRoute.labels | object | `{}` |  |
| server.gateway.tlsRoute.parentRefs | list | `[]` |  |
| server.ha.apiAddr | string | `nil` |  |
| server.ha.clusterAddr | string | `nil` |  |
| server.ha.config | string | `"ui = true\n\nlistener \"tcp\" {\n  tls_disable = 1\n  address = \"[::]:8200\"\n  cluster_address = \"[::]:8201\"\n}\nstorage \"consul\" {\n  path = \"openbao\"\n  address = \"HOST_IP:8500\"\n}\n\nservice_registration \"kubernetes\" {}\n\n# Example configuration for using auto-unseal, using Google Cloud KMS. The\n# GKMS keys must already exist, and the cluster must have a service account\n# that is authorized to access GCP KMS.\n#seal \"gcpckms\" {\n#   project     = \"openbao-helm-dev-246514\"\n#   region      = \"global\"\n#   key_ring    = \"openbao-helm-unseal-kr\"\n#   crypto_key  = \"openbao-helm-unseal-key\"\n#}\n\n# Example configuration for enabling Prometheus metrics.\n# If you are using Prometheus Operator you can enable a ServiceMonitor resource below.\n# You may wish to enable unauthenticated metrics in the listener block above.\n#telemetry {\n#  prometheus_retention_time = \"30s\"\n#  disable_hostname = true\n#}\n"` |  |
| server.ha.disruptionBudget.enabled | bool | `true` |  |
| server.ha.disruptionBudget.maxUnavailable | string | `nil` |  |
| server.ha.enabled | bool | `false` |  |
| server.ha.raft.config | string | `"ui = true\n\nlistener \"tcp\" {\n  tls_disable = 1\n  address = \"[::]:8200\"\n  cluster_address = \"[::]:8201\"\n  # Enable unauthenticated metrics access (necessary for Prometheus Operator)\n  #telemetry {\n  #  unauthenticated_metrics_access = \"true\"\n  #}\n}\n\nstorage \"raft\" {\n  path = \"/openbao/data\"\n}\n\nservice_registration \"kubernetes\" {}\n"` |  |
| server.ha.raft.enabled | bool | `false` |  |
| server.ha.raft.setNodeId | bool | `false` |  |
| server.ha.replicas | int | `3` |  |
| server.hostAliases | list | `[]` |  |
| server.hostNetwork | bool | `false` |  |
| server.image.pullPolicy | string | `"IfNotPresent"` | image pull policy to use for server image. if tag is "latest", set to "Always" |
| server.image.registry | string | `"quay.io"` | image registry to use for server image |
| server.image.repository | string | `"openbao/openbao"` | image repo to use for server image |
| server.image.tag | string | `""` | image tag to use for server image - defaults to chart appVersion |
| server.ingress.activeService | bool | `true` |  |
| server.ingress.annotations | object | `{}` |  |
| server.ingress.enabled | bool | `false` |  |
| server.ingress.extraPaths | list | `[]` |  |
| server.ingress.hosts[0].host | string | `"chart-example.local"` |  |
| server.ingress.hosts[0].paths | list | `[]` |  |
| server.ingress.ingressClassName | string | `""` |  |
| server.ingress.labels | object | `{}` |  |
| server.ingress.pathType | string | `"Prefix"` |  |
| server.ingress.tls | list | `[]` |  |
| server.livenessProbe.enabled | bool | `false` |  |
| server.livenessProbe.execCommand | list | `[]` |  |
| server.livenessProbe.failureThreshold | int | `2` |  |
| server.livenessProbe.initialDelaySeconds | int | `60` |  |
| server.livenessProbe.path | string | `"/v1/sys/health?standbyok=true"` |  |
| server.livenessProbe.periodSeconds | int | `5` |  |
| server.livenessProbe.port | int | `8200` |  |
| server.livenessProbe.successThreshold | int | `1` |  |
| server.livenessProbe.timeoutSeconds | int | `3` |  |
| server.logFormat | string | `""` |  |
| server.logLevel | string | `""` |  |
| server.networkPolicy.egress | list | `[]` |  |
| server.networkPolicy.enabled | bool | `false` |  |
| server.networkPolicy.ingress[0].from[0].namespaceSelector | object | `{}` |  |
| server.networkPolicy.ingress[0].ports[0].port | int | `8200` |  |
| server.networkPolicy.ingress[0].ports[0].protocol | string | `"TCP"` |  |
| server.networkPolicy.ingress[0].ports[1].port | int | `8201` |  |
| server.networkPolicy.ingress[0].ports[1].protocol | string | `"TCP"` |  |
| server.nodeSelector | object | `{}` |  |
| server.persistentVolumeClaimRetentionPolicy | object | `{}` |  |
| server.podManagementPolicy | string | `"OrderedReady"` |  |
| server.postStart | list | `[]` |  |
| server.preStopSleepSeconds | int | `5` |  |
| server.priorityClassName | string | `""` |  |
| server.readinessProbe.enabled | bool | `true` |  |
| server.readinessProbe.failureThreshold | int | `2` |  |
| server.readinessProbe.initialDelaySeconds | int | `5` |  |
| server.readinessProbe.periodSeconds | int | `5` |  |
| server.readinessProbe.port | int | `8200` |  |
| server.readinessProbe.successThreshold | int | `1` |  |
| server.readinessProbe.timeoutSeconds | int | `3` |  |
| server.resources | object | `{}` |  |
| server.route.activeService | bool | `true` |  |
| server.route.annotations | object | `{}` |  |
| server.route.enabled | bool | `false` |  |
| server.route.host | string | `"chart-example.local"` |  |
| server.route.labels | object | `{}` |  |
| server.route.tls.termination | string | `"passthrough"` |  |
| server.service.active.annotations | object | `{}` |  |
| server.service.active.enabled | bool | `true` |  |
| server.service.active.extraLabels | object | `{}` |  |
| server.service.annotations | object | `{}` |  |
| server.service.enabled | bool | `true` |  |
| server.service.externalTrafficPolicy | string | `"Cluster"` |  |
| server.service.extraLabels | object | `{}` |  |
| server.service.extraPorts | list | `[]` | extraPorts is a list of extra ports. Specified as a YAML list. This is useful if you need to add additional ports to the server service in dynamic way. |
| server.service.headless.annotations | object | `{}` |  |
| server.service.instanceSelector.enabled | bool | `true` |  |
| server.service.ipFamilies | list | `[]` |  |
| server.service.ipFamilyPolicy | string | `""` |  |
| server.service.port | int | `8200` |  |
| server.service.publishNotReadyAddresses | bool | `true` |  |
| server.service.standby.annotations | object | `{}` |  |
| server.service.standby.enabled | bool | `true` |  |
| server.service.standby.extraLabels | object | `{}` |  |
| server.service.targetPort | int | `8200` |  |
| server.serviceAccount.annotations | object | `{}` |  |
| server.serviceAccount.create | bool | `true` |  |
| server.serviceAccount.createSecret | bool | `false` |  |
| server.serviceAccount.extraLabels | object | `{}` |  |
| server.serviceAccount.name | string | `""` |  |
| server.serviceAccount.serviceDiscovery.enabled | bool | `true` |  |
| server.shareProcessNamespace | bool | `false` | shareProcessNamespace enables process namespace sharing between OpenBao and the extraContainers This is useful if OpenBao must be signaled, e.g. to send a SIGHUP for a log rotation |
| server.standalone.config | string | (HCL) | Standalone server HCL config. The `listener "tcp"` block is templated: it renders `tls_disable = 1` when `global.tlsDisable=true`, otherwise `tls_cert_file`/`tls_key_file`/`tls_min_version` (and `tls_cipher_suites` when set) from `server.tls.*`. |
| server.standalone.enabled | string | `"-"` |  |
| server.statefulSet.annotations | object | `{}` |  |
| server.statefulSet.securityContext.container | object | `{}` |  |
| server.statefulSet.securityContext.pod | object | `{}` |  |
| server.terminationGracePeriodSeconds | int | `10` |  |
| server.tls.source | string | `"certManager"` | How the server TLS certificate is provisioned: `certManager`, `rawCerts` or `existingSecret`. Only effective when `global.tlsDisable=false`. |
| server.tls.secretName | string | `""` | Name of the kubernetes.io/tls secret with the server cert. Defaults to `<fullname>-tls`. |
| server.tls.certs.crt | string | `""` | Inline PEM certificate (source=rawCerts). |
| server.tls.certs.key | string | `""` | Inline PEM private key (source=rawCerts). |
| server.tls.certs.ca | string | `""` | Optional inline PEM CA certificate written to `ca.crt` (source=rawCerts). |
| server.tls.certKey | string | `"tls.crt"` | Key of the server certificate inside the TLS secret. |
| server.tls.keyKey | string | `"tls.key"` | Key of the private key inside the TLS secret. |
| server.tls.caKey | string | `"ca.crt"` | Key of the CA certificate used for `BAO_CACERT`, probes, metrics and snapshot agent. |
| server.tls.mountPath | string | `"/openbao/tls"` | Directory the TLS secret is mounted into inside the server container. |
| server.tls.tlsMinVersion | string | `"tls12"` | Minimum accepted TLS version for the listener (tls10/tls11/tls12/tls13). |
| server.tls.tlsCipherSuites | string | `""` | Optional cipher suite list for the listener (TLS 1.2 only). |
| server.tls.certManager.generateIssuer | bool | `false` | When true, the chart creates a self-signed `Issuer` named `<fullname>-issuer` and uses it to sign the cert (source=certManager). Ignored when `clusterIssuerName` is set. |
| server.tls.certManager.clusterIssuerName | string | `""` | Name of an existing `ClusterIssuer` to sign the cert. Takes precedence over `generateIssuer` and `issuerRef`. |
| server.tls.certManager.issuerRef.name | string | `"openbao-ca-issuer"` | cert-manager issuer name (used when `generateIssuer` is false and `clusterIssuerName` is empty). |
| server.tls.certManager.issuerRef.kind | string | `"Issuer"` | cert-manager issuer kind (Issuer or ClusterIssuer). |
| server.tls.certManager.issuerRef.group | string | `"cert-manager.io"` | cert-manager issuer API group. |
| server.tls.certManager.duration | string | `"8760h"` | Requested certificate duration. Takes precedence over `durationDays`. |
| server.tls.certManager.durationDays | int | `365` | Requested certificate duration in days (`durationDays * 24h`), used when `duration` is empty. |
| server.tls.certManager.renewBefore | string | `"720h"` | Renew the certificate this long before expiry. |
| server.tls.certManager.privateKey | object | `{"algorithm":"ECDSA","rotationPolicy":"Always","size":256}` | Private key configuration for the generated certificate (ECDSA; set to RSA/PKCS1/2048 for parity with seaweedfs). |
| server.tls.certManager.extraSans | list | `[]` | Additional DNS SANs to add to the certificate. |
| server.tls.certManager.extraIpSans | list | `[]` | Additional IP SANs to add to the certificate. |
| server.tls.certManager.subjectAlternativeName.additionalDnsNames | object | `{}` | Seaweedfs-compatible additional DNS SANs, merged with `extraSans`. |
| server.tls.certManager.subjectAlternativeName.additionalIpAddresses | object | `{}` | Seaweedfs-compatible additional IP SANs, merged with `extraIpSans`. |
| server.tolerations | list | `[]` |  |
| server.topologySpreadConstraints | list | `[]` |  |
| server.updateStrategyType | string | `"OnDelete"` |  |
| server.volumeMounts | string | `nil` |  |
| server.volumes | string | `nil` |  |
| serverTelemetry.grafanaDashboard.defaultLabel | bool | `true` |  |
| serverTelemetry.grafanaDashboard.enabled | bool | `false` |  |
| serverTelemetry.grafanaDashboard.extraAnnotations | object | `{}` |  |
| serverTelemetry.grafanaDashboard.extraLabel | object | `{}` |  |
| serverTelemetry.grafanaDashboard.namespace | string | `""` |  |
| serverTelemetry.prometheusRules.enabled | bool | `false` |  |
| serverTelemetry.prometheusRules.rules | list | `[]` |  |
| serverTelemetry.prometheusRules.selectors | object | `{}` |  |
| serverTelemetry.serviceMonitor.authorization | object | `{}` |  |
| serverTelemetry.serviceMonitor.enabled | bool | `false` |  |
| serverTelemetry.serviceMonitor.insecureSkipVerify | bool | `false` | When TLS is enabled and `tlsConfig` is unset, skip metrics endpoint certificate verification if true; otherwise verify against the server TLS CA. |
| serverTelemetry.serviceMonitor.interval | string | `"30s"` |  |
| serverTelemetry.serviceMonitor.port | string | `""` | Port which Prometheus uses when scraping metrics. If empty will use `openbao.scheme` helper for its value |
| serverTelemetry.serviceMonitor.scheme | string | `""` | scheme to use when Prometheus scrapes metrics. If empty will use `openbao.scheme` helper for its value |
| serverTelemetry.serviceMonitor.scrapeClass | string | `""` |  |
| serverTelemetry.serviceMonitor.scrapeTimeout | string | `"10s"` |  |
| serverTelemetry.serviceMonitor.selectors | object | `{}` |  |
| serverTelemetry.serviceMonitor.tlsConfig | object | `{}` |  |
| snapshotAgent.annotations | object | `{}` |  |
| snapshotAgent.config.baoAuthPath | string | `"kubernetes"` |  |
| snapshotAgent.config.baoRole | string | `"snapshot"` |  |
| snapshotAgent.config.s3Bucket | string | `"openbao-snapshots"` |  |
| snapshotAgent.config.s3ExpireDays | string | `"14"` |  |
| snapshotAgent.config.s3Host | string | `"s3.eu-east-1.amazonaws.com"` |  |
| snapshotAgent.config.s3Uri | string | `"s3://openbao-snapshots"` |  |
| snapshotAgent.config.s3cmdExtraFlag | string | `"-v"` |  |
| snapshotAgent.enabled | bool | `false` |  |
| snapshotAgent.extraEnvironmentVars | object | `{}` | Map of extra environment variables to set in the snapshot-agent cronjob |
| snapshotAgent.extraSecretEnvironmentVars | list | `[]` | List of extra environment variables to set in the snapshot-agent cronjob These variables take value from existing Secret objects. |
| snapshotAgent.extraVolumeMounts | list | `[]` | List of additional volumeMounts for the snapshot cronjob container. |
| snapshotAgent.extraVolumes | list | `[]` | List of extraVolumes made available to the snapshot cronjob container. |
| snapshotAgent.image.repository | string | `"ghcr.io/openbao/openbao-snapshot-agent"` |  |
| snapshotAgent.image.tag | string | `"0.3.0"` |  |
| snapshotAgent.resources | object | `{}` |  |
| snapshotAgent.restartPolicy | string | `"OnFailure"` |  |
| snapshotAgent.s3CredentialsSecret | string | `"my-s3-credentials"` |  |
| snapshotAgent.schedule | string | `"*/15 * * * *"` |  |
| snapshotAgent.securityContext.container | object | `{}` |  |
| snapshotAgent.securityContext.pod | object | `{}` |  |
| snapshotAgent.serviceAccount.annotations | object | `{}` |  |
| snapshotAgent.serviceAccount.create | bool | `true` |  |
| snapshotAgent.serviceAccount.extraLabels | object | `{}` |  |
| snapshotAgent.serviceAccount.name | string | `""` |  |
| snapshotAgent.tolerations | list | `[]` |  |
| ui.activeOpenbaoPodOnly | bool | `false` |  |
| ui.annotations | object | `{}` |  |
| ui.enabled | bool | `false` |  |
| ui.externalPort | int | `8200` |  |
| ui.externalTrafficPolicy | string | `"Cluster"` |  |
| ui.extraLabels | object | `{}` |  |
| ui.publishNotReadyAddresses | bool | `true` |  |
| ui.serviceIPFamilies | list | `[]` |  |
| ui.serviceIPFamilyPolicy | string | `""` |  |
| ui.serviceNodePort | string | `nil` |  |
| ui.serviceType | string | `"ClusterIP"` |  |
| ui.targetPort | int | `8200` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
