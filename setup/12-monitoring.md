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

Footprint: **not measured.** Prometheus, Grafana and Alertmanager need real memory, and the maintainer had to remove the full stack (with Loki) from a small server for lack of CPU and RAM. On a small node, add the lite override: put `$values/monitoring/values-lite.yaml` after `values.yaml` in `templates/argocd/monitoring.yaml` (60s scrape, 3-day retention, smaller limits; the numbers are estimates). Check real usage with `kubectl top pods -n monitoring` after a day. Logs are a separate optional guide: [13-logging.md](13-logging.md).

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

The ingress alerts (`IngressHigh5xxRate`, `TLSCertificateExpiringSoon`) only work if Prometheus scrapes Traefik.

```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o yaml | grep -B2 -A3 containerPort
```

If the metrics port is not named `metrics`, edit `monitoring/manifests/traefik-podmonitor.yaml`. Then in Prometheus query `traefik_service_requests_total`; it should return series.

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
