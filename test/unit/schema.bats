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
