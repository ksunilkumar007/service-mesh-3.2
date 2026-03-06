# observability/

## What this block does

Configures Prometheus scraping for the OSSM 3.2 ambient mode mesh using
OCP User Workload Monitoring (built-in). No additional operators required.
Metrics are accessible via OCP Console → Observe → Metrics.

---

## Lab environment

```
Cluster:    local-cluster (SNO, platform: None)
OCP:        4.20
Istio:      v1.27.5_ossm ambient mode
Monitoring: OCP User Workload Monitoring (already enabled)
```

---

## Folder structure

```
observability/
  README.md
  monitors/
    istiod-monitor.yaml     Service (15014) + ServiceMonitor -> istiod
    ztunnel-monitor.yaml    Service (15020) + ServiceMonitor -> ztunnel
    waypoint-monitor.yaml   PodMonitor -> Waypoint (15020 + 15090)
```

---

## Architecture

```
istiod pod (istio-system)
  port 15014 (http-monitoring)
  -> istiod-monitor Service
  -> istiod-monitor ServiceMonitor
  -> Prometheus (UWM)

ztunnel pod (ztunnel namespace)
  port 15020 (ztunnel-stats)
  -> ztunnel Service (created by us — none exists by default)
  -> ztunnel-monitor ServiceMonitor
  -> Prometheus (UWM)

Waypoint pod (bookinfo)
  port 15020 (metrics)       Istio agent stats
  port 15090 (http-envoy-prom)  Envoy L7 stats
  -> waypoint-monitor PodMonitor (two endpoints)
  -> Prometheus (UWM)

Prometheus (UWM)
  -> Thanos Query
  -> OCP Console Observe → Metrics
```

---

## Why PodMonitor for Waypoint

The Waypoint Service only exposes ports 15008 (HBONE) and 15021 (health).
Metrics ports 15020 and 15090 are not in the Service spec.
PodMonitor scrapes pods directly by label — no Service needed.

```yaml
selector:
  matchLabels:
    gateway.networking.k8s.io/gateway-name: waypoint
```

---

## Apply order

```bash
mkdir -p observability/monitors

# Apply all monitors
oc apply -f observability/monitors/istiod-monitor.yaml
oc apply -f observability/monitors/ztunnel-monitor.yaml
oc apply -f observability/monitors/waypoint-monitor.yaml

# Verify targets are up (wait ~60s for first scrape)
oc get servicemonitor -n istio-system
oc get servicemonitor -n ztunnel
oc get podmonitor -n bookinfo
```

---

## Verify scraping

```bash
# Check all targets are up
oc -n openshift-user-workload-monitoring \
  exec prometheus-user-workload-0 -c prometheus -- \
  curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    ns=t['labels'].get('namespace','')
    if ns in ('istio-system','ztunnel','bookinfo'):
        print(t['health'], ns, t['labels'].get('job',''), t.get('lastError',''))
"
# Expected:
# up  bookinfo     bookinfo/waypoint-monitor  (x2)
# up  istio-system istiod
# up  ztunnel      ztunnel
```

---

## Key metrics

### istiod (control plane)

| Metric | Description |
|---|---|
| `pilot_xds_pushes` | xDS config pushes to proxies |
| `pilot_proxy_convergence_time` | Time for proxies to converge |
| `pilot_k8s_reg_events` | Kubernetes resource events processed |
| `pilot_services` | Total services in mesh |
| `pilot_xds` | Connected proxy count |
| `pilot_push_triggers` | What triggered each config push |

### ztunnel (L4 data plane)

| Metric | Description |
|---|---|
| `workload_manager_active_proxy_count` | Active workloads enrolled in mesh |
| `workload_manager_proxies_started_total` | Total workloads ever enrolled |
| `istio_xds_message_bytes_total` | xDS message volume to/from ztunnel |
| `istio_xds_connection_terminations_total` | Proxy disconnections |

### Waypoint (L7 data plane)

| Metric | Description |
|---|---|
| `envoy_http_downstream_rq_total` | Total requests through Waypoint |
| `envoy_http_downstream_rq_time` | Request latency histogram |
| `envoy_cluster_upstream_rq_total` | Requests per upstream service |
| `envoy_http_downstream_cx_active` | Active connections |

---

## Useful PromQL queries

```promql
# Waypoint request rate (RPS)
rate(envoy_http_downstream_rq_total{namespace="bookinfo"}[5m])

# Waypoint p99 latency
histogram_quantile(0.99,
  rate(envoy_http_downstream_rq_time_bucket{namespace="bookinfo"}[5m]))

# istiod xDS push rate
rate(pilot_xds_pushes[5m])

# Active workloads in ztunnel
workload_manager_active_proxy_count

# ztunnel xDS message rate
rate(istio_xds_message_bytes_total[5m])

# Proxy convergence p99
histogram_quantile(0.99, rate(pilot_proxy_convergence_time_bucket[5m]))
```

Open OCP Console → Observe → Metrics and paste any of the above.

---

## Lab findings

### Finding 1 — ztunnel has no Service by default

The ztunnel namespace has no Service resource. Without a Service,
ServiceMonitor cannot scrape ztunnel pods. Must create a Service
targeting port 15020 with label `service: ztunnel` to match the
ServiceMonitor selector.

### Finding 2 — istiod Service does not expose metrics port

The existing `istiod` Service exposes 15010, 15012, 15017, 443.
Port 15014 (http-monitoring) is not included. Must create a separate
Service `istiod-monitor` with port 15014 and label `istio: pilot`
to match the ServiceMonitor selector.

### Finding 3 — Waypoint metrics ports not in Waypoint Service

The Waypoint Service only exposes 15008 (HBONE) and 15021 (health).
Metrics ports 15020 and 15090 require a PodMonitor that selects
pods directly by `gateway.networking.k8s.io/gateway-name: waypoint`.

### Finding 4 — ztunnel metrics are not named ztunnel_*

Despite the target being the ztunnel pod, metrics use `istio_*` and
`workload_manager_*` prefixes, not `ztunnel_*`. Searching for
`ztunnel` in metric names returns nothing. Use instance label filter:
```promql
{instance="<ztunnel-pod-ip>:15020"}
```

### Finding 5 — ambient mode has no sidecar metrics

In sidecar mode, each app pod exposes metrics on port 15020 via the
injected Envoy sidecar. In ambient mode, app pods have no sidecar —
port 15020 does not exist on app pods. All L7 metrics come from the
Waypoint, all L4 metrics from ztunnel.

---

## Verify healthy state

```bash
# Targets up
oc -n openshift-user-workload-monitoring \
  exec prometheus-user-workload-0 -c prometheus -- \
  curl -s "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22ztunnel%22%7D" \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']: print(r['metric']['job'], r['value'][1])
"
# ztunnel 1

# Waypoint metrics present
oc -n openshift-user-workload-monitoring \
  exec prometheus-user-workload-0 -c prometheus -- \
  curl -s "http://localhost:9090/api/v1/query?query=envoy_http_downstream_rq_total" \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('waypoint metrics:', len(d['data']['result']), 'series')
"
```

---

## What to do next

```
Update validate.sh with observability checks
```
