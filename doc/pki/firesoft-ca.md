# PKI Firesoft — bootstrap GitOps e mesh trust

Hierarquia:

- **Root** — `firesoft.com.br` (âncora de confiança do lab)
- **Intermediate External** — `external.firesoft.com.br` (certificados de servidor no Gateway RHCL)
- **Intermediate Internal** — `internal.firesoft.com.br` (mTLS entre workloads via istio-csr)

## 1. Bootstrap da Root (cluster vazio — GitOps)

O Job `bootstrap-firesoft-root-ca` em `manifests/foundation/pki/` cria o Secret `firesoft-root-ca` no namespace `cert-manager` **somente se ele ainda não existir**, com extensões X.509 de CA (`keyCertSign`, `cRLSign`).

Ordem Argo CD:

1. `foundation-pki` (wave 0) — bootstrap Root + `ClusterIssuer` `firesoft-root` + intermediárias
2. `service-mesh-platform` (wave 3+) — CronJob trust + `Certificate` em `istio-system` + `IstioCSR`

### Root manual (opcional, lab existente)

Se você já gerou a Root fora do cluster, crie o Secret **antes** do primeiro sync da PKI (o Job de bootstrap não sobrescreve):

```bash
openssl genrsa -out firesoft-root.key 4096
cat > openssl-root.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
C = BR
O = Firesoft
CN = Firesoft Root CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
openssl req -x509 -new -nodes -key firesoft-root.key -sha256 -days 3650 \
  -out firesoft-root.crt -config openssl-root.cnf -extensions v3_ca
cp firesoft-root.crt ~/firesoft-root.crt

oc create secret tls firesoft-root-ca -n cert-manager \
  --cert=firesoft-root.crt --key=firesoft-root.key
```

**Não commitar** chaves privadas no Git.

## 2. Mesh trust (istio-csr)

| Recurso | Conteúdo | Motivo |
|---------|----------|--------|
| `firesoft-istio-trust` | Intermediate `firesoft-internal-ca` | `IstioCSR.spec...istioCACertificate` exige `Certificate Sign` |
| `istio-ca-root-cert` | Cadeia intermediate + root | Sidecars validam o gRPC do istio-csr e certs de workload |

O **CronJob** `sync-firesoft-mesh-trust` reconcilia esses ConfigMaps a cada 2 minutos (evita regressão com `O=cluster.local`).

`IstioCSR` usa sync-wave **4** (após Certificate + CronJob).

```bash
oc wait --for=condition=Ready certificate/firesoft-internal-ca -n istio-system --timeout=300s
oc get cronjob sync-firesoft-mesh-trust -n istio-system
oc get istiocsr default -n istio-csr
```

## 3. Exportar Root para testes locais

```bash
oc get secret firesoft-root-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > tmp/firesoft-root.crt
```

## 4. DNS e VIP do secure-gateway

```bash
export SECURE_GW_VIP=$(oc get svc -n ingress-gateway \
  -l gateway.networking.k8s.io/gateway-name=secure-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
echo "$SECURE_GW_VIP secure-app-a.external.firesoft.com.br"
```

## 5. Verificação E2E (pod → gateway MetalLB)

Com `secure-app-a` em Running (2/2):

```bash
export SECURE_GW_VIP=$(oc get svc -n ingress-gateway \
  -l gateway.networking.k8s.io/gateway-name=secure-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
oc get secret firesoft-root-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/firesoft-root.crt
oc exec -n secure-app-a deploy/aplicacao-a -c aplicacao-a -- \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/firesoft-root.crt \
  -H "Host: secure-app-a.external.firesoft.com.br" \
  "https://${SECURE_GW_VIP}/"
```

Esperado: `200`.

## 6. Verificação geral

```bash
oc get clusterissuer,certificate -A | grep firesoft
curl -v --cacert tmp/firesoft-root.crt https://secure-app-a.external.firesoft.com.br/
oc get peerauthentication -n secure-app-a
oc get deployment -n istio-csr
oc get istiocsr -n istio-csr
```
