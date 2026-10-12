#!/usr/bin/env bats

load _helpers

@test "server/ConfigMap: enabled by default" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      . | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "true" ]

  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.ha.enabled=true' \
      . | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "true" ]

  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.ha.enabled=true' \
      --set 'server.ha.raft.enabled=true' \
      . | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "true" ]

  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.standalone.enabled=true' \
      . | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

@test "server/ConfigMap: raft config disabled by default" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.ha.enabled=true' \
      . | tee /dev/stderr |
      grep "raft" | yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" != "true" ]
}

@test "server/ConfigMap: raft config can be enabled" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.ha.enabled=true' \
      --set 'server.ha.raft.enabled=true' \
      . | tee /dev/stderr |
      grep "raft" | yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}


@test "server/ConfigMap: disabled by server.dev.enabled true" {
  cd `chart_dir`
  local actual=$( (helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.dev.enabled=true' \
      . || echo "---") | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "server/ConfigMap: disable with global.enabled" {
  cd `chart_dir`
  local actual=$( (helm template \
      --show-only templates/server-config-configmap.yaml  \
      --set 'global.enabled=false' \
      . || echo "---") | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "server/ConfigMap: namespace" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --namespace foo \
      . | tee /dev/stderr |
      yq -r '.metadata.namespace' | tee /dev/stderr)
  [ "${actual}" = "foo" ]
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'global.namespace=bar' \
      --namespace foo \
      . | tee /dev/stderr |
      yq -r '.metadata.namespace' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

@test "server/ConfigMap: standalone extraConfig is set" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml  \
      --set 'server.standalone.enabled=true' \
      --set 'server.standalone.config="{\"hello\": \"world\"}"' \
      . | tee /dev/stderr |
      yq '.data["extraconfig-from-values.hcl"] | match("world") | length' | tee /dev/stderr)
  [ ! -z "${actual}" ]

  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml  \
      --set 'server.standalone.enabled=true' \
      --set 'server.standalone.config="{\"foo\": \"bar\"}"' \
      . | tee /dev/stderr |
      yq '.data["extraconfig-from-values.hcl"] | match("bar") | length' | tee /dev/stderr)
  [ ! -z "${actual}" ]
}

#--------------------------------------------------------------------
# standalone = single-node integrated Raft storage

@test "server/ConfigMap: standalone default uses single-node raft storage" {
  cd `chart_dir`
  local hcl=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.dev_mode.enabled=false' \
      --set 'server.standalone.enabled=true' \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]')
  echo "$hcl" | grep -q 'storage "raft"'
  echo "$hcl" | grep -q 'path = "/openbao/data"'
  [ -z "$(echo "$hcl" | grep 'storage "file"')" ]
  [ -z "$(echo "$hcl" | grep 'retry_join')" ]
  [ -z "$(echo "$hcl" | grep 'service_registration')" ]
}

@test "server/ConfigMap: standalone raft path follows dataStorage.mountPath" {
  cd `chart_dir`
  local hcl=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.dev_mode.enabled=false' \
      --set 'server.dataStorage.mountPath=/bao/raft' \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]')
  echo "$hcl" | grep -q 'path = "/bao/raft"'
}

@test "server/ConfigMap: default dev mode also uses raft storage" {
  cd `chart_dir`
  local hcl=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      . | tee /dev/stderr |
      yq -r '.data["extraconfig-from-values.hcl"]')
  echo "$hcl" | grep -q 'storage "raft"'
}

@test "server/ConfigMap: ha extraConfig is set" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml  \
      --set 'server.ha.enabled=true' \
      --set 'server.ha.config="{\"hello\": \"world\"}"' \
      . | tee /dev/stderr |
      yq '.data["extraconfig-from-values.hcl"] | match("world") | length' | tee /dev/stderr)
  [ ! -z "${actual}" ]

  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml  \
      --set 'server.ha.enabled=true' \
      --set 'server.ha.config="{\"foo\": \"bar\"}"' \
      . | tee /dev/stderr |
      yq '.data["extraconfig-from-values.hcl"] | match("bar") | length' | tee /dev/stderr)
  [ ! -z "${actual}" ]
}

@test "server/ConfigMap: disabled by global.externalVaultAddr" {
  cd `chart_dir`
  local actual=$( (helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'global.externalVaultAddr=http://openbao-outside' \
      . || echo "---") | tee /dev/stderr |
      yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "server/ConfigMap: config checksum annotation defaults to off" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      . | tee /dev/stderr |
      yq '.metadata.annotations["vault.hashicorp.com/config-checksum"] == null' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

@test "server/ConfigMap: config checksum annotation can be enabled" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/server-config-configmap.yaml \
      --set 'server.configAnnotation=true' \
      . | tee /dev/stderr |
      yq '.metadata.annotations["vault.hashicorp.com/config-checksum"] == null' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}
