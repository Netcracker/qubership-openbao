#!/usr/bin/env bats

load _helpers

@test "server/tls-certificate: disabled by default (tlsDisable=true)" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    . || echo "---") | tee /dev/stderr |
    yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "server/tls-certificate: created when TLS enabled with certManager" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    . || echo "---") | tee /dev/stderr |
    yq -r '.kind' | tee /dev/stderr)
  [ "${actual}" = "Certificate" ]
}

@test "server/tls-certificate: not created when source=existingSecret" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    --set 'server.tls.source=existingSecret' \
    . || echo "---") | tee /dev/stderr |
    yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "server/tls-certificate: default secretName is <fullname>-tls" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    .) | tee /dev/stderr |
    yq -r '.spec.secretName' | tee /dev/stderr)
  [ "${actual}" = "release-name-openbao-tls" ]
}

@test "server/tls-certificate: uses configured issuerRef" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    --set 'server.tls.certManager.issuerRef.name=my-issuer' \
    --set 'server.tls.certManager.issuerRef.kind=ClusterIssuer' \
    .) | tee /dev/stderr)

  local name=$(echo "$actual" | yq -r '.spec.issuerRef.name')
  [ "${name}" = "my-issuer" ]

  local kind=$(echo "$actual" | yq -r '.spec.issuerRef.kind')
  [ "${kind}" = "ClusterIssuer" ]
}

@test "server/tls-certificate: includes headless and wildcard SANs" {
  cd `chart_dir`
  local out=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    .) | tee /dev/stderr)

  local internal=$(echo "$out" | yq -r '.spec.dnsNames | contains(["release-name-openbao-internal"])')
  [ "${internal}" = "true" ]

  local wildcard=$(echo "$out" | yq -r '.spec.dnsNames | contains(["*.release-name-openbao-internal"])')
  [ "${wildcard}" = "true" ]
}

@test "server/tls-certificate: extraSans are appended" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    --set 'server.tls.certManager.extraSans[0]=vault.example.com' \
    .) | tee /dev/stderr |
    yq -r '.spec.dnsNames | contains(["vault.example.com"])' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

@test "server/tls-certificate: HA mode adds active/standby SANs" {
  cd `chart_dir`
  local actual=$( (helm template \
    --show-only templates/server-tls-certificate.yaml \
    --set 'global.tlsDisable=false' \
    --set 'server.ha.enabled=true' \
    --set 'server.ha.raft.enabled=true' \
    .) | tee /dev/stderr |
    yq -r '.spec.dnsNames | contains(["release-name-openbao-active"])' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}
