# 13 — Logging: Loki + Grafana Alloy (optional, experimental)

Centralized, searchable container logs in Grafana. **Optional**: install this only if the node has spare RAM and CPU. On a small server, Prometheus + Grafana + Loki together can be too much, and the maintainer removed the full stack from a small server for exactly that reason. Start with metrics (guide 12), add logs later.

> **Status:** experimental. Every Helm value key was checked against the chart's default values (Loki 7.3.0, Alloy 1.13.1), but this profile has not been measured on a live cluster. The resource numbers are starting estimates.

---

## What you get

| Component | Role | Notes |
|-----------|------|-------|
| Loki (single binary) | Stores and indexes logs | Filesystem storage on a local PVC. No MinIO, no caches, no gateway |
| Grafana Alloy (DaemonSet) | Reads pod logs and ships them to Loki | Only the app namespaces ({{NAMESPACE}}, {{STAGING_NAMESPACE}}) |
| Loki data source in Grafana | Query logs in Explore | Added through `values-loki-datasource.yaml` |

The chart's own single-binary example asks for 2 CPU / 2 GiB RAM and runs MinIO. This profile requests 100m CPU and 256 Mi for Loki and limits it to 512 Mi, and keeps `{{LOKI_RETENTION}}` of logs on a `{{LOKI_STORAGE}}` volume. Measure before trusting it.

---

## Read this first: redaction

Loki durably stores whatever your apps print: tokens, emails, request bodies, personal data. Before enabling this:
1. Make sure your apps do not log secrets or personal data.
2. Keep retention short (`LOKI_RETENTION` in `vars.env`).
3. Restrict who can open Grafana.

`monitoring/alloy-values.yaml` has a commented redaction example. It is untested, so try it on your own log lines first.

---

## Prerequisites

- Monitoring stack installed (guide 12). Grafana must exist to query Loki
- Spare capacity: check `kubectl top nodes`
- `local-path` StorageClass (K3s default)

---

## Step 1: Add the files to your devops repo

`init.sh` already placed these in `output/`:

```
monitoring/loki-values.yaml
monitoring/alloy-values.yaml
monitoring/values-loki-datasource.yaml
argocd/logging.yaml
```

Commit and push to `main`.

---

## Step 2: Add the Loki data source to Grafana

In `argocd/monitoring.yaml`, add one more value file to the stack Application:

```yaml
helm:
  releaseName: monitoring
  valueFiles:
    - $values/monitoring/values.yaml
    - $values/monitoring/values-loki-datasource.yaml
```

Commit and push. ArgoCD updates Grafana.

---

## Step 3: Install Loki and Alloy

```bash
kubectl apply -f argocd/logging.yaml
kubectl -n monitoring get pods -w
```

Expect `loki-0` and one `alloy-*` pod per node. `loki-0` can take a minute to become Ready.

---

## Step 4: Verify

```bash
# Loki is ready
kubectl -n monitoring port-forward svc/loki 3100:3100
curl -s localhost:3100/ready          # prints: ready

# Alloy is shipping (look for no errors)
kubectl -n monitoring logs -l app.kubernetes.io/name=alloy --tail=30
```

In Grafana: **Explore → data source Loki → query** `{namespace="{{NAMESPACE}}"}`. You should see your app logs. Try `{namespace="{{NAMESPACE}}"} |= "error"` for a text search.

---

## Resource check (do this after a day)

```bash
kubectl top pods -n monitoring
kubectl -n monitoring get pvc
```

If Loki is near its 512 Mi limit, shorten retention or collect fewer namespaces. If the node is short on RAM, remove logging first (it is the optional piece) before touching metrics.

---

## Removing it

```bash
kubectl delete -f argocd/logging.yaml
```

Warning: the Loki chart deletes its PVC when the StatefulSet is deleted (`persistence.whenDeleted: Delete`). Your logs go with it.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `loki-0` Pending | PVC not bound: `kubectl describe pvc -n monitoring` |
| `loki-0` OOMKilled | Raise the memory limit, or collect fewer namespaces |
| No logs in Explore | Wrong namespace in `alloy-values.yaml`, or Alloy errors: check its logs |
| Alloy "forbidden" errors | RBAC not created; the chart creates it by default, check `rbac.create` was not disabled |
| Disk filling | Lower `LOKI_RETENTION` or raise `LOKI_STORAGE` (a PVC cannot shrink) |
| Loki data source red in Grafana | Loki not installed yet, or the service name differs from `loki` |
