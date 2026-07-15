#!/usr/bin/env bats

load _helpers

# Acceptance tests for end-to-end TLS.
#
# Requirements (must exist in the target cluster before running):
#   - cert-manager installed (CRDs Issuer/Certificate available)
#   - kubectl / helm configured against the cluster
#
# These tests deploy a self-signed CA Issuer, then install OpenBao with TLS
# enabled (global.tlsDisable=false, server.tls.source=certManager) in both
# standalone and HA/raft modes, and verify that:
#   1. The cert-manager Certificate becomes Ready and produces the TLS secret.
#   2. The server listener actually serves HTTPS with a cert signed by our CA.
#   3. In-cluster clients verify the server certificate against the mounted CA
#      (BAO_CACERT) without -tls-skip-verify.
#   4. Certificate rotation is picked up (renew) without breaking the listener.

setup() {
    kubectl create namespace "${TLS_NS:=openbao-tls-acc}" 2>/dev/null || true

    # Self-signed CA Issuer + CA Certificate + CA Issuer used to sign the
    # server certificate.
    cat <<EOF | kubectl apply -n "${TLS_NS}" -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-ca
spec:
  isCA: true
  commonName: openbao-ca
  secretName: openbao-ca-tls
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: Issuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openbao-ca-issuer
spec:
  ca:
    secretName: openbao-ca-tls
EOF

    kubectl wait --for=condition=Ready --timeout=120s \
        certificate/openbao-ca -n "${TLS_NS}"
}

teardown() {
    helm delete openbao -n "${TLS_NS}" 2>/dev/null || true
    kubectl delete namespace "${TLS_NS}" 2>/dev/null || true
}

@test "tls/standalone: server serves HTTPS verified by mounted CA" {
    cd `chart_dir`
    helm install openbao -n "${TLS_NS}" \
        --set 'global.tlsDisable=false' \
        --set 'server.tls.source=certManager' \
        --set 'server.tls.certManager.issuerRef.name=openbao-ca-issuer' \
        --set 'server.tls.certManager.issuerRef.kind=Issuer' \
        .

    # The cert-manager Certificate created by the chart must become Ready.
    kubectl wait --for=condition=Ready --timeout=120s \
        certificate/openbao-openbao-tls -n "${TLS_NS}"

    # TLS secret exists and has the expected keys.
    run kubectl get secret openbao-openbao-tls -n "${TLS_NS}" \
        -o jsonpath='{.data.tls\.crt}{" "}{.data.tls\.key}{" "}{.data.ca\.crt}'
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    wait_for_running "openbao-0"

    # The listener must speak HTTPS; `bao status` uses BAO_CACERT and must NOT
    # need -tls-skip-verify. A non-error TLS handshake proves the CA is trusted.
    run kubectl exec -n "${TLS_NS}" openbao-0 -- sh -c \
        'BAO_ADDR=https://127.0.0.1:8200 bao status -format=json'
    # exit code 2 == sealed but reachable over verified TLS; 0 == unsealed.
    [ "$status" -eq 2 ] || [ "$status" -eq 0 ]
}

@test "tls/ha-raft: cluster comes up with TLS on peer/replication traffic" {
    cd `chart_dir`
    helm install openbao -n "${TLS_NS}" \
        --set 'global.tlsDisable=false' \
        --set 'server.tls.source=certManager' \
        --set 'server.tls.certManager.issuerRef.name=openbao-ca-issuer' \
        --set 'server.tls.certManager.issuerRef.kind=Issuer' \
        --set 'server.ha.enabled=true' \
        --set 'server.ha.raft.enabled=true' \
        --set 'server.ha.replicas=3' \
        .

    kubectl wait --for=condition=Ready --timeout=120s \
        certificate/openbao-openbao-tls -n "${TLS_NS}"

    # All three pods should reach a running (sealed) state, which requires the
    # per-pod DNS SANs on the cert to be valid for internal :8201 traffic.
    wait_for_sealed_vault "openbao-0"
    wait_for_sealed_vault "openbao-1"
    wait_for_sealed_vault "openbao-2"

    # Verify HTTPS on a non-zero pod via the headless internal DNS name, which
    # exercises the wildcard SAN.
    run kubectl exec -n "${TLS_NS}" openbao-1 -- sh -c \
        'BAO_ADDR=https://openbao-1.openbao-internal:8200 bao status -format=json'
    [ "$status" -eq 2 ] || [ "$status" -eq 0 ]
}

@test "tls/rotation: renewing the certificate keeps the listener serving HTTPS" {
    cd `chart_dir`
    helm install openbao -n "${TLS_NS}" \
        --set 'global.tlsDisable=false' \
        --set 'server.tls.source=certManager' \
        --set 'server.tls.certManager.issuerRef.name=openbao-ca-issuer' \
        --set 'server.tls.certManager.issuerRef.kind=Issuer' \
        .

    kubectl wait --for=condition=Ready --timeout=120s \
        certificate/openbao-openbao-tls -n "${TLS_NS}"
    wait_for_running "openbao-0"

    local before
    before=$(kubectl get secret openbao-openbao-tls -n "${TLS_NS}" \
        -o jsonpath='{.data.tls\.crt}')

    # Force cert-manager to reissue.
    kubectl annotate certificate/openbao-openbao-tls -n "${TLS_NS}" \
        cert-manager.io/issue-temporary-certificate="true" --overwrite || true
    kubectl delete secret openbao-openbao-tls -n "${TLS_NS}"

    kubectl wait --for=condition=Ready --timeout=120s \
        certificate/openbao-openbao-tls -n "${TLS_NS}"

    local after
    after=$(kubectl get secret openbao-openbao-tls -n "${TLS_NS}" \
        -o jsonpath='{.data.tls\.crt}')

    [ "$before" != "$after" ]

    # Listener still serves verified HTTPS after rotation.
    run kubectl exec -n "${TLS_NS}" openbao-0 -- sh -c \
        'BAO_ADDR=https://127.0.0.1:8200 bao status -format=json'
    [ "$status" -eq 2 ] || [ "$status" -eq 0 ]
}
