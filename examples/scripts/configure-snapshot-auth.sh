#!/usr/bin/env bash
# Copyright (c) Netcracker / Qubership contributors
# SPDX-License-Identifier: MPL-2.0
#
# configure-snapshot-auth.sh - prepare OpenBao for the chart's snapshot agent.
#
# Creates (idempotently):
#   * the Kubernetes auth method at --auth-path, if it is not enabled yet;
#   * its config (kubernetes_host), unless --skip-auth-config is given;
#   * policy `--policy` with read access to sys/storage/raft/snapshot;
#   * role `--role` bound to the snapshot ServiceAccount and namespace.
#
# The values must match the chart:
#   --auth-path        = snapshotAgent.config.baoAuthPath   (default kubernetes)
#   --role             = snapshotAgent.config.baoRole       (default snapshot)
#   --service-account  = <fullname>-snapshot, or snapshotAgent.serviceAccount.name
#   --namespace        = the namespace of the release
#
# Where it runs:
#   * default: inside pod <fullname>-0 through `kubectl exec` (in-cluster server);
#   * --local: against $BAO_ADDR with the local `bao` CLI (external server).
#
# Authentication: the script needs a token with permission to manage auth
# methods and policies. It reads it from $BAO_TOKEN; it never prints it.
#
# Exit codes: 0 success, 1 usage error, 2 missing dependency, 3 OpenBao error.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"

NAMESPACE="openbao"
FULLNAME="openbao"
AUTH_PATH="kubernetes"
ROLE="snapshot"
POLICY="snapshot"
SERVICE_ACCOUNT=""
TOKEN_TTL="15m"
KUBERNETES_HOST="https://kubernetes.default.svc"
LOCAL=0
SKIP_AUTH_CONFIG=0

log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$SCRIPT_NAME" "$*" >&2; }
die() { local code="$1"; shift; log "ERROR: $*"; exit "$code"; }
trap 'log "ERROR: command failed (exit $?) at line $LINENO: ${BASH_COMMAND}"' ERR

usage() {
  cat <<EOF
Usage: BAO_TOKEN=<token> $SCRIPT_NAME [options]

Options:
  -n, --namespace NAME        Release namespace (role binding)  (default: $NAMESPACE)
  -f, --fullname NAME         Resource prefix <fullname>        (default: $FULLNAME)
  -a, --auth-path PATH        Kubernetes auth mount path        (default: $AUTH_PATH)
  -r, --role NAME             Role name                         (default: $ROLE)
  -P, --policy NAME           Policy name                       (default: $POLICY)
  -s, --service-account NAME  ServiceAccount of the agent       (default: <fullname>-snapshot)
      --ttl DURATION          Token TTL for the agent           (default: $TOKEN_TTL)
      --kubernetes-host URL   kubernetes_host for the auth config (default: $KUBERNETES_HOST)
      --skip-auth-config      Do not write auth/<path>/config (already configured)
      --local                 Use the local bao CLI and \$BAO_ADDR instead of kubectl exec
  -h, --help                  Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -n|--namespace)       NAMESPACE="${2:?}"; shift 2 ;;
    -f|--fullname)        FULLNAME="${2:?}"; shift 2 ;;
    -a|--auth-path)       AUTH_PATH="${2:?}"; shift 2 ;;
    -r|--role)            ROLE="${2:?}"; shift 2 ;;
    -P|--policy)          POLICY="${2:?}"; shift 2 ;;
    -s|--service-account) SERVICE_ACCOUNT="${2:?}"; shift 2 ;;
    --ttl)                TOKEN_TTL="${2:?}"; shift 2 ;;
    --kubernetes-host)    KUBERNETES_HOST="${2:?}"; shift 2 ;;
    --skip-auth-config)   SKIP_AUTH_CONFIG=1; shift ;;
    --local)              LOCAL=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage >&2; die 1 "unknown option: $1" ;;
  esac
done

SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${FULLNAME}-snapshot}"
AUTH_PATH="${AUTH_PATH%/}"
[[ -n "${BAO_TOKEN:-}" ]] || die 1 "BAO_TOKEN is not set"

# bao CMD... : run the CLI either locally or in the leader pod. The token is
# passed through the environment of the exec'd shell, never as an argument.
if (( LOCAL )); then
  command -v bao >/dev/null 2>&1 || die 2 "'bao' CLI is required with --local"
  [[ -n "${BAO_ADDR:-}" ]] || die 1 "BAO_ADDR is required with --local"
  bao() { command bao "$@"; }
else
  command -v kubectl >/dev/null 2>&1 || die 2 "'kubectl' is required"
  POD="${FULLNAME}-0"
  kubectl -n "$NAMESPACE" get pod "$POD" >/dev/null 2>&1 || die 3 "pod $POD not found in $NAMESPACE"
  bao() {
    # BAO_TOKEN is read from stdin inside the pod so it is not visible in
    # `ps` on the node or in the kubectl command line.
    printf '%s\n' "$BAO_TOKEN" | kubectl -n "$NAMESPACE" exec -i "$POD" -c openbao -- \
      sh -ec 'IFS= read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' _ "$@"
  }
fi

command -v jq >/dev/null 2>&1 || die 2 "'jq' is required"

# Sanity check: token valid, server unsealed, storage is Raft.
bao token lookup -format=json >/dev/null 2>&1 || die 3 "token is invalid or the server is sealed/unreachable"
if ! bao read -format=json sys/storage/raft/configuration >/dev/null 2>&1; then
  log "WARNING: sys/storage/raft/configuration is not readable. The snapshot agent only works with integrated Raft storage."
fi

# 1. Auth method -----------------------------------------------------------
if bao auth list -format=json | jq -e --arg p "${AUTH_PATH}/" 'has($p)' >/dev/null; then
  log "auth method at ${AUTH_PATH}/ already enabled"
else
  log "enabling kubernetes auth at ${AUTH_PATH}/"
  bao auth enable -path="$AUTH_PATH" kubernetes >/dev/null || die 3 "cannot enable auth method"
fi

if (( SKIP_AUTH_CONFIG )); then
  log "skipping auth/${AUTH_PATH}/config"
else
  # In-cluster: OpenBao uses its own ServiceAccount token and CA from
  # /var/run/secrets/kubernetes.io/serviceaccount (needs authDelegator).
  log "writing auth/${AUTH_PATH}/config (kubernetes_host=$KUBERNETES_HOST)"
  bao write "auth/${AUTH_PATH}/config" kubernetes_host="$KUBERNETES_HOST" >/dev/null \
    || die 3 "cannot write auth/${AUTH_PATH}/config. For an external server pass --skip-auth-config and configure token_reviewer_jwt and kubernetes_ca_cert yourself."
fi

# 2. Policy ----------------------------------------------------------------
log "writing policy $POLICY"
printf '%s\n' \
  '# Read-only access to Raft snapshots for the snapshot agent.' \
  'path "sys/storage/raft/snapshot" {' \
  '  capabilities = ["read"]' \
  '}' \
  | bao policy write "$POLICY" - >/dev/null || die 3 "cannot write policy $POLICY"

# 3. Role ------------------------------------------------------------------
log "writing role $ROLE (sa=$SERVICE_ACCOUNT, ns=$NAMESPACE, ttl=$TOKEN_TTL)"
bao write "auth/${AUTH_PATH}/role/${ROLE}" \
  bound_service_account_names="$SERVICE_ACCOUNT" \
  bound_service_account_namespaces="$NAMESPACE" \
  token_policies="$POLICY" \
  token_ttl="$TOKEN_TTL" \
  token_max_ttl="$TOKEN_TTL" >/dev/null || die 3 "cannot write role $ROLE"

bao read -format=json "auth/${AUTH_PATH}/role/${ROLE}" \
  | jq '{bound_service_account_names: .data.bound_service_account_names,
         bound_service_account_namespaces: .data.bound_service_account_namespaces,
         token_policies: .data.token_policies,
         token_ttl: .data.token_ttl}' >&2

log "done. Values for the chart:"
log "  snapshotAgent.config.baoAuthPath=$AUTH_PATH"
log "  snapshotAgent.config.baoRole=$ROLE"
log "Test: kubectl -n $NAMESPACE create job snapshot-test --from=cronjob/${FULLNAME}-snapshot"
