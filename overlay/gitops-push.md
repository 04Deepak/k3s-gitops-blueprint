# GitOps Image-Tag Push Pattern

How CI deploys: build → push image → update manifest in git → ArgoCD syncs.

## Why Not Deploy Directly?

ArgoCD watches a git repo as the source of truth for what should be running.
If CI applied manifests directly (`kubectl apply`), ArgoCD would immediately
revert them to match git. So CI must change git, not the cluster.

```
┌─────────────┐     ┌──────────┐     ┌─────────────┐     ┌─────────┐
│  App Repo   │────▸│  CI/CD   │────▸│ Devops Repo │────▸│ ArgoCD  │
│  (code)     │     │ (build)  │     │ (manifests) │     │ (sync)  │
└─────────────┘     └──────────┘     └─────────────┘     └─────────┘
  push to dev        build image      git push tag        auto-sync
                     push to GHCR     update YAML         rollout
```

## The Pattern

After CI builds and pushes a Docker image tagged with the commit SHA:

```bash
# 1. Clone the devops repo
git clone https://x-access-token:${PAT}@github.com/org/project-devops.git devops
cd devops
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# 2. Update the image tag in the manifest
NEW_IMAGE="ghcr.io/org/my-backend:${SHORT_SHA}"
perl -pi -e "s|image: ghcr.io/org/my-backend:\S+|image: ${NEW_IMAGE}|g" \
  backend/deployment.yaml \
  backend/cronjobs.yaml

# 3. Commit
git add -A
git commit -m "ci(prod): backend image ${SHORT_SHA}" || exit 0

# 4. Push with retry (see Race Protection below)
```

### Why `perl -pi` Instead of `sed -i`

`sed -i` behaves differently on macOS vs Linux (macOS requires `sed -i ''`).
`perl -pi -e` works identically everywhere. The `\Q...\E` quoting handles
dots and slashes in image names without escaping.

### Why Update Both deployment.yaml and cronjobs.yaml

CronJobs run the same image as the Deployment. If you update the Deployment
but not the CronJobs, scheduled tasks run on old code while the API serves new
code. They must always match.

## Race Protection

**The problem:** If backend and frontend CI both deploy at the same time, they both
clone the devops repo, modify different files, and try to push. The second push fails
because the remote has moved forward.

**Without protection:** The second push fails silently (CI step exits 0), and the
deploy job reports success. But the frontend's image tag was never committed — the
old image keeps running. You don't notice until someone reports the bug isn't fixed.

**The fix:** `git pull --rebase` + retry loop + explicit `exit 1` guard.

```bash
git add -A
git commit -m "ci(prod): backend image ${SHORT_SHA}" || exit 0

MAX_RETRIES=3
for i in $(seq 1 $MAX_RETRIES); do
  echo "Push attempt $i/$MAX_RETRIES..."
  if git push origin main; then
    echo "Push succeeded on attempt $i"
    exit 0
  fi
  echo "Push failed, rebasing..."
  git pull --rebase origin main
done

# THIS LINE IS CRITICAL.
# Without it, the loop exhausting all retries exits with the loop's
# exit code (0 from the last `git pull --rebase`), and the CI job
# reports success. The image tag was never pushed. Silent failure.
echo "ERROR: All $MAX_RETRIES push attempts failed"
exit 1
```

### Why `exit 1` Matters

```
Without exit 1:          With exit 1:
  retry 1: push fails      retry 1: push fails
  retry 2: push fails      retry 2: push fails
  retry 3: push fails      retry 3: push fails
  loop ends                exit 1 → JOB FAILS ✘
  job exits 0 ✓ (WRONG!)   CI shows red
  deploy "succeeded"        you know immediately
  old image still running
```

This is a real bug that was caught in production.

## ArgoCD Sync

For **staging**, ArgoCD auto-sync is usually fast enough — the manifest change
triggers a sync within the polling interval (default 3 minutes, often faster).

For **production**, you may want an explicit sync to avoid waiting:

```bash
ssh deploy@server '
  kubectl exec deployment/argocd-server -n argocd -- \
    argocd login localhost:8080 --plaintext \
      --username admin \
      --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)" && \
  kubectl exec deployment/argocd-server -n argocd -- \
    argocd app sync my-backend --plaintext && \
  kubectl exec deployment/argocd-server -n argocd -- \
    argocd app wait my-backend --plaintext --timeout 300
'
```

This is an in-cluster exec — the CI runner never talks to ArgoCD directly,
only through SSH → kubectl exec. No ArgoCD port needs to be exposed.

## Concurrency Groups

```yaml
concurrency:
  group: deploy-prod-backend
  cancel-in-progress: false    # ← IMPORTANT
```

`cancel-in-progress: false` means: if two deploys are queued, the second waits
for the first to finish. It does NOT cancel the running deploy. Canceling a
deploy mid-push could leave the devops repo in a broken state.
