# Red Hat Connectivity Link & OpenShift Service Mesh 3 (Sidecar Mode) Architecture

Multi-cluster on-premises hybrid connectivity architecture blueprint using Red Hat Connectivity Link (RHCL) 1.3 and Red Hat OpenShift Service Mesh (OSSM) 3.x. This document specifies the layout to expose, secure, and load-balance workloads (70-30 split) between Prod and DR clusters using MetalLB and CoreDNS with an enforced Sidecar proxy topology.

## Tech Stack

* **Edge Gateway / Ingress**: Red Hat Connectivity Link 1.3
* **Service Mesh**: Red Hat OpenShift Service Mesh 3.2
* **Mesh Data Plane**: Sidecar Mode (Envoy Proxy injection per Pod)
* **Bare-Metal Load Balancer**: MetalLB Operator (Layer 2 Advertisement mode)
* **Local DNS Engine**: CoreDNS with `kuadrant-dns` plugin integration
* **Corporate DNS Master**: BIND9 VM or A10 Networks Appliance (Zone Authority)
* **Certificate Lifecycle**: cert-manager Operator 1.18 (Automated `TLSPolicy` rotation)
* **Unified Observability**: Kiali Engine + OSSMC (OpenShift Service Mesh Console plugin)

## Architecture

* `openshift-ingress/edge-gateway` — Core North-South Kubernetes Gateway API deployment. Inherits physical VIPs from MetalLB and terminates external TLS.
* `kuadrant-dns/coredns-loadbalancer` — Local CoreDNS instances exposed via MetalLB (`10.10.10.A` / `10.10.10.B`) acting as the authoritative nameservers for the delegated subzone.
* `istio-system/eastwest-gateway` — Dedicated Istio Mesh Gateway handling secure cross-cluster East-West traffic control.
* `prod-apps/sidecar-injection` — Automated webhook injection. Every application Pod loads an Envoy sidecar container containerized within the network namespace.
* `prod-apps/httproute-borda` — Ingress routing rules directing validated traffic from RHCL directly to the Mesh application services.

## Configuration Standards

* **API Standard**: Native Kubernetes Gateway API (`gateway.networking.k8s.io/v1`) replacing legacy OpenShift Routes.
* **Security Baseline**: Strict mTLS (Mutual TLS) enforced at the Sidecar level inside the application pod boundaries.
* **DNS Delegation Rules**: Corporate DNS Master delegates `*.apps.firesoft.com.br` via `NS` records pointing to MetalLB IPs.
* **Policy Enforcement**: Avoid inline custom annotations. Use external declarative CRDs (`DNSPolicy`, `TLSPolicy`, `AuthPolicy`).

---

## Topology & Multi-Cluster Deployment

The setup requires replicating the application manifests across both clusters, altering only the local routing weights within the `DNSPolicy`.

### Cluster A: Production Environment (70% Traffic Weight)

This configuration establishes the primary target. MetalLB assigns local VIPs, and the `DNSPolicy` configures the local CoreDNS to return the RHCL edge gateway IP 70% of the time.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-rhcl-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: rhcl-gateway-class
  addresses:
  - type: IPAddress
    value: "10.10.10.Z" # Dedicated Application VIP from MetalLB
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "backend.apps.firesoft.com.br"
    tls:
      mode: Terminate
      certificateRefs:
      - name: backend-firesoft-tls
---
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata:
  name: backend-dns-policy
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: external-rhcl-gateway
  providerRefs:
    - name: coredns-local-provider
  loadBalancing:
    defaultGeo: true
    weight: 70 # 70% probability configuration

```

### Cluster B: Disaster Recovery Environment (30% Traffic Weight)

The DR environment hosts an identical deployment setup. The sidecar container configuration remains identical, but the weight drops to 30%.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-rhcl-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: rhcl-gateway-class
  addresses:
  - type: IPAddress
    value: "10.10.20.Z" # DR Specific Application VIP from MetalLB
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "backend.apps.firesoft.com.br"
    tls:
      mode: Terminate
      certificateRefs:
      - name: backend-firesoft-tls
---
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata:
  name: backend-dns-policy
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: external-rhcl-gateway
  providerRefs:
    - name: coredns-local-provider
  loadBalancing:
    defaultGeo: false
    weight: 30 # 30% probability configuration

```

### Mesh Integration: Sidecar Enforcement

To ensure the OSSM 3 data plane intercepts the incoming edge traffic immediately after the RHCL gateway pass-through, the destination namespace must enforce sidecar injection.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aplicacao-a
  namespace: prod-apps
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: aplicacao-a
      annotations:
        # Enforces OSSM 3 Sail Operator to inject the Envoy Sidecar
        sidecar.istio.io/inject: "true"
    spec:
      containers:
      - name: application
        image: quay.io/firesoft/backend-app:v1
        ports:
        - containerPort: 8080
```

---

## Key Patterns

* **Local VIP Isolation**: CoreDNS and Ingress Gateways never share a single IP address. MetalLB explicitly maps dedicated IPs (`10.10.10.A` for DNS, `10.10.10.Z` for App) to prevent cross-port blast radiuses.
* **Zero-Trust Loopback**: Unlike Ambient mode where encryption happens at the node transport layer, OSSM 3 Sidecar mode terminates mTLS directly inside the application container network interface.
* **Cross-Cluster Fallback**: If `Aplicação B` fails locally in Cluster A, the local Envoy sidecar intercepts the 503 error and automatically reroutes the request over the East-West Gateway (`10.10.10.X`) to the healthy sidecar instance in Cluster B.

## Support & Lifecycle

### ⚠️ Architecture Warnings & Support Status
* **MetalLB Operator**: Fully **GA** for Layer 2 configurations on Bare-Metal/Proxmox topologies.
* **RHCL Multi-cluster Weighted DNS**: Based on the upstream Kuadrant project, the real-time synchronization of `DNSPolicy` weights utilizing local CoreDNS architectures on-premises is a **Technology Preview** feature. Ensure corporate network TTL configurations are verified to prevent client-side cache stagnation.
