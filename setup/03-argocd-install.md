# 03 — ArgoCD Installation

Install ArgoCD for GitOps — it watches your devops repo and auto-syncs K8s manifests to the cluster. No more `kubectl apply` in production.

**Time:** ~20 minutes

---

## Step 1: Create namespace

```bash
kubectl create namespace argocd
```

## Step 2: Install ArgoCD via Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

Install from `templates/argocd/values.yaml`, pinning the chart version:

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 10.11.6 \
  -f output/argocd/values.yaml \
  --wait --timeout 10m
```

> **Pin the version.** An unpinned `helm install argo/argo-cd` takes whatever is newest that day, so two people following this guide a month apart get different clusters. It also makes a failure reproducible — this install failed on the first attempt with `context deadline exceeded` fetching the `.tgz` from `release-assets.githubusercontent.com`. If that happens, download once and install from the file:
>
> ```bash
> helm pull argo/argo-cd --version 10.11.6 --destination ./charts
> helm install argocd ./charts/argo-cd-10.11.6.tgz -n argocd -f output/argocd/values.yaml --wait
> ```

### Why a values file and not `--set`

Earlier versions of this guide used `--set` flags. **Two of them did nothing at all**, and Helm accepted both silently — unknown `--set` keys are not an error, and they even show up in `helm get values` as if they had worked:

| Flag that looks right | What actually happens |
|---|---|
| `--set server.insecure=true` | There is no `insecure` key under `server:` in this chart. The real one is `configs.params."server.insecure"`. |
| `--set applicationSet.enabled=false` | There is no `enabled` key under `applicationSet:` either. The controller keeps running. Use `applicationSet.replicas: 0`. |

Confirm for yourself before trusting any value:

```bash
helm show values argo/argo-cd --version 10.11.6 | grep -nE "^applicationSet:|^  insecure:"
```

The values file also sets CPU and memory on all four components. The chart ships `resources: {}` for every one of them, which puts all six ArgoCD pods in the **BestEffort** QoS class — the first thing the kubelet evicts under node pressure, which is exactly when you need ArgoCD working. Check:

```bash
kubectl -n argocd get pods -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
```

Every pod should say `Burstable`. If any says `BestEffort`, your values file was not applied.

**Verify:**

```bash
kubectl -n argocd get pods
```

Expected — four running pods, plus a completed one-shot Job:

```
NAME                                  READY   STATUS      RESTARTS
argocd-application-controller-0       1/1     Running     0
argocd-redis-xxx                      1/1     Running     0
argocd-redis-secret-init-xxx          0/1     Completed   0
argocd-repo-server-xxx                1/1     Running     0
argocd-server-xxx                     1/1     Running     0
```

No `argocd-dex-server` (no SSO configured) and no `argocd-applicationset-controller` pod (scaled to zero). The `argocd-redis-secret-init` Job is normal and stays `Completed`.

## Step 3: Get the initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo  # newline
```

Save this password temporarily.

## Step 4: Change the admin password

Use `kubectl exec` to access the ArgoCD CLI inside the cluster (no need to expose the API externally):

```bash
kubectl -n argocd exec -it deploy/argocd-server -- bash

# Inside the pod:
argocd login localhost:8080 --plaintext --username admin --password 'INITIAL_PASSWORD_FROM_STEP_3'
argocd account update-password --current-password 'INITIAL_PASSWORD_FROM_STEP_3' --new-password 'YOUR_NEW_STRONG_PASSWORD'
exit
```

Delete the initial secret (it's no longer needed):

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## Step 5: Add your devops repo

ArgoCD needs read access to the repo holding your manifests. Do this **declaratively**, with a
Secret — not with the `argocd` CLI. A CLI login lives inside one `kubectl exec` session and is
gone the moment that session ends, which is why the CLI-based verification in older versions of
this guide never worked.

Generate a deploy key **on the server**, so the private half never travels:

```bash
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f /root/argocd-deploy-key -N ""
cat /root/argocd-deploy-key.pub
```

Add the **public** key on GitHub: repo → Settings → Deploy keys → Add deploy key.
Title `argocd`, paste the key, and leave **"Allow write access" unticked**. ArgoCD only reads.

Now create the credential Secret. ArgoCD discovers it by label, not by name:

```bash
kubectl -n argocd create secret generic devops-repo \
  --from-literal=type=git \
  --from-literal=url={{DEVOPS_REPO}} \
  --from-file=sshPrivateKey=/root/argocd-deploy-key \
  --dry-run=client -o yaml \
  | kubectl label -f - --local -o yaml --dry-run=client \
      argocd.argoproj.io/secret-type=repository \
  | kubectl apply -f -
```

**Verify the label is there** — without it ArgoCD ignores the Secret completely and you get a
confusing "repository not accessible" later:

```bash
kubectl -n argocd get secret devops-repo --show-labels
```

Expected to include `argocd.argoproj.io/secret-type=repository`.

Confirm ArgoCD actually cloned it (do this after step 6, once an Application exists):

```bash
kubectl -n argocd logs deploy/argocd-repo-server --tail=200 | grep -i "Initializing git@"
```

## Step 6: Apply ArgoCD Application manifests

The templates are at `templates/argocd/`. Apply them:

```bash
kubectl apply -f templates/argocd/application.yaml
```

This creates ArgoCD Applications for your backend and frontend.

**Verify** — read the Application CRDs directly:

```bash
kubectl -n argocd get applications -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Expected:

```
NAME                      SYNC     HEALTH
{{PROJECT_NAME}}-backend   Synced   Healthy
{{PROJECT_NAME}}-frontend  Synced   Healthy
```

> **Do not use `argocd app list --plaintext` here.** It fails with
> `{"level":"fatal","msg":"Argo CD server address unspecified"}`. `--plaintext` selects the
> protocol; it does not supply a server address, and a login from an earlier interactive `exec`
> does not carry into a new one. `argocd app list --core` fails too, with
> `services is forbidden: User "system:serviceaccount:argocd:argocd-server" cannot list resource
> "services"`. The Applications are Kubernetes resources — just read them with `kubectl`.

### If an Application stays OutOfSync forever

A StatefulSet will do this, and syncing will not help. The API server defaults fields into
`volumeClaimTemplates` that cannot exist in your manifest (`spec.volumeMode`, and a
`status: {phase: Pending}` block inside the template). ArgoCD sees drift and tries to reconcile,
but `volumeClaimTemplates` is immutable, so it never succeeds.

This matters more than it looks: a permanently OutOfSync Application hides **real** drift in
everything else it manages. Add to that Application:

```yaml
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /spec/volumeClaimTemplates
```

You lose nothing — that field cannot be changed through GitOps anyway.

## Step 7: Understand sync behavior

The Application manifests set:

```yaml
syncPolicy:
  automated:
    prune: true      # Delete resources removed from git
    selfHeal: true   # Revert manual kubectl changes
```

This means:
- **Any push to the devops repo's `main` branch** → ArgoCD auto-syncs within ~3 minutes
- **Manual `kubectl apply/edit/delete`** → ArgoCD reverts it on next sync
- **Deleted from git** → ArgoCD deletes from cluster

> **Never use `kubectl apply` for ArgoCD-managed resources.** Commit to git instead. ArgoCD will revert your change.

## Step 8: ArgoCD hooks (PreSync / PostSync)

The backend deployment template includes hook Jobs for database migrations:

```yaml
# PreSync — runs BEFORE new pods deploy
apiVersion: batch/v1
kind: Job
metadata:
  name: backend-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

- **PreSync** (migrate): Runs `prisma migrate deploy` before new pods roll out
- **PostSync** (seed): Runs seeder after successful deployment

Hook Jobs use `hook-delete-policy: BeforeHookCreation` — the old Job is deleted when ArgoCD creates a new one for the next sync.

---

## Access the ArgoCD UI

You'll set up the TLS IngressRoute in [07-tls-dns.md](./07-tls-dns.md). For now, use port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
# Open http://localhost:8080 in your browser
# Login: admin / YOUR_PASSWORD
```

Or from the server via SSH tunnel:

```bash
ssh -L 8080:localhost:8080 myserver \
  kubectl -n argocd port-forward svc/argocd-server 8080:80
```

---

## Troubleshooting

### Application stuck in "Unknown" or "Missing"

```bash
kubectl -n argocd get app {{PROJECT_NAME}}-backend -o yaml | sed -n '/^status:/,$p' | head -40
```

Common causes:
- **Repo not connected:** Check step 5
- **Wrong path in Application spec:** The `spec.source.path` must match a directory in your devops repo
- **Branch mismatch:** Default is `HEAD`; set `targetRevision: main` explicitly

### Sync fails with "permission denied"

The deploy key doesn't have access. Verify on GitHub:
- Repo → Settings → Deploy Keys → check the key is listed and active

### Application shows "OutOfSync" but won't sync

```bash
kubectl -n argocd get app {{PROJECT_NAME}}-backend -o json \
  | jq -r '.status.resources[] | select(.status != "Synced") | "\(.kind)/\(.name): \(.status)"'
```

That lists exactly which resources differ from git. For a field-level diff, use the ArgoCD web UI
(App → the resource → Diff) — the CLI needs a logged-in session, which `kubectl exec` cannot give it.

### Hook Job fails

```bash
kubectl -n {{NAMESPACE}} logs job/backend-migrate --tail=50
```

Common causes:
- **Database not reachable:** Check DIRECT_URL in the Job's env
- **Migration error:** Fix in code, push, ArgoCD will re-trigger

---

## What you have now

- ArgoCD installed and running
- Devops repo connected (git → cluster)
- Applications defined with automated sync + self-heal
- PreSync/PostSync hooks for database migrations
- Admin password changed, initial secret deleted

**Next:** [04-infisical-install.md](./04-infisical-install.md) — set up secret management.
