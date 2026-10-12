#!/usr/bin/env bats

load _helpers

# These tests are just to verify there is a schema file used in the chart. Since
# .enabled is defined as a boolean type for each of the top-level blocks in the
# schema, setting it as a string fails 'helm template'.
@test "schema: csi enabled datatype" {
  cd `chart_dir`
  run helm template . --set csi.enabled="123"
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "- at '/csi/enabled': got number, want boolean or string" ]

  run helm template . --set csi.enabled=true
  [ "$status" -eq 0 ]
}

@test "schema: injector enabled datatype" {
  cd `chart_dir`
  run helm template . --set injector.enabled="123"
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "- at '/injector/enabled': got number, want boolean or string" ]

  run helm template . --set injector.enabled=true
  [ "$status" -eq 0 ]
}

@test "schema: server enabled datatype" {
  cd `chart_dir`
  run helm template . --set server.enabled="123"
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "- at '/server/enabled': got number, want boolean or string" ]

  run helm template . --set server.enabled=true
  [ "$status" -eq 0 ]
}

@test "schema: ui enabled datatype" {
  cd `chart_dir`
  run helm template . --set ui.enabled="123"
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "- at '/ui/enabled': got number, want boolean or string" ]

  run helm template . --set ui.enabled=true
  [ "$status" -eq 0 ]
}

@test "schema: storageClass can be null" {
  cd `chart_dir`
  run helm template . --set server.dataStorage.storageClass=null
  [ "$status" -eq 0 ]
}

@test "mode: dev_mode and ha.enabled are mutually exclusive" {
  cd `chart_dir`
  run helm template . \
      --set 'server.dev_mode.enabled=true' \
      --set 'server.ha.enabled=true'
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "mode: dev_mode alone still renders" {
  cd `chart_dir`
  run helm template . \
      --set 'server.dev_mode.enabled=true' \
      --set 'server.ha.enabled=false'
  [ "$status" -eq 0 ]
}

@test "mode: ha alone still renders" {
  cd `chart_dir`
  run helm template . \
      --set 'server.dev_mode.enabled=false' \
      --set 'server.ha.enabled=true'
  [ "$status" -eq 0 ]
}

# CORR-02 regression coverage: the schema must accept every form the
# templates actually render (string OR object/array/null), not just one.
# Each of these previously failed with "values don't meet the specifications
# of the schema(s)" even though the underlying template (openbao.affinity,
# openbao.tolerations, openbao.annotations.render.4/8, openbao.mode, etc.)
# explicitly supports both forms via a `typeOf` check.

@test "schema: server.standalone.enabled accepts boolean" {
  cd `chart_dir`
  run helm template . --set server.standalone.enabled=true
  [ "$status" -eq 0 ]
}

@test "schema: server.enabled accepts boolean" {
  cd `chart_dir`
  run helm template . --set server.enabled=true
  [ "$status" -eq 0 ]
}

@test "schema: server.extraContainers accepts an array" {
  cd `chart_dir`
  run helm template . --set-json 'server.extraContainers=[{"name":"x","image":"y"}]'
  [ "$status" -eq 0 ]
}

@test "schema: server.ha.apiAddr and server.ha.clusterAddr accept a string" {
  cd `chart_dir`
  run helm template . \
      --set 'server.ha.enabled=true' \
      --set 'server.dev_mode.enabled=false' \
      --set 'server.ha.apiAddr=https://example.com:8200' \
      --set 'server.ha.clusterAddr=https://example.com:8201'
  [ "$status" -eq 0 ]
}

@test "schema: ui.serviceNodePort accepts an integer" {
  cd `chart_dir`
  run helm template . --set ui.serviceNodePort=30001
  [ "$status" -eq 0 ]
}

@test "schema: server.annotations accepts a templated string" {
  cd `chart_dir`
  run helm template . --set 'server.annotations=foo: bar'
  [ "$status" -eq 0 ]
}

@test "schema: server.affinity accepts a YAML map" {
  cd `chart_dir`
  run helm template . --set-json 'server.affinity={"podAntiAffinity":{}}'
  [ "$status" -eq 0 ]
}

@test "schema: server.tolerations accepts a templated string" {
  cd `chart_dir`
  run helm template . --set 'server.tolerations=- key: foo'
  [ "$status" -eq 0 ]
}

@test "schema: server.nodeSelector accepts a templated string" {
  cd `chart_dir`
  run helm template . --set 'server.nodeSelector=foo: bar'
  [ "$status" -eq 0 ]
}

@test "schema: server.topologySpreadConstraints accepts a templated string" {
  cd `chart_dir`
  run helm template . --set 'server.topologySpreadConstraints=- maxSkew: 1'
  [ "$status" -eq 0 ]
}

@test "schema: server.statefulSet.securityContext.pod/container accept a templated string" {
  cd `chart_dir`
  run helm template . \
      --set 'server.statefulSet.securityContext.pod=runAsNonRoot: true' \
      --set 'server.statefulSet.securityContext.container=allowPrivilegeEscalation: false'
  [ "$status" -eq 0 ]
}

@test "schema: server.standalone.config accepts an object" {
  cd `chart_dir`
  run helm template . --set-json 'server.standalone.config={"ui":true}'
  [ "$status" -eq 0 ]
}

@test "schema: examples/standalone.yaml installs" {
  cd `chart_dir`
  run helm template . -f ../../examples/standalone.yaml
  [ "$status" -eq 0 ]
}
