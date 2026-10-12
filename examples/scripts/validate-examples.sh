#!/usr/bin/env bash
# Copyright (c) Netcracker / Qubership contributors
# SPDX-License-Identifier: MPL-2.0
#
# validate-examples.sh - render every example (and the documented overlay
# combinations) with `helm lint` and `helm template`, and optionally validate
# the result against the Kubernetes API server.
#
# Usage:
#   examples/scripts/validate-examples.sh            # offline: lint + template
#   examples/scripts/validate-examples.sh --server   # also kubectl apply --dry-run=server
#
# CRDs are not available offline, so the script passes --api-versions for
# cert-manager and the Prometheus Operator. `helm template` does not check
# that a CRD exists; installation does.
#
# Exit code: number of failed cases (0 = all passed), capped at 125.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="$ROOT/charts/openbao"
EX="$ROOT/examples"
SERVER_DRY_RUN=0
[[ "${1:-}" == "--server" ]] && SERVER_DRY_RUN=1

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }
if (( SERVER_DRY_RUN )); then
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required for --server" >&2; exit 2; }
fi

API_VERSIONS=(
  --api-versions cert-manager.io/v1/Certificate
  --api-versions cert-manager.io/v1/Issuer
  --api-versions monitoring.coreos.com/v1/ServiceMonitor
  --api-versions monitoring.coreos.com/v1/PrometheusRule
  --api-versions route.openshift.io/v1/Route
)

# name | values files (space separated, relative to examples/) | expected kinds
CASES=(
  "dev|dev.yaml|StatefulSet ConfigMap Service"
  "standalone|standalone.yaml|StatefulSet Certificate Issuer"
  "standalone+snapshot|standalone.yaml overlays/snapshot-s3.yaml|CronJob"
  "ha-raft|ha-raft.yaml|StatefulSet PodDisruptionBudget Role Certificate"
  "ha-raft+monitoring|ha-raft.yaml overlays/monitoring.yaml|ServiceMonitor PrometheusRule"
  "ha-raft+snapshot|ha-raft.yaml overlays/snapshot-s3.yaml|CronJob"
  "ha-postgresql|ha-postgresql.yaml|StatefulSet PodDisruptionBudget"
  "external|external.yaml|ServiceAccount ClusterRoleBinding"
  "openshift|../charts/openbao/values.openshift.yaml ha-raft.yaml overlays/openshift-route.yaml|Route"
)

failed=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for case in "${CASES[@]}"; do
  IFS='|' read -r name files kinds <<<"$case"
  args=()
  for f in $files; do args+=(-f "$EX/$f"); done
  out="$tmp/$name.yaml"

  if ! helm lint "$CHART" "${args[@]}" >"$tmp/$name.lint" 2>&1; then
    echo "FAIL $name: helm lint"; sed 's/^/    /' "$tmp/$name.lint"; failed=$((failed + 1)); continue
  fi
  if ! helm template openbao "$CHART" -n openbao "${API_VERSIONS[@]}" "${args[@]}" >"$out" 2>"$tmp/$name.err"; then
    echo "FAIL $name: helm template"; sed 's/^/    /' "$tmp/$name.err"; failed=$((failed + 1)); continue
  fi

  missing=()
  for k in $kinds; do
    grep -q "^kind: $k\$" "$out" || missing+=("$k")
  done
  if (( ${#missing[@]} )); then
    echo "FAIL $name: missing kinds: ${missing[*]}"; failed=$((failed + 1)); continue
  fi

  if (( SERVER_DRY_RUN )); then
    if ! kubectl apply --dry-run=server -n openbao -f "$out" >"$tmp/$name.dry" 2>&1; then
      echo "FAIL $name: kubectl dry-run"; sed 's/^/    /' "$tmp/$name.dry"; failed=$((failed + 1)); continue
    fi
  fi
  echo "ok   $name"
done

# Negative cases: the chart must refuse these.
expect_fail() {
  local name="$1"; shift
  if helm template openbao "$CHART" "${API_VERSIONS[@]}" "$@" >/dev/null 2>&1; then
    echo "FAIL $name: expected render error"; failed=$((failed + 1))
  else
    echo "ok   $name (rejected)"
  fi
}
expect_fail "dev+ha" --set server.dev_mode.enabled=true --set server.ha.enabled=true
expect_fail "tls-material-with-tls-off" --set server.tls.secretName=foo
expect_fail "existingSecret-without-name" --set global.tlsDisable=false --set server.tls.source=existingSecret

(( failed == 0 )) && echo "all cases passed" || echo "$failed case(s) failed"
exit $(( failed > 125 ? 125 : failed ))
