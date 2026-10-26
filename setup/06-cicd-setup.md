# 06 — CI/CD Setup (GitHub Actions)

Set up GitHub Actions pipelines that build, test, push images to GHCR, update the devops repo, and trigger ArgoCD sync — fully automated on every push.

**Time:** ~30 minutes

---

## How the pipeline works

```
Push to app repo (main/dev)
  → GitHub Actions: test → build Docker image → push to GHCR
  → Clone devops repo → update image tag in deployment.yaml → git push
  → ArgoCD detects change → syncs to cluster
  → PreSync hook runs migrations → new pods roll out
```

This is **GitOps**: the devops repo is the single source of truth for what's deployed. CI never talks to the cluster directly (except to trigger ArgoCD sync for immediate feedback).

---

## Step 1: GitHub repo secrets

Set these on **each app repo** (backend + frontend):

Go to repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value | Purpose |
|--------|-------|---------|
| `GITOPS_PAT` | GitHub PAT with `repo` + `write:packages` scope | Push to devops repo + GHCR auth |
| `SSH_PRIVATE_KEY` | Contents of your server SSH private key | SSH into server for ArgoCD sync |
| `SERVER_HOST` | Your server IP (e.g., `203.0.113.10`) | SSH target |
| `SERVER_USER` | `root` | SSH user |

### GitHub repo variables (optional)

Go to repo → Settings → Secrets and variables → Actions → Variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `CI_RUNNER` | `self-hosted` or empty | Override runner (default: `ubuntu-latest`) |

## Step 2: Copy CI workflow templates

Copy the workflow templates to each app repo:

**Backend:**

```bash
cd your-backend-repo
mkdir -p .github/workflows
cp /path/to/devops-blueprint/templates/ci/backend-ci.yml .github/workflows/ci.yml
```

**Frontend:**

```bash
cd your-frontend-repo
mkdir -p .github/workflows
cp /path/to/devops-blueprint/templates/ci/frontend-ci.yml .github/workflows/ci.yml
```

Review and update the placeholders in each workflow file. Key values to set:

```yaml
env:
  REGISTRY: ghcr.io
  BACKEND_IMAGE: ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-be
  DEVOPS_REPO: {{GHCR_ORG}}/{{PROJECT_NAME}}-devops
  DEPLOY_FILE: backend/deployment.yaml    # path in devops repo
  CRONJOB_FILE: backend/cronjobs.yaml     # path in devops repo
```

## Step 3: Understand the workflow structure

### Backend CI (`backend-ci.yml`)

**Jobs:**

1. **`test`** — checkout → install deps → generate types → typecheck → lint → unit test → build
2. **`integration-db`** — spin up Postgres in Docker → run DB integration tests
3. **`build-push`** (on push, after tests pass) — Docker build → push to GHCR with `<sha>` + `latest` tags
4. **`deploy`** (main branch) — clone devops → update image tag → git push → SSH → ArgoCD sync
5. **`deploy-staging`** (dev branch) — same for staging manifests

### Frontend CI (`frontend-ci.yml`)

**Jobs:**

1. **`test`** — checkout → install deps → typecheck → lint → test → build
2. **`build-push`** — Docker build with `VITE_API_BASE_URL=/api` baked in
3. **`deploy`** / **`deploy-staging`** — same GitOps push pattern

### Image tagging

```bash
IMAGE_TAG=$(echo "${{ github.sha }}" | cut -c1-7)
```

Every image is tagged with the short commit SHA (7 chars). The `latest` tag is also updated. The SHA tag is what goes into the deployment manifest — it's immutable.

### GitOps push (the critical part)

```yaml
- name: Update image tag in devops repo
  run: |
    git clone https://x-access-token:${{ secrets.GITOPS_PAT }}@github.com/$DEVOPS_REPO.git devops
    cd devops
    
    # Update deployment image tag
    perl -pi -e "s|image: .*$BACKEND_IMAGE.*|image: $BACKEND_IMAGE:$IMAGE_TAG|g" $DEPLOY_FILE
    
    # Update cronjob image tags (if applicable)
    perl -pi -e "s|image: .*$BACKEND_IMAGE.*|image: $BACKEND_IMAGE:$IMAGE_TAG|g" $CRONJOB_FILE
    
    git config user.name "CI Bot"
    git config user.email "ci@example.com"
    git add -A
    git commit -m "ci: update backend image to $IMAGE_TAG" || exit 0
    
    # Race protection: retry with rebase
    for i in 1 2 3; do
      git pull --rebase origin main
      if git push origin main; then
        echo "Push succeeded on attempt $i"
        exit 0
      fi
      echo "Push failed, retrying ($i/3)..."
      sleep 2
    done
    echo "All push attempts failed"
    exit 1
```

### GHCR authentication (macOS runner compatible)

The workflow avoids `docker login` (which uses the macOS Keychain on self-hosted Mac runners):

```yaml
- name: Configure GHCR auth
  run: |
    DOCKER_CONFIG=$(mktemp -d)
    echo '{"auths":{"ghcr.io":{"auth":"'$(echo -n "${{ github.actor }}:${{ secrets.GITOPS_PAT }}" | base64)'"}}}' > "$DOCKER_CONFIG/config.json"
    echo "DOCKER_CONFIG=$DOCKER_CONFIG" >> $GITHUB_ENV
```

### Race protection

When backend and frontend deploy simultaneously, both try to push to the devops repo. The `git pull --rebase + retry` pattern handles this:

```
BE push succeeds (attempt 1)
FE push fails (conflict) → pull --rebase → push succeeds (attempt 2)
```

Without this, the loser silently reverts the winner's image tag.

## Step 4: Push and verify

```bash
cd your-backend-repo
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow"
git push origin dev
```

Watch the workflow run:
- Go to repo → Actions → click the running workflow
- Verify: `test` passes → `build-push` succeeds → `deploy-staging` pushes to devops repo

Check the devops repo for the updated image tag:

```bash
cd your-devops-repo
git pull
grep "image:" staging/backend/deployment.yaml
```

Expected: `image: ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-be:<sha>`

### Deploy concurrency

The workflow uses concurrency groups to prevent overlapping deploys:

```yaml
concurrency:
  group: deploy-prod-backend
  cancel-in-progress: false  # Don't cancel running deploys
```

## Step 5: ArgoCD sync trigger (optional)

The workflow can SSH to the server and trigger an immediate sync instead of waiting for ArgoCD's polling interval:

```yaml
- name: Trigger ArgoCD sync
  run: |
    ssh -o StrictHostKeyChecking=no ${{ secrets.SERVER_USER }}@${{ secrets.SERVER_HOST }} << 'EOF'
      kubectl -n argocd exec deploy/argocd-server -- \
        argocd login localhost:8080 --plaintext --username admin --password "$ARGOCD_PASSWORD"
      kubectl -n argocd exec deploy/argocd-server -- \
        argocd app sync {{PROJECT_NAME}}-backend --plaintext
      kubectl -n argocd exec deploy/argocd-server -- \
        argocd app wait {{PROJECT_NAME}}-backend --plaintext --timeout 300
    EOF
```

> **Note:** This uses `kubectl exec` to run the ArgoCD CLI inside the cluster — no need to expose the ArgoCD API externally.

---

## Adapting for GitLab CI

The same pattern works with GitLab CI. Key differences:
- Use `CI_REGISTRY` / `CI_REGISTRY_IMAGE` instead of GHCR
- Store secrets in GitLab CI/CD variables
- Replace GitHub Actions syntax with `.gitlab-ci.yml` stages
- The GitOps push step is identical (git clone → sed → push)

---

## Troubleshooting

### CI can't push to GHCR

- Check `GITOPS_PAT` has `write:packages` scope
- Verify the image path matches: `ghcr.io/OWNER/IMAGE` (owner is lowercase)

### CI can't push to devops repo

- Check `GITOPS_PAT` has `repo` scope
- Verify the PAT owner has push access to the devops repo

### Deploy step SSH fails

- Check `SSH_PRIVATE_KEY` is the full private key (including `-----BEGIN/END-----`)
- Verify `SERVER_HOST` and `SERVER_USER` are correct
- Test locally: `ssh -i ~/.ssh/key root@SERVER_HOST 'echo ok'`

### Race condition on devops push

If you see "push failed" in logs, the retry mechanism should handle it. If all 3 retries fail, there's likely a persistent conflict. Check:

```bash
cd devops-repo
git log --oneline -5
```

---

## What you have now

- Automated CI/CD: push → test → build → deploy
- GitOps: devops repo is the source of truth
- Race protection on concurrent deploys
- Staging deploys on `dev` branch, production on `main`

**Next:** [07-tls-dns.md](./07-tls-dns.md) — set up domains and TLS certificates.
