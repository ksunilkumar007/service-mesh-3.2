#!/bin/bash
# =============================================================================
# service-mesh-3.2 — end to end validation script
# Tests: mesh health, mTLS, Waypoint, traffic splitting,
#        ingress, AuthorizationPolicy, egress ServiceEntry
# =============================================================================

#!/bin/bash

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}  PASS${NC}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "${YELLOW}  WARN${NC}  $1"; WARN=$((WARN+1)); }
section() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# =============================================================================
# SECTION 1 — Control plane health
# =============================================================================
section "Control plane"

# Istio CR
STATUS=$(oc get istio default -o jsonpath='{.status.state}' 2>/dev/null)
STATUS=${STATUS:-"NotFound"}
if [[ "$STATUS" == "Healthy" ]]; then pass "Istio CR: Healthy"; else fail "Istio CR: $STATUS"; fi

# IstioCNI CR
STATUS=$(oc get istiocni default -o jsonpath='{.status.state}' 2>/dev/null)
STATUS=${STATUS:-"NotFound"}
if [[ "$STATUS" == "Healthy" ]]; then pass "IstioCNI CR: Healthy"; else fail "IstioCNI CR: $STATUS"; fi

# ZTunnel CR
STATUS=$(oc get ztunnel default -o jsonpath='{.status.state}' 2>/dev/null)
STATUS=${STATUS:-"NotFound"}
if [[ "$STATUS" == "Healthy" ]]; then pass "ZTunnel CR: Healthy"; else fail "ZTunnel CR: $STATUS"; fi

# istiod pod
READY=$(oc get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$READY" == "True" ]]; then pass "istiod pod: Ready"; else fail "istiod pod: not Ready"; fi

# ztunnel pod
READY=$(oc get pods -n ztunnel -l app=ztunnel -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$READY" == "True" ]]; then pass "ztunnel pod: Ready"; else fail "ztunnel pod: not Ready"; fi

# CNI pod
READY=$(oc get pods -n istio-cni -l k8s-app=istio-cni-node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$READY" == "True" ]]; then pass "CNI pod: Ready"; else fail "CNI pod: not Ready"; fi

# =============================================================================
# SECTION 2 — Bookinfo pods
# =============================================================================
section "Bookinfo pods"

EXPECTED_PODS=("details-v1" "productpage-v1" "ratings-v1" "reviews-v1" "reviews-v2" "reviews-v3" "waypoint")

for POD_PREFIX in "${EXPECTED_PODS[@]}"; do
  READY=$(oc get pods -n bookinfo -l "app=${POD_PREFIX%-*}" \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || \
    oc get pods -n bookinfo --no-headers 2>/dev/null | grep "^${POD_PREFIX}" | awk '{print $2}')

  POD_READY=$(oc get pods -n bookinfo --no-headers 2>/dev/null | grep "^${POD_PREFIX}" | head -1 | awk '{print $2}')

  if [[ "$POD_READY" == "1/1" ]]; then
    pass "bookinfo/${POD_PREFIX}: 1/1 Running (ambient — no sidecar)"
  elif [[ "$POD_READY" == "2/2" ]]; then
    fail "bookinfo/${POD_PREFIX}: 2/2 Running — sidecar injected (should be ambient 1/1)"
  else
    fail "bookinfo/${POD_PREFIX}: not ready ($POD_READY)"
  fi
done

# =============================================================================
# SECTION 3 — Ambient enrollment
# =============================================================================
section "Ambient enrollment (ztunnel workload registry)"

ZTUNNEL_POD=$(oc get pods -n ztunnel -l app=ztunnel -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

for APP in details productpage ratings reviews; do
  PROTOCOL=$(istioctl ztunnel-config workloads ${ZTUNNEL_POD}.ztunnel \
    --workload-namespace bookinfo 2>/dev/null | grep " ${APP}-" | head -1 | awk '{print $NF}')
  if [[  "$PROTOCOL" == "HBONE" ]]; then pass "${APP}: PROTOCOL=HBONE (enrolled)"; else fail "${APP}: PROTOCOL=${PROTOCOL} (expected HBONE)"; fi
done

# Gateway pod should be TCP (excluded from ambient by design)
GW_PROTOCOL=$(istioctl ztunnel-config workloads ${ZTUNNEL_POD}.ztunnel \
  --workload-namespace bookinfo-ingress 2>/dev/null | grep "bookinfo-gateway" | head -1 | awk '{print $NF}')
if [[  "$GW_PROTOCOL" == "TCP" ]]; then pass "ingress gateway: PROTOCOL=TCP (correctly excluded from ambient)"; else warn "ingress gateway: PROTOCOL=${GW_PROTOCOL} (expected TCP)"; fi

# =============================================================================
# SECTION 4 — Waypoint
# =============================================================================
section "Waypoint proxy"

# Waypoint pod
WP_READY=$(oc get pods -n bookinfo -l "gateway.networking.k8s.io/gateway-name=waypoint" \
  --no-headers 2>/dev/null | awk '{print $2}')
if [[  "$WP_READY" == "1/1" ]]; then pass "Waypoint pod: 1/1 Running"; else fail "Waypoint pod: $WP_READY"; fi

# Waypoint attached to all bookinfo services
for SVC in details productpage ratings reviews; do
  WAYPOINT=$(istioctl ztunnel-config svc --namespace ztunnel 2>/dev/null | \
    grep "bookinfo " | grep " ${SVC} " | awk '{print $4}')
  if [[  "$WAYPOINT" == "waypoint" ]]; then pass "Service ${SVC}: WAYPOINT=waypoint"; else fail "Service ${SVC}: WAYPOINT=${WAYPOINT} (expected waypoint)"; fi
done

# =============================================================================
# SECTION 5 — PeerAuthentication
# =============================================================================
section "PeerAuthentication (STRICT mTLS)"

MODE=$(oc get peerauthentication default -n istio-system -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
if [[  "$MODE" == "STRICT" ]]; then pass "Mesh-wide PeerAuthentication: STRICT"; else fail "Mesh-wide PeerAuthentication: $MODE"; fi

MODE=$(oc get peerauthentication bookinfo-strict -n bookinfo -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
if [[  "$MODE" == "STRICT" ]]; then pass "bookinfo PeerAuthentication: STRICT"; else fail "bookinfo PeerAuthentication: $MODE"; fi

# =============================================================================
# SECTION 6 — Traffic splitting
# =============================================================================
section "Traffic splitting (HTTPRoute 90/10)"

# HTTPRoute status
ACCEPTED=$(oc get httproute reviews -n bookinfo \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
RESOLVED=$(oc get httproute reviews -n bookinfo \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)
WAYPOINTS=$(oc get httproute reviews -n bookinfo \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedWaypoints")].status}' 2>/dev/null)

if [[  "$ACCEPTED" == "True" ]]; then pass "HTTPRoute reviews: Accepted"; else fail "HTTPRoute reviews: Accepted=${ACCEPTED}"; fi
if [[  "$RESOLVED" == "True" ]]; then pass "HTTPRoute reviews: ResolvedRefs"; else fail "HTTPRoute reviews: ResolvedRefs=${RESOLVED}"; fi
if [[  "$WAYPOINTS" == "True" ]]; then pass "HTTPRoute reviews: ResolvedWaypoints"; else fail "HTTPRoute reviews: ResolvedWaypoints=${WAYPOINTS}"; fi

# Functional traffic split test
echo "  Testing 90/10 split (10 requests)..."
V1=0; V2=0; V3=0; ERRORS=0
for i in $(seq 1 10); do
  RESULT=$(oc exec -n bookinfo deploy/productpage-v1 -- \
    python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://reviews:9080/reviews/1').read().decode()
    if 'color' not in r: print('v1')
    elif 'black' in r: print('v2')
    elif 'red' in r: print('v3')
    else: print('v1')
except Exception as e:
    print('error')
" 2>/dev/null || echo "error")
  case "$RESULT" in
    v1) ((V1++)) ;;
    v2) ((V2++)) ;;
    v3) ((V3++)) ;;
    *)  ((ERRORS++)) ;;
  esac
done

if [[ $ERRORS -eq 0 ]]; then
  pass "Traffic split: v1=${V1}/10 v2=${V2}/10 v3=${V3}/10 (expect ~9/1/0)"
  [[ $V3 -gt 0 ]] && warn "reviews-v3 received traffic — should be 0 (check HTTPRoute weights)"
else
  fail "Traffic split: ${ERRORS} errors out of 10 requests"
fi

# =============================================================================
# SECTION 7 — Mesh-internal connectivity (mTLS via ztunnel)
# =============================================================================
section "Mesh-internal connectivity"

for TARGET in "details:9080/details/1" "reviews:9080/reviews/1" "ratings:9080/ratings/1"; do
  SVC=${TARGET%%:*}
  PATH_=${TARGET#*9080}
  RESULT=$(oc exec -n bookinfo deploy/productpage-v1 -- \
    python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://${TARGET}')
    print(r.status)
except Exception as e:
    print('FAIL:', e)
" 2>/dev/null)
  if [[  "$RESULT" == "200" ]]; then pass "productpage -> ${SVC}: 200 OK"; else fail "productpage -> ${SVC}: $RESULT"; fi
done

# =============================================================================
# SECTION 8 — Ingress gateway
# =============================================================================
section "Ingress gateway"

# Gateway programmed
PROGRAMMED=$(oc get gateway bookinfo-gateway -n bookinfo-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
if [[  "$PROGRAMMED" == "True" ]]; then pass "Ingress Gateway: Programmed"; else fail "Ingress Gateway: Programmed=${PROGRAMMED}"; fi

# Service type
SVC_TYPE=$(oc get svc bookinfo-gateway-istio -n bookinfo-ingress \
  -o jsonpath='{.spec.type}' 2>/dev/null)
if [[  "$SVC_TYPE" == "ClusterIP" ]]; then pass "Ingress Gateway Service: ClusterIP"; else fail "Ingress Gateway Service: type=${SVC_TYPE} (expected ClusterIP on bare metal)"; fi

# HTTPRoute accepted
ACCEPTED=$(oc get httproute bookinfo -n bookinfo \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
if [[  "$ACCEPTED" == "True" ]]; then pass "Ingress HTTPRoute: Accepted"; else fail "Ingress HTTPRoute: Accepted=${ACCEPTED}"; fi

# OCP Route
ROUTE=$(oc get route bookinfo -n bookinfo-ingress \
  -o jsonpath='{.spec.host}' 2>/dev/null)
if [[  -n "$ROUTE" ]]; then pass "OCP Route: $ROUTE"; else fail "OCP Route: not found"; fi

# External GET — expect 200
HOSTNAME=$(oc get route bookinfo -n bookinfo-ingress -o jsonpath='{.spec.host}' 2>/dev/null)
if [[ -n "$HOSTNAME" ]]; then
  HTTP_CODE=$(curl -L -o /dev/null -s -w "%{http_code}" \
    --connect-timeout 10 \
    "https://${HOSTNAME}/productpage" 2>/dev/null)
  if [[  "$HTTP_CODE" == "200" ]]; then pass "External GET /productpage: 200 OK"; else fail "External GET /productpage: HTTP ${HTTP_CODE}"; fi

  # External POST — expect 403 (blocked by AuthorizationPolicy at Gateway)
  HTTP_CODE=$(curl -L -X POST -o /dev/null -s -w "%{http_code}" \
    --connect-timeout 10 \
    "https://${HOSTNAME}/productpage" 2>/dev/null)
  [[ "$HTTP_CODE" == "403" ]] && pass "External POST /productpage: 403 Forbidden (AuthorizationPolicy enforcing)" \
    || fail "External POST /productpage: HTTP ${HTTP_CODE} (expected 403 — check ingress authpolicy)"
fi

# =============================================================================
# SECTION 9 — AuthorizationPolicy
# =============================================================================
section "AuthorizationPolicy"

# Ingress gateway policy
ACTION=$(oc get authorizationpolicy ingress-policy -n bookinfo-ingress \
  -o jsonpath='{.spec.action}' 2>/dev/null || echo "")
if [[  "$ACTION" == "ALLOW" ]]; then pass "Ingress AuthorizationPolicy: ALLOW (GET only)"; else fail "Ingress AuthorizationPolicy: not found or action=${ACTION}"; fi

# Confirm no rogue policies blocking bookinfo namespace
BOOKINFO_POLICIES=$(oc get authorizationpolicy -n bookinfo --no-headers 2>/dev/null | wc -l)
if [[  "$BOOKINFO_POLICIES" -eq "0" ]]; then pass "bookinfo namespace: no AuthorizationPolicies (no accidental inbound blocks)"; else warn "bookinfo namespace: ${BOOKINFO_POLICIES} AuthorizationPolicy found — verify not blocking inbound"; fi

# =============================================================================
# =============================================================================
# SECTION 10 — Egress (Waypoint + ServiceEntry + AuthorizationPolicy)
# =============================================================================
section "Egress (Waypoint enforcement)"

EGRESS_WP=$(oc get pods -n egress --no-headers 2>/dev/null | grep "egress-waypoint" | head -1 | awk '{print $2}')
if [[ "$EGRESS_WP" == "1/1" ]]; then pass "egress Waypoint pod: 1/1 Running"; else fail "egress Waypoint pod: $EGRESS_WP"; fi

PROGRAMMED=$(oc get gateway egress-waypoint -n egress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
if [[ "$PROGRAMMED" == "True" ]]; then pass "egress Waypoint: Programmed"; else fail "egress Waypoint: Programmed=${PROGRAMMED}"; fi

HOSTS=$(oc get serviceentry github-external -n istio-system -o jsonpath='{.spec.hosts[0]}' 2>/dev/null)
if [[ "$HOSTS" == "github.com" ]]; then pass "ServiceEntry github-external: registered"; else fail "ServiceEntry github-external: not found"; fi

WP_BOUND=$(oc get serviceentry github-external -n istio-system -o jsonpath='{.status.conditions[?(@.type=="istio.io/WaypointBound")].status}' 2>/dev/null)
if [[ "$WP_BOUND" == "True" ]]; then pass "ServiceEntry: bound to egress Waypoint"; else fail "ServiceEntry: WaypointBound=${WP_BOUND}"; fi

WAYPOINT=$(istioctl ztunnel-config svc --namespace ztunnel 2>/dev/null | grep "github-external" | awk '{print $4}')
if [[ "$WAYPOINT" == "egress-waypoint" ]]; then pass "github.com: WAYPOINT=egress-waypoint"; else fail "github.com: WAYPOINT=${WAYPOINT} (expected egress-waypoint)"; fi

DNS_IP=$(oc exec -n bookinfo deploy/productpage-v1 -- python3 -c "import socket; print(socket.gethostbyname('github.com'))" 2>/dev/null)
if [[ "$DNS_IP" == "240.240."* ]]; then pass "DNS capture: github.com -> ${DNS_IP} (synthetic mesh IP)"; else fail "DNS capture: github.com -> ${DNS_IP} (expected 240.240.x.x)"; fi

WP_ACCEPTED=$(oc get authorizationpolicy github-egress-policy -n istio-system -o jsonpath='{.status.conditions[?(@.type=="WaypointAccepted")].status}' 2>/dev/null)
if [[ "$WP_ACCEPTED" == "True" ]]; then pass "egress AuthorizationPolicy: WaypointAccepted"; else fail "egress AuthorizationPolicy: WaypointAccepted=${WP_ACCEPTED}"; fi

RESULT="error"
for attempt in 1 2 3; do
  RESULT=$(oc exec -n bookinfo deploy/productpage-v1 -- python3 -c "
import urllib.request, ssl
ctx = ssl.create_default_context()
try:
    r = urllib.request.urlopen('https://github.com', context=ctx)
    print(r.status)
except Exception as e:
    print('FAIL:', e)
" 2>/dev/null || echo "error")
  [[ "$RESULT" == "200" ]] && break
  sleep 3
done
if [[ "$RESULT" == "200" ]]; then pass "productpage -> github.com: 200 OK (ALLOW at Waypoint)"; else fail "productpage -> github.com: $RESULT (after 3 attempts)"; fi

DENIED=$(oc exec -n bookinfo deploy/ratings-v1 -- curl -o /dev/null -s -w "%{http_code}" --max-time 5 https://github.com 2>/dev/null)
if [[ "$DENIED" == "000" ]]; then pass "ratings -> github.com: blocked (DENY at Waypoint)"; else fail "ratings -> github.com: ${DENIED} (expected 000)"; fi

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "\n${BLUE}━━━ Summary ━━━${NC}"
echo -e "${GREEN}  PASS: ${PASS}${NC}"
[[ $WARN -gt 0 ]] && echo -e "${YELLOW}  WARN: ${WARN}${NC}"
[[ $FAIL -gt 0 ]] && echo -e "${RED}  FAIL: ${FAIL}${NC}"

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All tests passed.${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} test(s) failed. Review output above.${NC}"
  exit 1
fi
