# 12 — Monitoring: Prometheus, Grafana & Alertmanager

This guide adds metrics, dashboards and alerts to the cluster using `kube-prometheus-stack`, deployed by ArgoCD like everything else. Alerts go to Slack.

> **Status:** these manifests are validated for YAML syntax only. Run through the verification steps below on a staging cluster before trusting the alerts in production. Logs (Loki) are not included; see `docs/11-monitoring.md`.

---

## What you get

| Component | Purpose |
|-----------|---------|
| Prometheus | Scrapes metrics, stores {{PROMETHEUS_RETENTION}} of history |
| Alertmanager | Routes alerts to Slack |
| Grafana | Dashboards at `https://{{GRAFANA_DOMAIN}}` |
| node-exporter, kube-state-metrics | Node and Kubernetes object metrics |
| `monitoring/manifests/alert-rules.yaml` | Crash loops, OOM kills, missing replicas, HPA maxed out, failed jobs, disk/memory/PVC pressure, 5xx rate, TLS expiry |
| `monitoring/manifests/traefik-podmonitor.yaml` | Feeds Traefik request and certificate metrics to Prometheus |

### Footprint — measured

Measured on a 4-vCPU / 15Gi node running K3s v1.36.5, with ArgoCD, Infisical, PostgreSQL, Redis
and two app Deployments already present. `kube-prometheus-stack` 92.2.0, **lite profile**, 13
scrape targets, 108,835 head series:

| Pod | CPU (actual) | Memory (actual) | Memory limit |
|---|---|---|---|
| Grafana | 9m idle | **391Mi** | 640Mi |
| Prometheus | 8–19m | **348Mi** | 768Mi |
| Alertmanager | 1m | 24Mi | 128Mi |
| kube-state-metrics | 1–5m | 20Mi | 128Mi |
| prometheus-operator | 2m | 22Mi | 192Mi |
| node-exporter | 1–2m | 9Mi | 64Mi |

Cluster totals before and after installing the stack:

| | CPU requests | Memory requests | Memory limits |
|---|---|---|---|
| Before | 1425m (36%) | 2956Mi (19%) | 7978Mi (52%) |
| After | 1600m (40%) | 3916Mi (25%) | 9898Mi (64%) |

**So the stack costs roughly +175m CPU and +960Mi of memory requests.** Actual steady-state usage
is about 40m CPU and 815Mi of memory. It fits comfortably on a 15Gi node; it would not fit on a
2Gi one.

> **Do not lower the Grafana memory limit.** Grafana 12.x runs an embedded apiserver that
> registers ~20 GroupVersions at boot, and its startup peak is fixed regardless of how little it
> serves afterwards. At a 192Mi limit it OOMKills mid-boot (exit 137) in a permanent
> CrashLoopBackOff — on a node with 89% of its memory free. The logs are no help: they show a page
> of healthy `Installed APIs for app` lines and then stop. The only place the cause appears is:
>
> ```bash
> kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana \
>   -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="grafana")].lastState.terminated.reason}'
> ```

> **Prometheus memory scales with series, not with scrape interval or retention.** 108k head
> series from 13 targets is normal — most of it is cadvisor and kube-state-metrics, and it grows
> with every container you run. Lowering `scrapeInterval` reduces samples per series and
> `retention` reduces disk; neither meaningfully reduces head memory. To actually shrink
> Prometheus you must drop series, which is what the commented `cAdvisorMetricRelabelings` block
> at the bottom of `values-lite.yaml` does. Check your own number before tuning anything:
>
> ```bash
> IP=$(kubectl -n monitoring get pod prometheus-monitoring-kube-prometheus-prometheus-0 \
>        -o jsonpath='{.status.podIP}')
> curl -s "http://$IP:9090/api/v1/status/tsdb" | python3 -m json.tool | head -20
> ```
>
> An OOMKilled Prometheus loses its whole head block — up to 2 hours of unwritten samples — on
> every restart, so a limit that is merely "probably enough" costs you data silently.

On a small node, add the lite override: put `$values/monitoring/values-lite.yaml` after
`values.yaml` in `templates/argocd/monitoring.yaml`. Re-check real usage with
`kubectl top pods -n monitoring` after a day — series count climbs as you add workloads.

Logs are a separate optional guide: [13-logging.md](13-logging.md).

---

## Prerequisites

- ArgoCD 2.6+ running (multi-source Applications): `kubectl -n argocd get deploy argocd-server`
- Infisical operator installed (guide 04)
- DNS A record `{{GRAFANA_DOMAIN}}` → `{{SERVER_IP}}`
- A Slack incoming webhook URL for `{{ALERT_SLACK_CHANNEL}}`

---

## Step 1: Secrets

In Infisical, create a folder `/monitoring` in the `{{INFISICAL_ENV}}` environment with three secrets:

| Key | Value |
|-----|-------|
| `SLACK_WEBHOOK_URL` | Your Slack incoming webhook |
| `GRAFANA_ADMIN_USER` | e.g. `admin` |
| `GRAFANA_ADMIN_PASSWORD` | A strong generated password |

Create the machine-identity Secret in the `monitoring` namespace (same as other namespaces, see `docs/06-infisical.md`):

```bash
kubectl create namespace monitoring
kubectl create secret generic infisical-machine-identity \
  --namespace monitoring \
  --from-literal=clientId="<client-id>" \
  --from-literal=clientSecret="<client-secret>"
```

The identity needs read access to the `/monitoring` path.

---

## Step 2: Add the files to your devops repo

`init.sh` already placed them in `output/`. Confirm the repo has:

```
monitoring/values.yaml
monitoring/manifests/{alert-rules,grafana-ingress,secrets,traefik-podmonitor}.yaml
argocd/monitoring.yaml
```

Commit and push to `main`.

---

## Step 3: Register the ArgoCD Applications

```bash
kubectl apply -f argocd/monitoring.yaml
```

Watch the sync:

```bash
kubectl -n argocd get applications | grep monitoring
kubectl -n monitoring get pods -w
```

The first sync takes a few minutes. The `extras` app may show errors until the stack has installed its CRDs; it retries automatically.

---

## Step 4: Verify

```bash
# All pods Running
kubectl -n monitoring get pods

# The synced secret exists with all three keys
kubectl -n monitoring get secret monitoring-secrets -o jsonpath='{.data}' | python3 -c "import sys,json; print(list(json.load(sys.stdin)))"

# Prometheus sees its targets (open http://localhost:9090/targets)
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090

# Alert rules loaded (open http://localhost:9090/rules, look for {{PROJECT_NAME}}.workloads)
```

Grafana: open `https://{{GRAFANA_DOMAIN}}` and sign in with the credentials from Infisical. The built-in "Kubernetes / Compute Resources" dashboards should already show data.

---

## Step 5: Prove an alert reaches Slack

Create a deliberately broken pod in a watched namespace:

```bash
kubectl run crashtest -n {{STAGING_NAMESPACE}} --image=busybox --restart=Always -- sh -c "exit 1"
```

After about 10 minutes `PodCrashLooping` should fire and a message should appear in `{{ALERT_SLACK_CHANNEL}}`. Clean up:

```bash
kubectl delete pod crashtest -n {{STAGING_NAMESPACE}}
```

If nothing arrives: check `http://localhost:9093` (port-forward `svc/monitoring-kube-prometheus-alertmanager`) for the alert, then the Alertmanager logs for Slack errors.

---

## Step 6: Check the Traefik metrics

The ingress alerts (`IngressHigh5xxRate`, `TLSCertificateExpiringSoon`) only work if Prometheus
scrapes Traefik.

> **If you installed the chart with `helm` by hand instead of through ArgoCD, stop here — this
> step will fail and nothing will explain why.** The PodMonitor lives in
> `monitoring/manifests/`, which is applied by **ArgoCD** from your devops repo (Steps 2–3), not
> by the Helm release. A hand-installed chart has zero Traefik targets simply because the
> PodMonitor object does not exist. Either finish Steps 2–3, or apply it directly:
> `kubectl apply -f output/monitoring/manifests/traefik-podmonitor.yaml`

Confirm the port name the PodMonitor expects actually exists on the pod:

```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o jsonpath='{range .items[0].spec.containers[*].ports[*]}{.name}={.containerPort}{"\n"}{end}'
```

Verified on chart `traefik-40.1.5+up40.1.0` (Traefik 3.7.13), where this prints:

```
metrics=9100
traefik=8080
web=8000
websecure=8443
```

`metrics` is what the shipped PodMonitor asks for, so no edit is needed on that version. The name
does change across Traefik chart majors — if yours differs, edit
`monitoring/manifests/traefik-podmonitor.yaml`.

Then confirm the target is actually **up**, which is the part that catches a wrong port name,
a label-selector mismatch, or a NetworkPolicy in the way:

```bash
IP=$(kubectl -n monitoring get pod prometheus-monitoring-kube-prometheus-prometheus-0 \
       -o jsonpath='{.status.podIP}')
curl -s "http://$IP:9090/api/v1/targets?state=active" \
  | python3 -c 'import json,sys; [print(t["labels"]["job"], t["health"], t.get("lastError") or "") for t in json.load(sys.stdin)["data"]["activeTargets"] if "traefik" in str(t["discoveredLabels"]).lower()]'
```

Expected: `monitoring/traefik up`. Allow up to a minute — the operator has to regenerate scrape
config and Prometheus has to reload it, so a freshly applied PodMonitor reports `unknown` first.

Finally query a real metric:

```bash
curl -s --get "http://$IP:9090/api/v1/query" \
  --data-urlencode 'query=count(traefik_entrypoint_requests_total)'
```

> Note the metric name. Older versions of this guide said to query `traefik_service_requests_total`,
> which only has series once a request has actually been routed to a backend **service** — on a
> freshly built cluster that returns nothing and looks like a broken scrape.
> `traefik_entrypoint_requests_total` exists as soon as Traefik is serving anything at all.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Stack app fails with "metadata.annotations: Too long" | Missing `ServerSideApply=true` sync option |
| Extras app: "no matches for kind PrometheusRule" | CRDs not installed yet; wait for the stack app, it retries |
| Grafana pod stuck `Pending` | `local-path` PVC not bound; `kubectl describe pvc -n monitoring` |
| Grafana update hangs | RWO volume; the chart is set to `Recreate`, check it was not overridden |
| Constant `TargetDown` for etcd/scheduler | K3s embeds these; keep them disabled in `values.yaml` |
| No Slack messages | Webhook key name mismatch; it must be `SLACK_WEBHOOK_URL` in Infisical |
| Prometheus disk fills | Lower `PROMETHEUS_RETENTION` or raise `PROMETHEUS_STORAGE` (PVC cannot shrink) |
