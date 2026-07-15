#!/usr/bin/env bats

load _helpers

# --- listener TLS config in the ConfigMap ---

@test "server/tls: listener disables TLS by default" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]' | tee /dev/stderr)
  [[ "${actual}" == *"tls_disable = 1"* ]]
  [[ "${actual}" != *"tls_cert_file"* ]]
}

@test "server/tls: listener enables TLS cert/key files when TLS on" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'global.tlsDisable=false' \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]' | tee /dev/stderr)
  [[ "${actual}" != *"tls_disable = 1"* ]]
  [[ "${actual}" == *'tls_cert_file = "/openbao/tls/tls.crt"'* ]]
  [[ "${actual}" == *'tls_key_file  = "/openbao/tls/tls.key"'* ]]
  [[ "${actual}" == *'tls_min_version = "tls12"'* ]]
}

@test "server/tls: raft listener enables TLS when TLS on" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'global.tlsDisable=false' \
      --set 'server.ha.enabled=true' \
      --set 'server.ha.raft.enabled=true' \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]' | tee /dev/stderr)
  [[ "${actual}" == *'tls_cert_file = "/openbao/tls/tls.crt"'* ]]
  [[ "${actual}" != *"tls_disable = 1"* ]]
}

@test "server/tls: cipher suites rendered when set" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'global.tlsDisable=false' \
      --set 'server.tls.tlsCipherSuites=TLS_AES_128_GCM_SHA256' \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]' | tee /dev/stderr)
  [[ "${actual}" == *'tls_cipher_suites = "TLS_AES_128_GCM_SHA256"'* ]]
}

# --- StatefulSet TLS mounts / env / probes ---

@test "server/tls: no tls volume by default" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-statefulset.yaml \
      . | tee /dev/stderr |
      yq -r '.spec.template.spec.volumes[] | select(.name == "tls") | .name' | tee /dev/stderr)
  [ "${actual}" = "" ]
}

@test "server/tls: tls volume mounted when TLS on" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-statefulset.yaml \
      --set 'global.tlsDisable=false' \
      . | tee /dev/stderr |
      yq -r '.spec.template.spec.volumes[] | select(.name == "tls") | .secret.secretName' | tee /dev/stderr)
  [ "${actual}" = "release-name-openbao-tls" ]

  local mount=$(helm template \
      --show-only templates/server-statefulset.yaml \
      --set 'global.tlsDisable=false' \
      . | yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "tls") | .mountPath')
  [ "${mount}" = "/openbao/tls" ]
}

@test "server/tls: BAO_CACERT set when TLS on" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-statefulset.yaml \
      --set 'global.tlsDisable=false' \
      . | tee /dev/stderr |
      yq -r '.spec.template.spec.containers[0].env[] | select(.name == "BAO_CACERT") | .value' | tee /dev/stderr)
  [ "${actual}" = "/openbao/tls/ca.crt" ]
}

@test "server/tls: BAO_CACERT absent when TLS off" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-statefulset.yaml \
      . | tee /dev/stderr |
      yq -r '.spec.template.spec.containers[0].env[] | select(.name == "BAO_CACERT") | .value' | tee /dev/stderr)
  [ "${actual}" = "" ]
}

@test "server/tls: readiness probe drops -tls-skip-verify when TLS on" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-statefulset.yaml \
      --set 'global.tlsDisable=false' \
      . | tee /dev/stderr |
      yq -r '.spec.template.spec.containers[0].readinessProbe.exec.command[2]' | tee /dev/stderr)
  [ "${actual}" = "bao status" ]
}

@test "server/tls: readiness probe keeps -tls-skip-verify when TLS off" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-statefulset.yaml \
      . | tee /dev/stderr |
      yq -r '.spec.template.spec.containers[0].readinessProbe.exec.command[2]' | tee /dev/stderr)
  [ "${actual}" = "bao status -tls-skip-verify" ]
}
