# single-cluster/ingress/

## What this block does

Deploys an Istio ingress gateway using Kubernetes Gateway API and exposes
bookinfo externally via an OCP Route. Includes L7 AuthorizationPolicy
enforcement at the gateway level. All findings are from actual lab observations.

---

## Lab environment

```
Cluster:      local-cluster (SNO, platform: None)
OCP Router:   HAProxy hostNetwork on 10.10.10.10:80/443
Wildcard DNS: *.apps.cluster-p5bcx.dynamic.redhatworkshops.io
Bookinfo URL: https://bookinfo.apps.cluster-p5bcx.dynamic.redhatworkshops.io/productpage
```

---

## Files in this directory

| File | Kind | What it does |
|---|---|---|
| bookinfo-namespace.yaml | Namespace | bookinfo-ingress namespace |
| bookinfo-gateway.yaml | Gateway | Istio ingress gateway |
| bookinfo-httproute.yaml | HTTPRoute | Routes /productpage to productpage Service |
| bookinfo-route.yaml | Route | OCP Route -> gateway Service |
| referencegrant.yaml | ReferenceGrant | Cross-namespace HTTPRoute -> Gateway reference |
| authpolicy.yaml | AuthorizationPolicy | GET-only enforcement at gateway |

---

## Architecture — platform:None vs cloud

### Cloud (AWS/Azure/GCP) — no OCP Route needed

```
Browser
  |
  v
AWS NLB
  |
  v
bookinfo-gateway-istio Service (type=LoadBalancer, external IP assigned by cloud)
  |
  v
bookinfo-gateway-istio Pod (Envoy)
  | AuthorizationPolicy enforced here
  |
  v
HTTPRoute routing
  |
  v
productpage Service VIP
  |
  v
kube-proxy / iptables
  |
  v
productpage Pod
  |
  v
ztunnel intercepts inbound via node iptables redirection (ambient dataplane)
```

The Istio Gateway API controller creates a `type=LoadBalancer` Service.
The cloud provisions an NLB and assigns an external IP automatically.
No OCP Routes required.

### Bare metal / platform:None (this cluster)

```
Browser
  |
  v
DNS *.apps.cluster-p5bcx.dynamic.redhatworkshops.io -> 10.10.10.10
  |
  v
OCP Router (HAProxy, edge TLS termination, hostNetwork :443)
  |
  v
OCP Route
  |
  v
bookinfo-gateway-istio Service (ClusterIP)
  |
  v
bookinfo-gateway-istio Pod (Envoy)
  | AuthorizationPolicy enforced here (GET only)
  |
  v
HTTPRoute routing (/productpage -> productpage Service)
  |
  v
productpage Service VIP
  |
  v
kube-proxy / iptables
  |
  v
productpage Pod
  |
  v
ztunnel intercepts inbound via node iptables redirection (ambient dataplane)
```

The OCP Router is the only external entry point on this cluster.
An OCP Route fronts the gateway ClusterIP Service.
The OCP Router handles TLS with its wildcard certificate.

---

## How ztunnel fits in the ingress path

The ingress gateway pod has `istio.io/dataplane-mode=none` set by the
Istio Gateway API controller. This means ztunnel does NOT intercept
traffic originating from the gateway pod.

The gateway sends traffic to the productpage Service VIP. kube-proxy/iptables
resolves the VIP to a pod IP. At the destination node, iptables redirects
the inbound connection to ztunnel before it reaches the workload:

```
gateway pod (dataplane-mode=none)
  |
  v  plain TCP to Service VIP — ztunnel not involved on source side
productpage Service VIP
  |
  v
kube-proxy / iptables -> productpage Pod
                              ^
              destination node iptables redirects to ztunnel
              ztunnel intercepts INBOUND, then passes to workload
```

The gateway already runs an Envoy proxy responsible for L7 ingress
processing. Enrolling it in ambient would insert ztunnel in front of
Envoy, adding an unnecessary L4 hop without additional policy benefit.

---

## Why the Waypoint does not enforce policy for ingress traffic

Waypoint insertion is triggered when traffic originates from a workload
intercepted by ztunnel AND the destination Service has a Waypoint attached:

```
ambient source pod
  |
  v ztunnel intercepts outbound
  | ztunnel checks: does destination Service have a Waypoint?
  v YES -> route via Waypoint
Waypoint -> destination pod
```

The ingress gateway has `istio.io/dataplane-mode=none` — it is not
intercepted by ztunnel on the source side. So the flow looks like:

```
Gateway Envoy -> productpage Service VIP -> productpage Pod
```

ztunnel at the source is never involved, so it never checks for or
inserts the Waypoint. The Waypoint is bypassed because source traffic
is not intercepted by ztunnel — not because the Service VIP is bypassed.

Consequence: `targetRefs -> Service` AuthorizationPolicy (enforced at
Waypoint) does not apply to ingress gateway traffic. Use
`targetRefs -> Gateway` to enforce policy at the gateway Envoy directly.

```yaml
# Enforced at Waypoint — works for ambient pod-to-pod traffic only
targetRefs:
- kind: Service
  name: productpage

# Enforced at Gateway Envoy — works for ingress traffic
targetRefs:
- kind: Gateway
  group: gateway.networking.k8s.io
  name: bookinfo-gateway
```

Both policies serve different purposes and should both be applied:
- `targetRefs -> Service` (bookinfo ns): enforces for mesh-internal traffic
- `targetRefs -> Gateway` (bookinfo-ingress ns): enforces for ingress traffic

---

## Apply order

```bash
# 1. Namespace
oc apply -f bookinfo-namespace.yaml

# 2. Gateway CR
oc apply -f bookinfo-gateway.yaml

# 3. Fix Service type on bare metal (platform:None only)
oc annotate gateway bookinfo-gateway -n bookinfo-ingress \
  networking.istio.io/service-type=ClusterIP

# Confirm Service type changed
oc get svc bookinfo-gateway-istio -n bookinfo-ingress -o wide
# TYPE: ClusterIP (not LoadBalancer <pending>)

# Wait for Programmed=True
oc get gateway bookinfo-gateway -n bookinfo-ingress -w

# 4. HTTPRoute + ReferenceGrant
oc apply -f bookinfo-httproute.yaml
oc apply -f referencegrant.yaml

# 5. OCP Route (bare metal only)
oc apply -f bookinfo-route.yaml

# 6. AuthorizationPolicy
oc apply -f authpolicy.yaml
```

---

## Lab findings

### Finding 1 — Gateway API controller appends "-istio" to Gateway name

The Istio Gateway API controller generates Service and ServiceAccount
names using the pattern `<gateway-name>-istio`. This is standard Istio
Gateway API controller behaviour.

```
Gateway CR name:    bookinfo-gateway
Service created:    bookinfo-gateway-istio
ServiceAccount:     bookinfo-gateway-istio
```

Always verify after applying Gateway CR:
```bash
oc get svc -n bookinfo-ingress
oc get sa -n bookinfo-ingress
```

Impact on OCP Route:
```yaml
to:
  name: bookinfo-gateway-istio   # NOT bookinfo-gateway
```

Impact on AuthorizationPolicy principals:
```yaml
principals:
- cluster.local/ns/bookinfo-ingress/sa/bookinfo-gateway-istio
```

### Finding 2 — LoadBalancer Service pending on platform:None

On bare metal / platform:None clusters, the Istio Gateway API controller
creates a `type=LoadBalancer` Service by default. Without a cloud provider
the Service stays `<pending>` forever and the Gateway never reaches
`PROGRAMMED=True`.

Fix — annotate the Gateway CR:
```bash
oc annotate gateway bookinfo-gateway -n bookinfo-ingress \
  networking.istio.io/service-type=ClusterIP

# Confirm fix applied
oc get svc bookinfo-gateway-istio -n bookinfo-ingress -o wide
# TYPE: ClusterIP   CLUSTER-IP: 172.x.x.x   EXTERNAL-IP: <none>
```

### Finding 3 — ReferenceGrant for cross-namespace HTTPRoute attachment

ReferenceGrant is a Gateway API resource that grants cross-namespace
permission for one resource to reference another in a different namespace.
It must exist in the TARGET namespace — the namespace being referenced.

In this lab the HTTPRoute is in `bookinfo` and the Gateway is in
`bookinfo-ingress`. The ReferenceGrant lives in `bookinfo-ingress`
(the target) and grants `bookinfo` permission to attach HTTPRoutes:

```
HTTPRoute (bookinfo)
  |
  | parentRefs
  v
Gateway (bookinfo-ingress)
  ^
  |
ReferenceGrant (bookinfo-ingress)
grants bookinfo namespace permission to attach HTTPRoutes here
```

ReferenceGrant is a standard Gateway API security mechanism. It is NOT
related to Waypoint authorization or ambient routing.

Alternative: set `allowedRoutes.from: All` on the Gateway listener to
skip the ReferenceGrant requirement. Use ReferenceGrant for explicit,
auditable cross-namespace permission control in production.

### Finding 4 — 403 vs 405 identifies enforcement point

```
403 Forbidden          <- Envoy blocked it (Gateway or Waypoint policy)
405 Method Not Allowed <- App rejected it (request reached productpage)
```

If a POST returns 405, the AuthorizationPolicy is not enforcing —
the request reached the application. If it returns 403, Envoy blocked
it before the application received it.

This is the fastest way to confirm whether policy is enforcing correctly.

---

## Verify healthy state

```bash
# Gateway programmed
oc get gateway bookinfo-gateway -n bookinfo-ingress
# PROGRAMMED=True

# Service type confirmed ClusterIP
oc get svc bookinfo-gateway-istio -n bookinfo-ingress -o wide
# TYPE: ClusterIP

# Gateway pod running and excluded from ambient
oc get pods -n bookinfo-ingress
# bookinfo-gateway-istio-xxx  1/1  Running

oc get pod -n bookinfo-ingress \
  -l gateway.networking.k8s.io/gateway-name=bookinfo-gateway \
  -o jsonpath='{.items[0].metadata.labels.istio\.io/dataplane-mode}'
# none  <- excluded from ambient, expected

# OCP Route active
oc get route bookinfo -n bookinfo-ingress
# edge/Redirect

# HTTPRoute accepted by controller
oc get httproute bookinfo -n bookinfo -o yaml | grep -E "reason|status" | head -10
# Accepted=True, ResolvedRefs=True, ResolvedWaypoints=True

# HTTPRoute programmed into gateway Envoy
# Accepted=True does not guarantee routes are programmed — verify this
istioctl pc routes <gateway-pod-name> -n bookinfo-ingress
# Should show route for bookinfo.apps.cluster-p5bcx... hostname
# "No routes" means hostname mismatch between HTTPRoute and OCP Route

# Policy enforced at gateway
oc get authorizationpolicy -n bookinfo-ingress
# ingress-policy  ALLOW

# Ambient enrollment — bookinfo pods enrolled, gateway pod excluded
istioctl ztunnel-config workloads ztunnel-p9b9r.ztunnel \
  --workload-namespace bookinfo
# All bookinfo pods: PROTOCOL=HBONE (enrolled in ambient)

istioctl ztunnel-config workloads ztunnel-p9b9r.ztunnel \
  --workload-namespace bookinfo-ingress
# gateway pod: PROTOCOL=TCP (excluded from ambient, by design)

# All proxies connected to istiod
istioctl proxy-status
# Shows: gateway Envoy + bookinfo Waypoint connected

# Confirm SPIFFE identity of gateway traffic in ztunnel logs
# Proves mTLS identity propagation even without Waypoint on source
oc logs -n ztunnel ztunnel-p9b9r | grep productpage | tail -5
# src.identity="spiffe://cluster.local/ns/bookinfo-ingress/sa/bookinfo-gateway-istio"
# dst.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"

# End to end test
curl -L -o /dev/null -s -w "%{http_code}\n" \
  https://bookinfo.apps.cluster-p5bcx.dynamic.redhatworkshops.io/productpage
# 200

curl -L -X POST -o /dev/null -s -w "%{http_code}\n" \
  https://bookinfo.apps.cluster-p5bcx.dynamic.redhatworkshops.io/productpage
# 403
```

---

## What to do next

```
single-cluster/egress/   Egress traffic control (ServiceEntry + L4 policy)
```
