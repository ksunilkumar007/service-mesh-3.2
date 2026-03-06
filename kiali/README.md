# Kiali

Service mesh observability UI for OSSM 3.2 ambient mode.

## Files

| File | Purpose |
|---|---|
| `kiali-operator.yaml` | OLM Subscription (in `operator/`) |
| `kiali.yaml` | Kiali CR |
| `kiali-rbac.yaml` | RBAC for Prometheus and bookinfo access |

---

## Prerequisites

- Sail Operator + Istio control plane running
- Tempo stack deployed in `tracing` namespace
- UWM enabled (`enableUserWorkload: true` in `cluster-monitoring-config`)
- `tracing` namespace labeled for istiod discovery (see Critical Notes below)

---

## Install

```bash
# 1. Install operator
oc apply -f ../operator/kiali-operator.yaml

# 2. Wait for CSV
oc get csv -n openshift-operators -w | grep kiali
# Expected: kiali-operator.v2.17.4   Succeeded

# 3. Apply RBAC
oc apply -f kiali-rbac.yaml

# 4. Deploy Kiali CR
oc apply -f kiali.yaml

# 5. Wait for pod
oc get pods -n istio-system -w | grep kiali
# Expected: kiali-xxxxx   1/1   Running

# 6. Get route
oc get route kiali -n istio-system -o jsonpath='{.spec.host}'
```

---

## Critical Notes

### 1. istiod Discovery Label on `tracing` namespace

**This is the most important step.** Without it, traces will not appear in Kiali.

istiod uses `discoverySelectors` with label `istio-discovery: enabled` to build its service registry. If the `tracing` namespace is missing this label, istiod cannot resolve `otel-collector.tracing.svc.cluster.local` and the Waypoint Envoy never gets the OTEL cluster configured — meaning no spans are exported to Tempo.

```bash
oc label namespace tracing istio-discovery=enabled
```

> ⚠️ This is NOT ambient enrollment. It does not add sidecar injection or ztunnel interception — it only makes the namespace's services visible to istiod.

Verify istiod picked it up (no more warns):
```bash
oc logs -n istio-system deployment/istiod --since=2m | grep -i "otel\|warn"
```

### 2. Service Account Name

The operator creates `kiali-service-account` in `istio-system` — not `kiali`. All RBAC must reference this name.

### 3. Prometheus — Thanos Proxy

Port `9091` (web) requires `thanos_proxy: enabled: true` so Kiali adds the required namespace scoping headers. Port `9092` (tenancy) returns `Bad Request` without these headers.

### 4. Tempo — Gateway URL

The TempoStack runs in `openshift` tenant mode with tenant `dev`. The gateway only serves:
```
/api/traces/v1/{tenant}/*
```

Kiali appends `/api/search` to `in_cluster_url`, so the correct base URL is:
```
https://tempo-tempo-gateway.tracing:8080/api/traces/v1/dev/tempo
```

This produces the working path:
```
/api/traces/v1/dev/tempo/api/search ✅
```

Do **not** use `tempo-tempo-query-frontend` — its ports require mTLS client certs that Kiali cannot present.

### 5. Kiali UI — Time Range for Traces

Set the time range to **Last 5m** when viewing traces. Longer windows show a sparse coverage warning because the trace volume is low relative to the window size.

---

## RBAC (`kiali-rbac.yaml`)

| Resource | Type | Role | Purpose |
|---|---|---|---|
| `kiali-monitoring-rbac` | ClusterRoleBinding | `cluster-monitoring-view` | Prometheus/Thanos access |
| `kiali-view-bookinfo` | RoleBinding (bookinfo) | `view` | Namespace metric access |

---

## Known Cosmetic Issues

These do not affect functionality:

| Issue | Cause | Impact |
|---|---|---|
| Cluster Status "Unreachable" for Prometheus/Tempo | Version check endpoints return 404 on tenancy ports | None — queries work |
| Waypoint WRN: `Ignoring service override for waypoint capture` | Known Kiali/ambient limitation for reviews-v* pods | Graph still renders correctly |

Both are suppressed via `disable_version_check: true` in `kiali.yaml` but the status banner may still appear.

---

## Validate

```bash
# Pod running
oc get pods -n istio-system | grep kiali

# RBAC correct
oc get clusterrolebinding kiali-monitoring-rbac
oc get rolebinding kiali-view-bookinfo -n bookinfo

# tracing namespace has discovery label
oc get namespace tracing --show-labels | grep istio-discovery

# Traces flowing (sent_spans_total > 0, send_failed_spans_total = 0)
oc port-forward -n tracing deployment/otel-collector 18888:8888 &
curl -s http://localhost:18888/metrics | grep "exporter_sent_spans\|exporter_send_failed"

# Generate traffic then check Kiali graph
for i in $(seq 1 30); do
  curl -s https://bookinfo.apps.cluster-p5bcx.dynamic.redhatworkshops.io/productpage > /dev/null
done
# Graph → Namespace: bookinfo → verify nodes and edges
# Click productpage → Traces tab → set Last 5m → verify spans appear
```
