#!/usr/bin/env bats
#
# Render tests for the files in examples/. They protect the examples against
# chart changes that would break them. Run with: bats test/unit/examples.bats

load _helpers

# Offline renders need the CRD API versions that the examples use.
api_versions() {
  echo "--api-versions cert-manager.io/v1/Certificate" \
       "--api-versions cert-manager.io/v1/Issuer" \
       "--api-versions monitoring.coreos.com/v1/ServiceMonitor" \
       "--api-versions monitoring.coreos.com/v1/PrometheusRule" \
       "--api-versions route.openshift.io/v1/Route"
}

examples_dir() {
  echo ${BATS_TEST_DIRNAME}/../../examples
}

#--------------------------------------------------------------------
# dev.yaml

@test "examples/dev: renders with TLS off and dev bootstrap hook" {
  cd `chart_dir`
  local sts=$(helm template . $(api_versions) -f $(examples_dir)/dev.yaml \
      --show-only templates/server-statefulset.yaml)
  [ "$(echo "$sts" | yq -r '.spec.replicas')" = "1" ]
  [ "$(echo "$sts" | yq -r '.spec.template.spec.containers[0].env[] | select(.name=="BAO_ADDR") | .value')" = "http://127.0.0.1:8200" ]
  echo "$sts" | yq -r '.spec.template.spec.containers[0].lifecycle.postStart.exec.command[2]' | grep -q 'bootstrap-keys.json'
}

@test "examples/dev: no TLS objects are rendered" {
  cd `chart_dir`
  local out=$(helm template . $(api_versions) -f $(examples_dir)/dev.yaml)
  [ -z "$(echo "$out" | grep '^kind: Certificate$')" ]
}

#--------------------------------------------------------------------
# standalone.yaml

@test "examples/standalone: TLS listener and certificate" {
  cd `chart_dir`
  local cm=$(helm template . $(api_versions) -f $(examples_dir)/standalone.yaml \
      --show-only templates/server-config-configmap.yaml | yq -r '.data["extraconfig-from-values.hcl"]')
  echo "$cm" | grep -q 'tls_cert_file = "/openbao/tls/tls.crt"'
  echo "$cm" | grep -q 'storage "file"'

  helm template . $(api_versions) -f $(examples_dir)/standalone.yaml \
      --show-only templates/server-tls-certificate.yaml | yq -e '.kind == "Certificate"'
}

@test "examples/standalone: drops all capabilities" {
  cd `chart_dir`
  local actual=$(helm template . $(api_versions) -f $(examples_dir)/standalone.yaml \
      --show-only templates/server-statefulset.yaml |
      yq -r '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]')
  [ "${actual}" = "ALL" ]
}

#--------------------------------------------------------------------
# ha-raft.yaml

@test "examples/ha-raft: one retry_join per replica with CA" {
  cd `chart_dir`
  local cm=$(helm template openbao . $(api_versions) -f $(examples_dir)/ha-raft.yaml \
      --set server.ha.replicas=5 \
      --show-only templates/server-config-configmap.yaml | yq -r '.data["extraconfig-from-values.hcl"]')
  [ "$(echo "$cm" | grep -c 'retry_join {')" = "5" ]
  echo "$cm" | grep -q 'leader_api_addr = "https://openbao-4.openbao-internal:8200"'
  echo "$cm" | grep -q 'leader_ca_cert_file = "/openbao/tls/ca.crt"'
  echo "$cm" | grep -q 'service_registration "kubernetes"'
}

@test "examples/ha-raft: PDB, active service and node id" {
  cd `chart_dir`
  local out=$(helm template openbao . $(api_versions) -f $(examples_dir)/ha-raft.yaml)
  echo "$out" | grep -q '^kind: PodDisruptionBudget$'
  echo "$out" | grep -q 'name: openbao-active$'
  helm template openbao . $(api_versions) -f $(examples_dir)/ha-raft.yaml \
      --show-only templates/server-statefulset.yaml |
      yq -e '.spec.template.spec.containers[0].env[] | select(.name=="BAO_RAFT_NODE_ID")'
}

@test "examples/ha-raft + monitoring overlay: ServiceMonitor and rules" {
  cd `chart_dir`
  local out=$(helm template openbao . $(api_versions) \
      -f $(examples_dir)/ha-raft.yaml -f $(examples_dir)/overlays/monitoring.yaml)
  echo "$out" | grep -q '^kind: ServiceMonitor$'
  echo "$out" | grep -q '^kind: PrometheusRule$'
  echo "$out" | grep -q 'alert: OpenBaoSealed'
}

@test "examples/ha-raft + snapshot overlay: CronJob targets the active service" {
  cd `chart_dir`
  local addr=$(helm template openbao . -n openbao $(api_versions) \
      -f $(examples_dir)/ha-raft.yaml -f $(examples_dir)/overlays/snapshot-s3.yaml \
      --show-only templates/snapshotagent-configmap.yaml | yq -r '.data.BAO_ADDR')
  [ "${addr}" = "https://openbao-active.openbao.svc:8200" ]
}

#--------------------------------------------------------------------
# ha-postgresql.yaml

@test "examples/ha-postgresql: postgresql storage, no data PVC, URL from secret" {
  cd `chart_dir`
  local cm=$(helm template . $(api_versions) -f $(examples_dir)/ha-postgresql.yaml \
      --show-only templates/server-config-configmap.yaml | yq -r '.data["extraconfig-from-values.hcl"]')
  echo "$cm" | grep -q 'storage "postgresql"'
  # `! cmd` does not fail a bats test unless it is the last command.
  [ -z "$(echo "$cm" | grep consul)" ]

  local sts=$(helm template . $(api_versions) -f $(examples_dir)/ha-postgresql.yaml \
      --show-only templates/server-statefulset.yaml)
  [ "$(echo "$sts" | yq -r '[.spec.volumeClaimTemplates[].metadata.name] | join(",")')" = "audit" ]
  [ "$(echo "$sts" | yq -r '.spec.template.spec.containers[0].env[] | select(.name=="BAO_PG_CONNECTION_URL") | .valueFrom.secretKeyRef.name')" = "openbao-pg" ]
}

#--------------------------------------------------------------------
# external.yaml

@test "examples/external: no server, reviewer service account" {
  cd `chart_dir`
  local out=$(helm template openbao . $(api_versions) -f $(examples_dir)/external.yaml)
  [ -z "$(echo "$out" | grep '^kind: StatefulSet$')" ]
  echo "$out" | grep -q '^kind: ClusterRoleBinding$'
  echo "$out" | grep -q 'type: kubernetes.io/service-account-token'
}

#--------------------------------------------------------------------
# openshift overlay

@test "examples/openshift-route: passthrough route to the active service" {
  cd `chart_dir`
  local route=$(helm template openbao . $(api_versions) \
      -f values.openshift.yaml \
      -f $(examples_dir)/ha-raft.yaml \
      -f $(examples_dir)/overlays/openshift-route.yaml \
      --show-only templates/server-route.yaml)
  [ "$(echo "$route" | yq -r '.spec.tls.termination')" = "passthrough" ]
  [ "$(echo "$route" | yq -r '.spec.host')" = "openbao.apps.example.com" ]
}
