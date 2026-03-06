# gateways/egress/

## What this block does

Configures egress traffic control for bookinfo pods using the correct
ambient mode egress pattern — a dedicated Waypoint proxy bound to a
ServiceEntry. All findings are from actual lab observations on OSSM 3.2
Istio 1.27.5 ambient mode.

---

## Lab environment

```
Cluster:   local-cluster (SNO, platform: None)
Istio:     v1.27.5_ossm
Mode:      ambient (ztunnel + Waypoint, no sidecars)
External:  github.com:443 (HTTPS, CDN-backed)
```

---

## Files in this directory

| File | Kind | Namespace | What it does |
|---|---|---|---|
| egress-waypoint.yaml | Namespace + Gateway | egress | egress namespace + Waypoint proxy |
| egress-referencegrant.yaml | ReferenceGrant | egress | allows istio-system to attach to Waypoint |
| egress-serviceentry.yaml | ServiceEntry | istio-system | registers github.com + binds to Waypoint |
| egress-authpolicy.yaml | AuthorizationPolicy | istio-system | only productpage SA allowed |

---

## Architecture — ambient mode egress

### Sidecar mode (NOT what we use)

```
pod -> Envoy sidecar
    -> VirtualService routes to egress gateway pod
    -> egress gateway pod -> external service
```

Requires: VirtualService + DestinationRule + egress gateway pod.
VirtualService is processed by the Envoy sidecar — not by ztunnel.

### Ambient mode (this block)

```
pod
  |
  v ztunnel intercepts outbound
  | github.com resolves to 240.240.0.2 (synthetic mesh IP via DNS capture)
  | ztunnel sees ServiceEntry has Waypoint bound -> routes via HBONE
  v
egress Waypoint pod (Envoy)
  | AuthorizationPolicy enforced here (L7 capable)
  | productpage SA -> ALLOW
  | ratings SA    -> DENY (connection dropped)
  v
github.com (real CDN IP)
```

No VirtualService. No DestinationRule. No separate egress gateway pod.
The Waypoint IS the egress enforcement point.

### How DNS capture enables Waypoint routing

```
1. ztunnel intercepts DNS queries from pods (dnsCapture=true by default)
2. github.com resolves to 240.240.0.2 (auto-allocated synthetic mesh IP)
   NOT the real CDN IP — verify with:
   oc exec -n bookinfo deploy/productpage-v1 -- \
     python3 -c "import socket; print(socket.gethostbyname('github.com'))"
   # 240.240.0.2

3. ztunnel checks: does 240.240.0.2 (github.com) have a Waypoint?
   ServiceEntry labels -> istio.io/use-waypoint=egress-waypoint
   YES -> route via HBONE to egress Waypoint pod

4. Waypoint forwards to real github.com IP
5. AuthorizationPolicy enforced at Waypoint
```

Without DNS capture this entire pattern breaks — ztunnel would never
see the synthetic IP and could not route to the Waypoint.

---

## Apply order

```bash
# 1. Namespace + Waypoint (allowedRoutes.from: All is critical)
oc apply -f egress-waypoint.yaml
oc get pods -n egress -w
# egress-waypoint-xxx  1/1  Running

# 2. ReferenceGrant (before ServiceEntry labeling)
oc apply -f egress-referencegrant.yaml

# 3. ServiceEntry with Waypoint labels
oc apply -f egress-serviceentry.yaml

# Verify Waypoint bound
oc get serviceentry github-external -n istio-system -o yaml | grep -A5 "WaypointBound"
# message: bound to egress/egress-waypoint

# Verify ztunnel service view shows Waypoint
istioctl ztunnel-config svc --namespace ztunnel | grep github
# WAYPOINT=egress-waypoint

# 4. AuthorizationPolicy (same namespace as ServiceEntry)
oc apply -f egress-authpolicy.yaml

oc get authorizationpolicy github-egress-policy -n istio-system -o yaml | grep -A5 "status:"
# message: bound to egress/egress-waypoint
# type: WaypointAccepted
```

---

## Lab findings — what we learned the hard way

### Finding 1 — allowedRoutes.from: All is required

The Waypoint listener defaults to `allowedRoutes.namespaces.from: Same`.
This only allows attachments from the same namespace (egress).
The ServiceEntry is in istio-system — a different namespace.

Without `from: All`:
```
ServiceEntry status:
  message: we are not permitted to attach to waypoint "egress/egress-waypoint"
           (missing allowedRoutes?)
  reason: AttachmentDenied
  type: istio.io/WaypointBound
```

Fix — set `from: All` in the Waypoint listener:
```yaml
listeners:
- name: mesh
  allowedRoutes:
    namespaces:
      from: All   # NOT Same (default)
```

### Finding 2 — ReferenceGrant from.group must be "" not "networking.istio.io"

ReferenceGrant `from` uses namespace-level references, not resource-level.

```yaml
# WRONG — rejected
from:
- group: networking.istio.io
  kind: ServiceEntry
  namespace: istio-system

# CORRECT — accepted
from:
- group: ""
  kind: namespace
  namespace: istio-system
```

### Finding 3 — AuthorizationPolicy must be in same namespace as ServiceEntry

Cross-namespace targetRefs not supported in Istio 1.27:
```
"cross namespace referencing is not currently supported"
```

Policy in egress namespace looking for ServiceEntry in istio-system:
```
message: ServiceEntry egress/github-external was not found
reason: TargetNotFound
```

Fix — put AuthorizationPolicy in istio-system (same as ServiceEntry).

### Finding 4 — selector-based policy with hosts field causes inbound DENY

Previous broken attempt used `selector: app=productpage` with
`operation.hosts: ["github.com"]`.

Two bugs:
```
Bug 1: hosts is an L7 attribute
  ztunnel cannot enforce HTTP attributes
  ztunnel drops the hosts rule silently
  ALLOW policy with no rules = deny everything

Bug 2: selector-based ALLOW on productpage
  triggers default-deny for ALL inbound to productpage
  ingress gateway traffic to productpage blocked
  Result: 503 on external access
```

ztunnel error seen in logs:
```
error="connection closed due to policy rejection:
       allow policies exist, but none allowed"
```

Resolution: delete the selector-based policy immediately.
Use targetRefs -> ServiceEntry instead (this file).

### Finding 5 — waypoint-for: all required for ServiceEntry traffic

bookinfo Waypoint uses `istio.io/waypoint-for: service`.
This handles east-west Service traffic only.
ServiceEntry traffic requires `waypoint-for: all`.

```yaml
# East-west only (bookinfo waypoint)
labels:
  istio.io/waypoint-for: service

# External services + east-west (egress waypoint)
labels:
  istio.io/waypoint-for: all
```

---

## Verified enforcement

```bash
# productpage allowed (SPIFFE identity in ALLOW list)
oc exec -n bookinfo deploy/productpage-v1 -- \
  python3 -c "
import urllib.request, ssl
ctx = ssl.create_default_context()
r = urllib.request.urlopen('https://github.com', context=ctx)
print(r.status)
"
# 200

# ratings denied (SPIFFE identity not in ALLOW list)
oc exec -n bookinfo deploy/ratings-v1 -- \
  curl -o /dev/null -s -w "%{http_code}" --max-time 5 https://github.com
# 000 (connection dropped at Waypoint, exit code 35)

# ztunnel log confirms traffic goes through Waypoint
oc logs -n ztunnel ztunnel-p9b9r | grep github | tail -3
# dst.workload="egress-waypoint-xxx"
# dst.namespace="egress"
# dst.addr=<waypoint-pod-ip>:15008  <- HBONE to Waypoint, not direct
```

---

## Verify healthy state

```bash
# Waypoint running
oc get pods -n egress
# egress-waypoint-xxx  1/1  Running

# Waypoint programmed
oc get gateway egress-waypoint -n egress
# PROGRAMMED=True

# ServiceEntry bound to Waypoint
oc get serviceentry github-external -n istio-system -o yaml | grep -A3 "WaypointBound"
# message: bound to egress/egress-waypoint

# ztunnel service view
istioctl ztunnel-config svc --namespace ztunnel | grep github
# WAYPOINT=egress-waypoint

# Policy bound to Waypoint
oc get authorizationpolicy github-egress-policy -n istio-system -o yaml | grep -A3 "WaypointAccepted"
# message: bound to egress/egress-waypoint

# DNS capture working (synthetic IP)
oc exec -n bookinfo deploy/productpage-v1 -- \
  python3 -c "import socket; print(socket.gethostbyname('github.com'))"
# 240.240.0.2
```

---

## What to do next

```
distributed-tracing/   Tempo + OTEL for request tracing
```
