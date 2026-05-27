#!/usr/bin/env bash
# Diagnóstico PKI / istio-csr — escreve NDJSON em .cursor/debug-a7cf22.log
set -euo pipefail
LOG="/home/agusmao/dev/redhat/pratica/lab-rhcl-ossm/.cursor/debug-a7cf22.log"
SESSION="a7cf22"
RUN_ID="${1:-pre-fix}"

log() {
  local hid="$1" loc="$2" msg="$3" data="$4"
  printf '%s\n' "{\"sessionId\":\"${SESSION}\",\"runId\":\"${RUN_ID}\",\"hypothesisId\":\"${hid}\",\"location\":\"${loc}\",\"message\":\"${msg}\",\"data\":${data},\"timestamp\":$(date +%s000)}" >> "$LOG"
}

cm_subject() {
  oc get configmap istio-ca-root-cert -n "$1" -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//' || echo "missing"
}

log "H1" "ingress-gateway/istio-ca-root-cert" "root-cert subject in gateway namespace" \
  "{\"subject\":\"$(cm_subject ingress-gateway)\"}"
log "H1" "istio-system/istio-ca-root-cert" "root-cert subject in istio-system" \
  "{\"subject\":\"$(cm_subject istio-system)\"}"

ISTIO_ROOT=$(oc get secret istio-root-ca -n istio-system -o name 2>/dev/null || echo "not-found")
log "H2" "istio-system/istio-root-ca" "istio-root-ca secret presence" "{\"resource\":\"${ISTIO_ROOT}\"}"

EP=$(oc get endpoints cert-manager-istio-csr -n istio-csr -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}' 2>/dev/null || echo "none")
ISTIOCSR_READY=$(oc get istiocsr default -n istio-csr -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
log "H4" "istio-csr/endpoints" "istio-csr availability" "{\"endpoints\":\"${EP}\",\"istiocsrReady\":\"${ISTIOCSR_READY}\"}"

PROXY_ERR=$(oc logs -n ingress-gateway -l gateway.networking.k8s.io/gateway-name=secure-gateway -c istio-proxy --tail=5 2>&1 | tail -1 | tr '"' "'")
log "H4" "secure-gateway/istio-proxy" "latest proxy error" "{\"line\":\"${PROXY_ERR}\"}"

CM_UPDATES=$(oc logs -n istio-csr deploy/cert-manager-istio-csr --tail=20 2>&1 | grep -c "updating ConfigMap" || true)
log "H3" "istio-csr/logs" "configmap update churn (last 20 lines)" "{\"updateLines\":${CM_UPDATES}}"

ISSUER_ISTIO=$(oc get issuer firesoft-internal -n istio-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "missing")
CI=$(oc get clusterissuer firesoft-internal -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "missing")
log "H5" "issuers" "issuer readiness" "{\"issuerIstioSystem\":\"${ISSUER_ISTIO}\",\"clusterIssuer\":\"${CI}\"}"

TRUST_KU=$(oc get configmap firesoft-istio-trust -n istio-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null \
  | openssl x509 -noout -ext keyUsage 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' || echo "missing")
TRUST_SUBJ=$(oc get configmap firesoft-istio-trust -n istio-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//' || echo "missing")
log "H6" "istio-system/firesoft-istio-trust" "istioCACertificate PEM (must have Certificate Sign)" \
  "{\"subject\":\"${TRUST_SUBJ}\",\"keyUsage\":\"${TRUST_KU}\"}"

DEGRADED=$(oc get istiocsr default -n istio-csr -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null \
  | head -c 200 | tr '"' "'")
log "H7" "istio-csr/istiocsr" "IstioCSR degraded message" "{\"message\":\"${DEGRADED}\"}"

echo "Wrote diagnostics to ${LOG}"
