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

Install with `server.insecure: true` — Traefik terminates TLS, so ArgoCD doesn't need its own cert:

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.insecure=true \
  --set configs.params."server\.insecure"=true \
  --set applicationSet.enabled=false \
  --set notifications.enabled=false \
  --wait
```

> We disable ApplicationSet and Notifications controllers — they're not needed for a basic setup and eliminating them reduces pod count and log noise.

**Verify:**

```bash
kubectl -n argocd get pods
```

Expected (3 main pods Running):

```
NAME                                  READY   STATUS
argocd-application-controller-0       1/1     Running
argocd-repo-server-xxx                1/1     Running
argocd-server-xxx                     1/1     Running
argocd-redis-xxx                      1/1     Running
argocd-dex-server-xxx                 1/1     Running
```

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

ArgoCD needs read access to your devops Git repo.

**Option A: SSH key (recommended)**

Generate a deploy key:

```bash
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f /tmp/argocd-deploy-key -N ""
```

Add the public key (`/tmp/argocd-deploy-key.pub`) as a Deploy Key on your devops repo:
- GitHub → repo → Settings → Deploy Keys → Add deploy key
- Title: `argocd`
- Key: contents of `/tmp/argocd-deploy-key.pub`
- Allow write access: No (read-only is fine)

Add the repo to ArgoCD:

```bash
kubectl -n argocd exec -it deploy/argocd-server -- bash

argocd login localhost:8080 --plaintext --username admin --password 'YOUR_PASSWORD'
argocd repo add {{DEVOPS_REPO}} \
  --ssh-private-key-path /dev/stdin <<< 'PASTE_PRIVATE_KEY_HERE'
exit
```

**Option B: HTTPS with PAT**

```bash
kubectl -n argocd exec -it deploy/argocd-server -- bash

argocd login localhost:8080 --plaintext --username admin --password 'YOUR_PASSWORD'
argocd repo add https://github.com/{{GHCR_ORG}}/{{PROJECT_NAME}}-devops.git \
  --username git --password 'YOUR_GITHUB_PAT'
exit
```

**Verify the repo is connected:**

```bash
kubectl -n argocd exec deploy/argocd-server -- \
  argocd repo list --plaintext
```

Expected: your repo URL with `STATUS: Successful`.

## Step 6: Apply ArgoCD Application manifests

The templates are at `templates/argocd/`. Apply them:

```bash
kubectl apply -f templates/argocd/application.yaml
```

This creates ArgoCD Applications for your backend and frontend.

**Verify:**

```bash
kubectl -n argocd exec deploy/argocd-server -- \
  argocd app list --plaintext
```

Expected:

```
NAME                     CLUSTER                         NAMESPACE   STATUS   HEALTH
{{PROJECT_NAME}}-backend  https://kubernetes.default.svc  {{NS}}     Synced   Healthy
{{PROJECT_NAME}}-frontend https://kubernetes.default.svc  {{NS}}     Synced   Healthy
```

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
kubectl -n argocd exec deploy/argocd-server -- \
  argocd app get {{PROJECT_NAME}}-backend --plaintext
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
kubectl -n argocd exec deploy/argocd-server -- \
  argocd app diff {{PROJECT_NAME}}-backend --plaintext
```

This shows exactly what's different between git and the cluster.

### Hook Job fails

```bash
kubectl -n {{NAMESPACE}} logs job/backend-migrate
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
