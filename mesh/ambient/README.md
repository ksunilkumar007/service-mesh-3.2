# mesh/ambient/

## What this block does

Deploys the OSSM 3.2 ambient mode control plane and data plane on a Single Node
OpenShift cluster running RHACM. Covers operator installation, control plane
deployment, bookinfo sample app enrollment, Waypoint proxy, mTLS policy,
and L7 traffic splitting. All findings are from actual lab observations.

---

## Lab environment

```
Cluster:   local-cluster (SNO — Single Node OpenShift)
OCP:       4.20
Node:      control-plane-cluster-p5bcx-1 (1 x master+worker)
RHACM:     2.15 (pre-installed)
Pod CIDR:  10.232.0.0/14
Svc CIDR:  172.231.0.0/16
IPv6:      enabled (dual-stack — ztunnel listens on [::] not 0.0.0.0)
Operator:  servicemeshoperator3.v3.2.2
Istio:     v1.27.5_ossm (Red Hat build)
```

---

## Files in this directory

| File | Kind | API | What it deploys |
|---|---|---|---|
| sail-operator.yaml | Subscription | operators.coreos.com/v1alpha1 | OSSM 3.2 operator |
| istio.yaml | Istio | sailoperator.io/v1 | istiod control plane |
| istio-cni.yaml | IstioCNI | sailoperator.io/v1 | CNI DaemonSet |
| ztunnel.yaml | ZTunnel | sailoperator.io/v1 | ztunnel DaemonSet |
| waypoint.yaml | Gateway | gateway.networking.k8s.io/v1 | L7 Waypoint for bookinfo |
| reviews-services.yaml | Service x3 | v1 | Per-version Services for traffic splitting |
| traffic-route.yaml | HTTPRoute | gateway.networking.k8s.io/v1 | 90/10 traffic split |
| peerauthentication.yaml | PeerAuthentication | security.istio.io/v1 | Mesh-wide STRICT mTLS |
| peerauth-bookinfo.yaml | PeerAuthentication | security.istio.io/v1 | Namespace STRICT mTLS |
| authorizationpolicy.yaml | AuthorizationPolicy | security.istio.io/v1 | L7 access control via Waypoint (apply after ingress) |

---

## Apply order

```
1.  sail-operator.yaml          Operator install
2.  istio.yaml                  Control plane
3.  istio-cni.yaml              CNI DaemonSet
4.  ztunnel.yaml                Data plane
    -- bookinfo deploy --
5.  waypoint.yaml               L7 Waypoint
6.  reviews-services.yaml       Per-version Services (required before HTTPRoute)
7.  traffic-route.yaml          90/10 traffic split
8.  peerauthentication.yaml     Mesh-wide STRICT mTLS
9.  peerauth-bookinfo.yaml      Namespace STRICT mTLS
    -- deploy ingress first --
10. authorizationpolicy.yaml    L7 access control (after ingress gateway SA exists)
```

---

## Operator installation — lessons learned on RHACM clusters

### Lesson 1 — RHACM shadows OLM CRDs

RHACM registers its own Subscription CRD (apps.open-cluster-management.io)
which takes priority over OLM's Subscription (operators.coreos.com).

```bash
# WRONG — hits RHACM CRD, returns nothing
oc get subscription sailoperator -n openshift-operators

# CORRECT — explicit API group required on RHACM clusters
oc get subscription.operators.coreos.com sailoperator -n openshift-operators
```

Same issue affects: Channel, PlacementRule — always use full resource.group syntax.

### Lesson 2 — Package name is not sailoperator

```bash
oc get packagemanifest -n openshift-marketplace | grep -i mesh
# servicemeshoperator3   Red Hat Operators  <- correct for OSSM 3.x
# sailoperator           Community Operators <- upstream only
```

### Lesson 3 — Correct Subscription

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: stable-3.2
  installPlanApproval: Automatic
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Available channels: candidates, stable, stable-3.0, stable-3.1, stable-3.2
Installed: servicemeshoperator3.v3.2.2

### Lesson 4 — ZTunnel API promoted to v1

Upstream docs and older manifests use sailoperator.io/v1alpha1 for ZTunnel.
On servicemeshoperator3.v3.2.2 (OCP 4.20) it is sailoperator.io/v1.

```bash
# Always verify before applying on a new cluster
oc api-resources | grep ztunnel
# ztunnels  sailoperator.io/v1  false  ZTunnel
```

Applying v1alpha1 on a v1 cluster fails silently or with:
"no matches for kind ZTunnel in version sailoperator.io/v1alpha1"

---

## Pre-flight — namespace labels

These namespaces must exist and be labelled BEFORE applying any CR.
istiod uses discoverySelectors and only watches labelled namespaces.
Without these labels, istiod cannot see its own components on first boot.

```bash
oc new-project istio-system
oc new-project istio-cni
oc new-project ztunnel

oc label namespace istio-system istio-discovery=enabled
oc label namespace istio-cni    istio-discovery=enabled
oc label namespace ztunnel      istio-discovery=enabled
```

---

## Control plane deployment — dependency chain

Apply in this exact order. Each CR status reports what is missing next.

```bash
# Step 1
oc apply -f istio.yaml
oc get istio default -w
# Wait for: STATUS=IstioCNINotFound (istiod running, waiting for CNI)

# Step 2
oc apply -f istio-cni.yaml
oc get istiocni default -w
# Wait for: STATUS=Healthy (~14 seconds)
# Istio CR moves to: ZTunnelNotFound

# Step 3
oc apply -f ztunnel.yaml
oc get ztunnel default -w
# Wait for: STATUS=Healthy (~30 seconds)
# Istio CR moves to: Healthy
```

Final state:
```
oc get istio default     # STATUS: Healthy   VERSION: v1.27.5
oc get istiocni default  # STATUS: Healthy   VERSION: v1.27.5
oc get ztunnel default   # STATUS: Healthy   VERSION: v1.27.5
```

---

## What the logs confirm after control plane is healthy

### istiod logs
```
ADS: new delta connection for node:ztunnel-p9b9r.ztunnel-1
  -> ztunnel authenticated and connected to istiod

WDS: PUSH request for node:ztunnel-p9b9r.ztunnel resources:3
  -> istiod pushed workload registry to ztunnel

ConnectedEndpoints:1
  -> ztunnel is the only connected endpoint (no workloads yet)
```

### ztunnel logs
```
Spiffe { trust_domain: "cluster.local",
         namespace: "ztunnel",
         service_account: "ztunnel" }
  -> SPIFFE identity issued by istiod — trust chain confirmed

listener established address=[::]:15008  -> HBONE inbound (IPv6 dual-stack)
listener established address=[::]:15020  -> metrics/stats
listener established address=[::]:15021  -> readiness probe
Stream established                       -> xDS connected to istiod
marking server ready                     -> ztunnel fully initialised
```

---

## Bookinfo deployment

```bash
oc new-project bookinfo
oc label namespace bookinfo istio-discovery=enabled
oc label namespace bookinfo istio.io/dataplane-mode=ambient

oc apply -n bookinfo -f \
  https://raw.githubusercontent.com/istio/istio/release-1.27/samples/bookinfo/platform/kube/bookinfo.yaml

# All pods must be 1/1 — NOT 2/2
# 2/2 means sidecar injection fired — check profile is ambient not default
oc get pods -n bookinfo
```

Verify HBONE mTLS is active:
```bash
istioctl ztunnel-config workloads ztunnel-p9b9r.ztunnel --workload-namespace bookinfo
# All bookinfo pods: PROTOCOL=HBONE

# ztunnel access log shows SPIFFE identity on every connection
oc logs -n ztunnel ztunnel-p9b9r | grep details | tail -3
# src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
# dst.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-details"
# dst.addr=10.232.0.34:15008  <- HBONE port, not 9080
```

---

## Waypoint proxy — L7 enablement

### Deploy and activate

```bash
# Step 1 — create the Waypoint
oc apply -f waypoint.yaml

# Step 2 — label namespace (LABEL not annotation — see lesson below)
oc label namespace bookinfo istio.io/use-waypoint=waypoint

# Waypoint pod appears alongside bookinfo pods
oc get pods -n bookinfo
# waypoint-xxx  1/1  Running
```

### Critical finding — label NOT annotation

OSSM 3.2 docs say oc annotate namespace is sufficient. This is incorrect.

```bash
# DOES NOT WORK — silently ignored by ztunnel
oc annotate namespace bookinfo istio.io/use-waypoint=waypoint

# WORKS — label is required
oc label namespace bookinfo istio.io/use-waypoint=waypoint
```

Verify it is a label not an annotation:
```bash
oc get namespace bookinfo --show-labels | tr ',' '\n' | grep waypoint
# Must show: istio.io/use-waypoint=waypoint
```

### Service-level labels (optional)

Namespace label is sufficient for all services. Use service-level labels
only when different services need different Waypoints.

```bash
# Per-service override (overrides namespace label for that service)
oc label service -n bookinfo reviews istio.io/use-waypoint=other-waypoint

# Remove service label to fall back to namespace label
oc label service -n bookinfo reviews istio.io/use-waypoint-
```

### Correct verification command

```bash
# CORRECT — service view shows Waypoint attachment
istioctl ztunnel-config svc --namespace ztunnel
# bookinfo services: WAYPOINT=waypoint  <- correct

# MISLEADING — workload view always shows None for service-scoped Waypoints
istioctl ztunnel-config workloads ztunnel-p9b9r.ztunnel --workload-namespace bookinfo
# WAYPOINT=None for all pods — this is CORRECT and EXPECTED for service-scoped Waypoint
# None does NOT mean Waypoint is not working
```

### Verified traffic path (from ztunnel access logs)

```
productpage pod (plain HTTP)
     |
     v ztunnel intercepts outbound
     | dst.addr=<waypoint-pod>:15008     <- Waypoint HBONE port
     | dst.hbone_addr=<reviews-VIP>:9080 <- Service VIP inside tunnel
     | dst.identity=spiffe://.../sa/waypoint
     v
Waypoint proxy (Envoy) — L7 processing
     | enforces: HTTPRoute weights, AuthorizationPolicy HTTP attrs, JWT
     v ztunnel intercepts Waypoint outbound
     | dst.addr=<reviews-pod>:15008      <- pod HBONE port
     | dst.identity=spiffe://.../sa/bookinfo-reviews
     v
reviews pod (plain HTTP delivered)
```

All bookinfo service-to-service calls go through Waypoint:
productpage->reviews, productpage->details, reviews->ratings.

### Why oc logs deploy/waypoint shows no HTTP access logs

Envoy access logging defaults to warning level (--proxyLogLevel=warning).
HTTP request logs are at info level. Use ztunnel access logs instead —
they show both hops and full SPIFFE identity for every connection.

---

## Traffic splitting — reviews 90/10

### Why per-version Services are required

bookinfo ships with a single reviews Service selecting all three versions.
Gateway API HTTPRoute backendRefs point to Services, not pod labels.
Per-version Services are required — they replace DestinationRule subsets
from sidecar mode. In ambient mode the Waypoint reads HTTPRoute natively
and does not read DestinationRule subsets at all.

```bash
# Step 1 — create per-version Services
oc apply -f reviews-services.yaml

# Verify endpoints (1 pod per version)
oc get endpoints reviews-v1 reviews-v2 reviews-v3 -n bookinfo

# Step 2 — apply HTTPRoute
oc apply -f traffic-route.yaml

# Verify — all three conditions must be True
oc get httproute reviews -n bookinfo -o yaml | grep -E "message|reason|status"
# Accepted: True
# ResolvedRefs: True       <- BackendNotFound here means Services missing
# ResolvedWaypoints: True
```

### Test the split

```bash
for i in $(seq 1 10); do
  oc exec -n bookinfo deploy/productpage-v1 -- \
    python3 -c "
import urllib.request
r = urllib.request.urlopen('http://reviews:9080/reviews/1').read().decode()
if 'color' not in r: print('v1 - no stars')
elif 'black' in r: print('v2 - black stars')
elif 'red' in r: print('v3 - red stars')
"
done
# Expect: ~9x v1, ~1x v2
```

### Canary promotion pattern

```yaml
# Shift traffic gradually — edit weights and reapply
backendRefs:
- name: reviews-v1
  port: 9080
  weight: 75    # was 90
- name: reviews-v2
  port: 9080
  weight: 25    # was 10
```

---

## PeerAuthentication — STRICT mTLS

### Two-layer policy for defence in depth

```bash
# Mesh-wide (all namespaces)
oc apply -f peerauthentication.yaml   # name: default, ns: istio-system

# Namespace-scoped (bookinfo only — independent of mesh-wide)
oc apply -f peerauth-bookinfo.yaml    # name: bookinfo-strict, ns: bookinfo
```

The namespace policy makes bookinfo's mTLS posture independent of the
mesh-wide policy. If mesh-wide is changed to PERMISSIVE for migration
purposes, bookinfo remains STRICT.

### SNO restart — STRICT policy failure and recovery

After a kube-apiserver update on SNO, cascading restarts cause iptables
rules in pod network namespaces to become stale. Symptoms:

```
ztunnel error: connection closed due to policy rejection:
               explicitly denied by: istio-system/istio_converted_static_strict
dst.addr=<pod-ip>:9080  <- direct TCP on 9080, not HBONE on 15008
```

This means ztunnel is not intercepting traffic — pods send direct TCP
which STRICT correctly rejects as plain text.

Recovery:
```bash
# 1. Restart CNI to trigger iptables reconciliation
oc delete pod -n istio-cni <cni-pod-name>
oc get pods -n istio-cni -w  # wait for new pod Running

# 2. Restart bookinfo pods so CNI inserts fresh iptables rules
oc rollout restart deployment -n bookinfo
oc get pods -n bookinfo -w   # wait for all 1/1

# 3. Verify Waypoint is still attached
istioctl ztunnel-config svc --namespace ztunnel
# bookinfo services: WAYPOINT=waypoint

# 4. Re-apply STRICT (if switched to PERMISSIVE during diagnosis)
oc patch peerauthentication default -n istio-system \
  --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'
oc patch peerauthentication bookinfo-strict -n bookinfo \
  --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'
```

---

## AuthorizationPolicy — apply AFTER ingress

authorization-policy.yaml targets the productpage Service via Waypoint
and only allows GET from the ingress gateway ServiceAccount.

Apply order:
```
1. Deploy ingress gateway in bookinfo-ingress namespace
   -> creates ServiceAccount: bookinfo-gateway
2. Verify ingress works without policy
3. oc apply -f authorization-policy.yaml
4. Verify GET via ingress still works (200)
5. Test POST is denied (403 from Waypoint)
```

Do NOT apply before the ingress gateway SA exists — productpage will
be locked to a non-existent principal and all traffic is denied.

---

## istioctl reference — correct syntax for v1.27.5

```bash
# Flag names changed between versions — always check help first
istioctl ztunnel-config workloads --help

# Workload registry (use ztunnel pod name + namespace)
istioctl ztunnel-config workloads ztunnel-p9b9r.ztunnel --workload-namespace bookinfo

# Service view — correct command to verify Waypoint attachment
istioctl ztunnel-config svc --namespace ztunnel

# Proxy config — Waypoint cluster/endpoint view
istioctl proxy-config cluster -n bookinfo deploy/waypoint
istioctl proxy-config endpoint -n bookinfo deploy/waypoint

# Not supported in this version (unknown flag error)
# istioctl ztunnel-config workloads --pod <name>
# istioctl ztunnel-config workloads --ztunnel-namespace <ns>
```

---

## Healthy state — full verification checklist

```bash
# Operator
oc get csv -n openshift-operators | grep servicemesh
# servicemeshoperator3.v3.2.2   Succeeded

# Control plane
oc get istio default        # Healthy  v1.27.5
oc get istiocni default     # Healthy  v1.27.5
oc get ztunnel default      # Healthy  v1.27.5

# Pods
oc get pods -n istio-system  # istiod-xxx          1/1 Running
oc get pods -n istio-cni     # istio-cni-node-xxx   1/1 Running
oc get pods -n ztunnel       # ztunnel-xxx          1/1 Running

# Bookinfo — 1/1 confirms ambient (no sidecars)
oc get pods -n bookinfo
# all pods 1/1 including waypoint-xxx

# Waypoint attached to all bookinfo services
istioctl ztunnel-config svc --namespace ztunnel
# bookinfo services: WAYPOINT=waypoint

# mTLS confirmed
oc logs -n ztunnel ztunnel-p9b9r | grep "bookinfo" | tail -5
# All connections show dst.addr=<pod>:15008 (HBONE) not :9080 (plain)

# Traffic splitting working
# Run 10 requests to reviews — expect ~9x v1, ~1x v2

# Policy
oc get peerauthentication -A
# istio-system/default: STRICT
# bookinfo/bookinfo-strict: STRICT

oc get httproute -n bookinfo
# reviews  (ResolvedRefs: True, ResolvedWaypoints: True)
```

---

## What to do next

```
gateways/ingress/   Deploy Gateway API ingress for external access
                    Then return here to apply authorizationpolicy.yaml
```
