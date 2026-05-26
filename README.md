# rhcl-rhossm

Manifests GitOps para instalar **Red Hat OpenShift Service Mesh (OSSM) 3.2** em modo sidecar e **Red Hat Connectivity Link (RHCL) 1.3** em clusters OpenShift, usando **OpenShift GitOps** (Argo CD).

Repositório: [github.com/thegusmao/rhcl-rhossm](https://github.com/thegusmao/rhcl-rhossm)

## Visão geral

| Componente | Versão | Função |
|------------|--------|--------|
| OpenShift GitOps | OperatorHub | Argo CD / sync declarativo |
| OSSM (Sail Operator) | 3.2 (`stable-3.2`) | Control plane Istio, sidecar injection |
| RHCL (Kuadrant) | 1.3 | Gateway API, políticas DNS/TLS/rate limit |
| Kiali | 2.17.x | Console standalone e topologia do mesh |
| OSSM Console (OSSMC) | via Kiali Operator | Plugin Service Mesh no console OpenShift |
| OpenTelemetry | Red Hat build | Coleta de telemetria (base para Tempo) |
| User Workload Monitoring | OCP Monitoring | Prometheus para `PodMonitor`/`ServiceMonitor` em namespaces de app |
| cert-manager | Red Hat OpenShift | TLS para gateways (pré-requisito RHCL) |

O blueprint de arquitetura multi-cluster (prod/DR, MetalLB, CoreDNS, mTLS) está em [`doc/architecture.md`](doc/architecture.md).

## Estrutura do repositório

```
.
├── bootstrap/              # Aplicação manual uma vez por cluster
├── manifests/
│   ├── applications/       # App-of-apps: AppProjects + Applications
│   ├── foundation/         # Subscriptions OLM (operadores globais)
│   ├── infra/
│   │   ├── namespaces/     # namespaces, user-workload-monitoring, ClusterRole/Binding GitOps
│   │   ├── service-mesh/     # Istio, IstioCNI, Kiali, OSSMConsole, OpenTelemetry
│   │   └── connectivity-link/  # Kuadrant (RHCL)
│   ├── service-mesh/       # Config por ambiente (platform/dev) — futuro
│   └── connectivity-link/  # Config RHCL por ambiente — futuro
└── doc/
```

### Fluxo GitOps (app-of-apps)

```mermaid
flowchart LR
  Bootstrap[lab-rhcl-ossm] --> Apps[manifests/applications]
  Apps --> Foundation[foundation wave 0]
  Apps --> Infra[infra wave 1]
  Apps --> MeshApp[service-mesh-infra wave 2]
  Apps --> RhclApp[connectivity-link-infra wave 3]
  Foundation --> Operators[CSV em openshift-operators]
  Infra --> NS[Namespaces]
  MeshApp --> Mesh[Istio Kiali OSSMConsole OTel]
  RhclApp --> RHCL[Kuadrant CR]
```

1. **Bootstrap** — `Application` `lab-rhcl-ossm` sincroniza `manifests/applications`.
2. **foundation** (sync-wave 0) — operadores OLM em `manifests/foundation`.
3. **infra** (sync-wave 1) — `manifests/infra/namespaces` (RBAC cluster, namespaces com `managed-by`, `cluster-monitoring-config` com `enableUserWorkload: true`).
4. **service-mesh-infra** (sync-wave 2) — `manifests/infra/service-mesh`.
5. **connectivity-link-infra** (sync-wave 3) — `manifests/infra/connectivity-link`.

| Application | Path | Projeto |
|-------------|------|---------|
| `foundation` | `manifests/foundation` | `infra` |
| `infra` | `manifests/infra/namespaces` | `infra` |
| `service-mesh-infra` | `manifests/infra/service-mesh` | `infra` |
| `connectivity-link-infra` | `manifests/infra/connectivity-link` | `infra` |

## Pré-requisitos

- OpenShift Container Platform **4.18+** (OSSM 3.2) ou versão suportada pelo [RHCL 1.3](https://access.redhat.com/articles/7092611)
- `cluster-admin` para bootstrap e Subscriptions
- Catálogo `redhat-operators` disponível
- Subscriptions Red Hat ativas (OSSM, RHCL, OCP)
- **cert-manager Operator for Red Hat OpenShift** — se já existir no cluster, revise [`manifests/foundation/04-subscription-cert-manager.yaml`](manifests/foundation/04-subscription-cert-manager.yaml) antes do sync para evitar conflito OLM

## Bootstrap (primeira instalação)

Ordem sugerida:

```bash
# 1. Operador GitOps
oc apply -f bootstrap/00-subscription.yaml
oc wait argocd/openshift-gitops -n openshift-gitops --for=condition=Available --timeout=300s

# 2. Configuração Argo CD
oc apply -f bootstrap/01-argocd-cr.yaml

# 3. Credencial do repositório (copie o exemplo e preencha token/usuário)
cp bootstrap/03-secret-lab-rhcl-ossm.yaml.example bootstrap/03-secret-lab-rhcl-ossm.yaml
# edite bootstrap/03-secret-lab-rhcl-ossm.yaml — não commitar o secret real
oc apply -f bootstrap/03-secret-lab-rhcl-ossm.yaml

# 4. App-of-apps raiz
oc apply -f bootstrap/04-application-lab-rhcl-ossm.yaml
```

O Argo CD passa a gerenciar `foundation`, `infra`, `service-mesh-infra` e `connectivity-link-infra` automaticamente.

## RBAC do GitOps (Istio / IstioCNI cluster-scoped)

`Istio` e `IstioCNI` (`sailoperator.io`) são **Cluster-scoped**. O label `managed-by` nos namespaces não basta; a Application `infra` aplica:

- `ClusterRole` `openshift-gitops-infra-platform`
- `ClusterRoleBinding` para `openshift-gitops-argocd-application-controller` em `openshift-gitops`

Inclui também permissões antecipadas para Kiali, Kuadrant, OpenTelemetry, `ClusterRoleBinding` do Kiali (`cluster-monitoring-view`), Gateway API e APIs Istio usadas nas fases `platform`/`dev`.

## Observabilidade (User Workload Monitoring)

A Application `infra` aplica [`manifests/infra/namespaces/user-workload-monitoring.yaml`](manifests/infra/namespaces/user-workload-monitoring.yaml), que define o ConfigMap `cluster-monitoring-config` em `openshift-monitoring` com `enableUserWorkload: true`. Isso implanta o stack Prometheus/Thanos em `openshift-user-workload-monitoring` para coletar `PodMonitor` e `ServiceMonitor` em projetos de usuário.

Os namespaces `app-a` e `app-b` recebem a label `openshift.io/user-monitoring: "true"`. As Applications `aplicacao-a` e `aplicacao-b` (projeto `dev`) publicam `PodMonitor` que expõem métricas do sidecar Envoy (`/stats/prometheus`).

O Kiali consulta métricas agregadas via Thanos Querier (`thanos-querier.openshift-monitoring.svc:9091`), com RBAC em [`manifests/infra/service-mesh/kiali-rbac.yaml`](manifests/infra/service-mesh/kiali-rbac.yaml).

Se o sync de `infra` falhar ao criar o `ClusterRoleBinding`, aplique uma vez com cluster-admin:

```bash
oc apply -f manifests/infra/namespaces/clusterrole-openshift-gitops-infra.yaml
oc apply -f manifests/infra/namespaces/clusterrolebinding-openshift-gitops-infra.yaml
```

## Validação

```bash
# Operadores
oc get csv -n openshift-operators | egrep 'servicemesh|rhcl|kiali|opentelemetry|cert-manager'

# Service Mesh
oc get istio,istiocni -A
oc get pods -n istio-system -l app=istiod

# Connectivity Link
oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready=true --timeout=300s

# Kiali
oc get kiali -n istio-system
oc get route kiali -n istio-system

# OSSM Console plugin (após Kiali Ready)
oc get ossmconsole -n istio-system

# User Workload Monitoring (métricas de sidecar / PodMonitor)
oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}'
oc get pods -n openshift-user-workload-monitoring
oc get podmonitor -n app-a
```

No console OpenShift: categoria **Service Mesh** no menu principal (refresh do browser se solicitado após o install do plugin).

## AppProjects

| Projeto | Uso |
|---------|-----|
| `infra` | Operadores e instalação base (`foundation`, `infra`, `service-mesh-infra`, `connectivity-link-infra`) |
| `platform` | Recursos compartilhados em namespaces de plataforma (futuro) |
| `dev` | Workloads e políticas por aplicação (futuro) |

Pastas reservadas: `manifests/service-mesh/{platform,dev}`, `manifests/connectivity-link/{platform,dev}`.

## Documentação Red Hat

- [OSSM 3.2 — Installing](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-installing-service-mesh)
- [RHCL 1.3 — Installing on OCP](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/installing_on_openshift_container_platform/rhcl-install-on-ocp)
- [OpenShift GitOps](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops)
- [Enabling monitoring for user-defined projects](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/monitoring/enabling-monitoring-for-user-defined-projects)

## Licença

Este projeto está licenciado sob a [Apache License 2.0](LICENSE).
