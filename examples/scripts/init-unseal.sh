#!/usr/bin/env bash
# Copyright (c) Netcracker / Qubership contributors
# SPDX-License-Identifier: MPL-2.0
#
# init-unseal.sh - initialize and unseal an OpenBao release installed with
# the qubership-openbao chart (standalone single-node Raft, HA with Raft, or
# HA with an external backend), using Shamir unseal keys.
#
# What it does:
#   1. Waits for pod <release>-0 to run.
#   2. If the server is not initialized, runs `bao operator init` and stores
#      the JSON output in a local file with mode 0600 (never overwrites).
#   3. Unseals every pod with the first <threshold> keys from that file.
#      In HA with Raft, followers join the leader through retry_join (or,
#      with --join, through an explicit `bao operator raft join`).
#   4. Waits until every pod is Ready and prints a summary.
#
# Keys are sent to the pods on stdin (`bao write sys/unseal key=-`), so they
# do not appear in process arguments or shell history.
#
# Do not use it for dev mode (the chart bootstraps itself) or with auto-unseal
# (use `bao operator init -recovery-shares ...` once instead).
#
# Requirements: bash 4+, kubectl, jq. Runs on Linux, macOS, WSL, Git Bash.
#
# Exit codes: 0 success, 1 usage error, 2 missing dependency,
#             3 pod/cluster error, 4 init/unseal error.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"

# ----------------------------------------------------------------- defaults
NAMESPACE="openbao"
RELEASE="openbao"
FULLNAME=""            # defaults to RELEASE (release names containing "openbao")
PODS=1
KEY_SHARES=5
KEY_THRESHOLD=3
KEYS_FILE=""
TIMEOUT=300
RAFT=1
EXPLICIT_JOIN=0

# ------------------------------------------------------------------ helpers
log()  { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$SCRIPT_NAME" "$*" >&2; }
die()  { local code="$1"; shift; log "ERROR: $*"; exit "$code"; }

on_error() {
  local code=$? line=$1
  log "ERROR: command failed (exit $code) at line $line: ${BASH_COMMAND}"
  exit "$code"
}
trap 'on_error $LINENO' ERR

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  -n, --namespace NAME     Kubernetes namespace           (default: $NAMESPACE)
  -r, --release NAME       Helm release name              (default: $RELEASE)
  -f, --fullname NAME      Resource prefix <fullname>     (default: release name)
  -p, --pods N             Number of server pods          (default: $PODS)
  -s, --key-shares N       Shamir key shares              (default: $KEY_SHARES)
  -t, --key-threshold N    Shamir key threshold           (default: $KEY_THRESHOLD)
  -k, --keys-file PATH     Init output file               (default: ./<fullname>-init.json)
      --timeout SECONDS    Wait timeout per step          (default: $TIMEOUT)
      --no-raft            External storage backend (no raft join)
      --join               Run 'bao operator raft join' before unsealing followers
  -h, --help               Show this help

Examples:
  $SCRIPT_NAME -n openbao -r openbao                 # standalone (single-node Raft)
  $SCRIPT_NAME -n openbao -r openbao -p 3            # HA with Raft
  $SCRIPT_NAME -n openbao -r openbao -p 2 --no-raft  # HA with PostgreSQL
EOF
}

require_int() {
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 )) || die 1 "$1 must be a positive integer, got '$2'"
}

# Run a command inside a pod's openbao container.
bao_exec() {
  local pod="$1"; shift
  kubectl -n "$NAMESPACE" exec -i "$pod" -c openbao -- "$@"
}

# Print `bao status -format=json` for a pod. `bao status` exits 2 when the
# server is sealed; that is a valid answer, not an error.
bao_status_json() {
  local pod="$1" out rc=0
  out="$(bao_exec "$pod" bao status -format=json 2>/dev/null)" || rc=$?
  if (( rc != 0 && rc != 2 )) || [[ -z "$out" ]]; then
    return 1
  fi
  printf '%s' "$out"
}

wait_for_pod_running() {
  local pod="$1"
  log "waiting for pod $pod to run (timeout ${TIMEOUT}s)"
  local deadline=$(( SECONDS + TIMEOUT ))
  until kubectl -n "$NAMESPACE" get pod "$pod" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die 3 "pod $pod was not created. With podManagementPolicy=OrderedReady the previous pod must be Ready first."
    sleep 3
  done
  kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Running \
    "pod/$pod" --timeout="${TIMEOUT}s" >/dev/null \
    || die 3 "pod $pod is not Running. Check: kubectl -n $NAMESPACE describe pod $pod"
}

wait_for_api() {
  local pod="$1" deadline=$(( SECONDS + TIMEOUT ))
  until bao_status_json "$pod" >/dev/null; do
    (( SECONDS < deadline )) || die 3 "OpenBao API in $pod does not answer. Check: kubectl -n $NAMESPACE logs $pod"
    sleep 3
  done
}

unseal_pod() {
  local pod="$1" status sealed i
  status="$(bao_status_json "$pod")" || die 4 "cannot read status of $pod"
  sealed="$(jq -r '.sealed' <<<"$status")"
  if [[ "$sealed" == "false" ]]; then
    log "$pod is already unsealed"
    return 0
  fi

  log "unsealing $pod with $KEY_THRESHOLD key(s)"
  for (( i = 0; i < KEY_THRESHOLD; i++ )); do
    # The key is passed on stdin; `key=-` makes the CLI read it from there.
    jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE" \
      | bao_exec "$pod" bao write -format=json sys/unseal key=- >/dev/null \
      || die 4 "unseal of $pod failed at key $((i + 1)). Wrong keys file, or the pod restarted."
  done

  status="$(bao_status_json "$pod")" || die 4 "cannot read status of $pod after unseal"
  [[ "$(jq -r '.sealed' <<<"$status")" == "false" ]] \
    || die 4 "$pod is still sealed after $KEY_THRESHOLD keys (progress: $(jq -r '.progress' <<<"$status")/$(jq -r '.t' <<<"$status"))"
}

# ------------------------------------------------------------ parse options
while (( $# > 0 )); do
  case "$1" in
    -n|--namespace)     NAMESPACE="${2:?}"; shift 2 ;;
    -r|--release)       RELEASE="${2:?}"; shift 2 ;;
    -f|--fullname)      FULLNAME="${2:?}"; shift 2 ;;
    -p|--pods)          PODS="${2:?}"; shift 2 ;;
    -s|--key-shares)    KEY_SHARES="${2:?}"; shift 2 ;;
    -t|--key-threshold) KEY_THRESHOLD="${2:?}"; shift 2 ;;
    -k|--keys-file)     KEYS_FILE="${2:?}"; shift 2 ;;
    --timeout)          TIMEOUT="${2:?}"; shift 2 ;;
    --no-raft)          RAFT=0; shift ;;
    --join)             EXPLICIT_JOIN=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage >&2; die 1 "unknown option: $1" ;;
  esac
done

require_int "--pods" "$PODS"
require_int "--key-shares" "$KEY_SHARES"
require_int "--key-threshold" "$KEY_THRESHOLD"
require_int "--timeout" "$TIMEOUT"
(( KEY_THRESHOLD <= KEY_SHARES )) || die 1 "--key-threshold ($KEY_THRESHOLD) must not exceed --key-shares ($KEY_SHARES)"
(( KEY_SHARES == 1 || KEY_THRESHOLD > 1 )) || die 1 "--key-threshold must be at least 2 when --key-shares > 1"

FULLNAME="${FULLNAME:-$RELEASE}"
KEYS_FILE="${KEYS_FILE:-./${FULLNAME}-init.json}"

for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die 2 "'$cmd' is required but not installed"
done
kubectl -n "$NAMESPACE" get statefulset "$FULLNAME" >/dev/null 2>&1 \
  || die 3 "StatefulSet $FULLNAME not found in namespace $NAMESPACE (check --release / --fullname)"

# Refuse dev mode: its postStart hook already initializes the server.
if kubectl -n "$NAMESPACE" get statefulset "$FULLNAME" \
     -o jsonpath='{.spec.template.spec.containers[0].lifecycle.postStart.exec.command}' 2>/dev/null \
     | grep -q 'bootstrap-keys.json'; then
  die 1 "$FULLNAME runs in dev mode; it initializes and unseals itself."
fi

LEADER="${FULLNAME}-0"

# ---------------------------------------------------------- 1. initialize
wait_for_pod_running "$LEADER"
wait_for_api "$LEADER"

status="$(bao_status_json "$LEADER")" || die 4 "cannot read status of $LEADER"
if [[ "$(jq -r '.initialized' <<<"$status")" == "false" ]]; then
  [[ -e "$KEYS_FILE" ]] && die 4 "$KEYS_FILE already exists. Move it away; refusing to overwrite unseal keys."

  if [[ "$(jq -r '.type' <<<"$status")" != "shamir" ]]; then
    die 4 "seal type is '$(jq -r '.type' <<<"$status")' (auto-unseal). Run once instead: bao operator init -recovery-shares=$KEY_SHARES -recovery-threshold=$KEY_THRESHOLD"
  fi

  log "initializing $LEADER ($KEY_SHARES shares, threshold $KEY_THRESHOLD)"
  umask 077
  tmp="$(mktemp "${KEYS_FILE}.XXXXXX")"
  if ! bao_exec "$LEADER" bao operator init -format=json \
         -key-shares="$KEY_SHARES" -key-threshold="$KEY_THRESHOLD" >"$tmp"; then
    rm -f "$tmp"
    die 4 "bao operator init failed on $LEADER"
  fi
  jq -e '.unseal_keys_b64 | length > 0' "$tmp" >/dev/null || { rm -f "$tmp"; die 4 "init output is not valid JSON"; }
  mv "$tmp" "$KEYS_FILE"
  log "init output written to $KEYS_FILE (mode 0600)."
  log "Distribute the key shares to separate holders and store the root token safely, then delete this file."
else
  log "$LEADER is already initialized"
  [[ -r "$KEYS_FILE" ]] || die 4 "server is initialized but $KEYS_FILE is missing; cannot unseal. Pass --keys-file."
fi

jq -e --argjson t "$KEY_THRESHOLD" '.unseal_keys_b64 | length >= $t' "$KEYS_FILE" >/dev/null \
  || die 4 "$KEYS_FILE contains fewer than $KEY_THRESHOLD keys"

# ---------------------------------------------------------- 2. unseal pods
unseal_pod "$LEADER"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$LEADER" --timeout="${TIMEOUT}s" >/dev/null \
  || die 3 "$LEADER is unsealed but not Ready. Check the readiness probe."

scheme="http"
if kubectl -n "$NAMESPACE" get statefulset "$FULLNAME" \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BAO_CACERT")].value}' | grep -q .; then
  scheme="https"
fi

for (( i = 1; i < PODS; i++ )); do
  pod="${FULLNAME}-${i}"
  wait_for_pod_running "$pod"
  wait_for_api "$pod"

  if (( RAFT && EXPLICIT_JOIN )); then
    pod_status="$(bao_status_json "$pod")" || die 4 "cannot read status of $pod"
    if [[ "$(jq -r '.initialized' <<<"$pod_status")" == "false" ]]; then
      leader_addr="${scheme}://${LEADER}.${FULLNAME}-internal:8200"
      log "joining $pod to $leader_addr"
      # With TLS, verify the leader with the CA the chart mounts (BAO_CACERT).
      # -leader-ca-cert takes the PEM content, so it is read inside the pod.
      if [[ "$scheme" == "https" ]]; then
        bao_exec "$pod" sh -ec 'bao operator raft join -leader-ca-cert="$(cat "$BAO_CACERT")" "$1"' _ "$leader_addr" >/dev/null \
          || die 4 "raft join of $pod failed. Check DNS ${LEADER}.${FULLNAME}-internal and the certificate SANs."
      else
        bao_exec "$pod" bao operator raft join "$leader_addr" >/dev/null \
          || die 4 "raft join of $pod failed. Check DNS ${LEADER}.${FULLNAME}-internal."
      fi
    fi
  fi

  unseal_pod "$pod"
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout="${TIMEOUT}s" >/dev/null \
    || die 3 "$pod is unsealed but not Ready. Check: kubectl -n $NAMESPACE logs $pod"
done

# --------------------------------------------------------------- 3. summary
log "all $PODS pod(s) unsealed and Ready"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${RELEASE},component=server" \
  -L openbao-active,openbao-sealed >&2 || true

if (( RAFT )); then
  log "check Raft membership with a token:"
  log "  kubectl -n $NAMESPACE exec -it $LEADER -- bao login"
  log "  kubectl -n $NAMESPACE exec $LEADER -- bao operator raft list-peers"
fi
