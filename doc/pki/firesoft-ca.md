# PKI Firesoft — geração da Root CA e bootstrap no cluster

Hierarquia:

- **Root** — `firesoft.com.br` (âncora de confiança do lab)
- **Intermediate External** — `external.firesoft.com.br` (certificados de servidor no Gateway RHCL)
- **Intermediate Internal** — `internal.firesoft.com.br` (mTLS entre workloads via istio-csr)

As intermediárias são emitidas pelo cert-manager (GitOps em `manifests/foundation/pki/`) após a Root estar no cluster.

## 1. Gerar a Root CA (uma vez, fora do cluster)

```bash
mkdir -p ~/firesoft-pki && cd ~/firesoft-pki

openssl genrsa -out firesoft-root.key 4096

openssl req -x509 -new -nodes \
  -key firesoft-root.key \
  -sha256 -days 3650 \
  -out firesoft-root.crt \
  -subj "/C=BR/O=Firesoft/CN=Firesoft Root CA"

# Copiar para uso em curl/browser
cp firesoft-root.crt ~/firesoft-root.crt
```

**Não commitar** `firesoft-root.key` no Git.

## 2. Bootstrap no namespace cert-manager

O operador cert-manager já está instalado no namespace `cert-manager`. Crie o Secret antes do Argo CD sincronizar `manifests/foundation/pki/`:

```bash
oc create secret generic firesoft-root-ca -n cert-manager \
  --from-file=tls.crt=firesoft-root.crt \
  --from-file=tls.key=firesoft-root.key
```

Verifique:

```bash
oc get secret firesoft-root-ca -n cert-manager
```

## 3. Ordem GitOps (Argo CD)

1. `foundation-pki` — `ClusterIssuer` `firesoft-root` + intermediárias em `cert-manager`
2. `service-mesh-platform` (sync-wave 3):
   - Job `sync-firesoft-root-trust` → ConfigMap `firesoft-istio-trust` (root pública, lida de `firesoft-root-ca`)
   - `Certificate` `firesoft-internal-ca` em **`istio-system`** (via `ClusterIssuer firesoft-root`, renovação automática)
   - `Issuer` `firesoft-internal` em `istio-system`
   - `IstioCSR` com `istioCACertificate` apontando para `firesoft-istio-trust`

**Não** copie manualmente o Secret da intermediate para `istio-system`. O mesh usa a CA emitida em `istio-system`; a intermediate em `cert-manager` permanece para `ClusterIssuer firesoft-internal` (borda/outros usos).

```bash
oc wait --for=condition=Ready certificate/firesoft-external-ca -n cert-manager --timeout=120s
oc wait --for=condition=Ready certificate/firesoft-internal-ca -n cert-manager --timeout=120s
oc wait --for=condition=Ready certificate/firesoft-internal-ca -n istio-system --timeout=120s
oc get clusterissuer | grep firesoft
oc get job sync-firesoft-root-trust -n istio-system
oc get configmap firesoft-istio-trust -n istio-system
```

**Importante:** o `IstioCSR` deve incluir `spec.istioCSRConfig.certManager.istioCACertificate` (sem isso, os sidecars recebem trust anchor `cluster.local` e falham TLS para o istio-csr).

## 4. Confiança no cliente (lab)

Importe `firesoft-root.crt` no SO/browser ou use:

```bash
curl --cacert ~/firesoft-root.crt https://secure-app-a.external.firesoft.com.br/
```

## 5. DNS e VIP do secure-gateway

```bash
export SECURE_GW_VIP=$(oc get svc -n ingress-gateway \
  -l gateway.networking.k8s.io/gateway-name=secure-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
echo "$SECURE_GW_VIP secure-app-a.external.firesoft.com.br" | sudo tee -a /etc/hosts
```

## 6. Verificação

```bash
# PKI
oc get clusterissuer,certificate -A | grep firesoft

# Borda HTTPS
curl -v --cacert ~/firesoft-root.crt https://secure-app-a.external.firesoft.com.br/

# Mesh mTLS (secure namespaces)
oc get peerauthentication -n secure-app-a
oc get peerauthentication -n secure-app-b

# istio-csr
oc get deployment -n istio-csr
oc get istiocsr -n istio-csr
```

A resposta HTTP da app A deve incluir dados obtidos da app B (`/fetch` interno via mesh).
