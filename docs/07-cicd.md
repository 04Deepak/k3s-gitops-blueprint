# CI/CD Pipeline

## Pipeline Overview

```
Developer pushes code
  │
  ├── Push to dev  → CI tests → build image → push GHCR → update staging manifest → ArgoCD syncs staging
  └── Push to main → CI tests → build image → push GHCR → update prod manifest → ArgoCD syncs prod
```

Every push triggers tests. Pushes to `dev` and `main` additionally build Docker images, push them to GHCR, and update the devops repo to trigger ArgoCD deployments.

## GitHub Actions Workflow Structure

### Backend CI (`ci.yml`)

```yaml
name: CI/CD Pipeline

on:
  push:
    branches: [dev, main]
  pull_request:
    branches: [dev, main]

concurrency:
  group: deploy-${{ github.ref == 'refs/heads/main' && 'prod' || 'staging' }}-backend
  cancel-in-progress: false  # Never cancel a running deploy

jobs:
  test:
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npm ci
      - run: npx prisma generate
      - run: npx tsc -b --noEmit
      - run: npm run lint
      - run: npm test
      - run: npm run build

  integration-db:
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test_db
        ports:
          - 55432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: npm ci
      - run: npx prisma generate
      - run: npx prisma migrate deploy
        env:
          DATABASE_URL: postgresql://test:test@localhost:55432/test_db
      - run: npm run test:db
        env:
          DATABASE_URL: postgresql://test:test@localhost:55432/test_db

  build-push:
    needs: [test, integration-db]
    if: github.event_name == 'push'
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3    # For cross-platform builds
      - uses: docker/setup-buildx-action@v3
      - name: Login to GHCR
        run: |
          mkdir -p /tmp/.docker
          echo '{"auths":{"ghcr.io":{"auth":"'$(echo -n "${{ github.actor }}:${{ secrets.GITOPS_PAT }}" | base64)'"}}}' > /tmp/.docker/config.json
        env:
          DOCKER_CONFIG: /tmp/.docker
      - name: Build and push
        run: |
          export DOCKER_CONFIG=/tmp/.docker
          docker buildx build \
            --platform linux/amd64 \
            --push \
            -t ghcr.io/${{ github.repository_owner }}/app-be:${{ github.sha }} \
            -t ghcr.io/${{ github.repository_owner }}/app-be:latest \
            .

  deploy:
    needs: build-push
    if: github.ref == 'refs/heads/main'
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    environment: production
    steps:
      - name: Update devops manifest
        run: |
          git clone https://x-access-token:${{ secrets.GITOPS_PAT }}@github.com/org/project-devops.git
          cd project-devops
          SHORT_SHA="${{ github.sha }}"
          SHORT_SHA="${SHORT_SHA:0:7}"
          # Update image tag in deployment and cronjobs
          perl -pi -e "s|image: ghcr.io/.*/app-be:.*|image: ghcr.io/${{ github.repository_owner }}/app-be:${SHORT_SHA}|g" \
            backend/deployment.yaml backend/cronjobs.yaml
          git config user.name "CI Bot"
          git config user.email "ci@example.com"
          git add -A
          git commit -m "ci: update backend image to ${SHORT_SHA}" || exit 0
          # Race-protected push
          for attempt in 1 2 3; do
            git pull --rebase origin main
            if git push origin main; then
              echo "Push succeeded on attempt $attempt"
              break
            fi
            if [ "$attempt" -eq 3 ]; then
              echo "ERROR: All 3 push attempts failed"
              exit 1
            fi
            sleep $((attempt * 2))
          done

  deploy-staging:
    needs: build-push
    if: github.ref == 'refs/heads/dev'
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    environment: staging
    steps:
      # Same pattern as deploy, but targets staging/backend/deployment.yaml
```

### Frontend CI

Same structure with these differences:
- No `integration-db` job (frontend has no database tests)
- Build uses `--build-arg VITE_API_BASE_URL=/api` to bake the API path
- Image: `ghcr.io/org/app-fe:<sha>`
- Updates `frontend/deployment.yaml` instead of `backend/deployment.yaml`
- May skip explicit ArgoCD sync (relies on auto-sync)

## Docker Build with GHCR

### Private Registry Authentication

GHCR requires authentication for both push (CI) and pull (K8s pods).

**CI push** uses a Personal Access Token (PAT) with `write:packages` scope, stored as the `GITOPS_PAT` repository secret.

**K8s pull** uses an `imagePullSecrets` reference in every Deployment:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ghcr-secret
```

Create the pull secret in each namespace:

```bash
kubectl create secret docker-registry ghcr-secret \
  --namespace acme \
  --docker-server=ghcr.io \
  --docker-username=github-user \
  --docker-password=ghp_xxxx
```

### GHCR Authentication Workaround for Self-Hosted Runners

macOS runners with Docker Desktop use the system keychain for Docker auth, which interferes with CI. The workaround creates an isolated Docker config:

```bash
mkdir -p /tmp/.docker
echo '{"auths":{"ghcr.io":{"auth":"'$(echo -n "user:token" | base64)'"}}}' > /tmp/.docker/config.json
export DOCKER_CONFIG=/tmp/.docker
```

## Image Tagging Strategy

| Tag | Purpose | Example |
|-----|---------|---------|
| `<short-sha>` | Immutable reference to a specific commit | `ghcr.io/org/app-be:a4d82d3` |
| `latest` | Convenience tag, always points to newest | `ghcr.io/org/app-be:latest` |

The devops manifests always reference the short SHA, never `latest`. This ensures:
- Deterministic rollbacks (revert the manifest to a previous SHA)
- ArgoCD detects changes (a new SHA triggers sync; `latest` doesn't)
- Clear audit trail (which commit is running in prod)

**Hook Jobs use `latest`** — the PreSync migrate job references `latest` because it needs the newest image (the one about to be deployed), and ArgoCD syncs all resources in the path together.

## GitOps Push Pattern

The deploy step clones the devops repo, updates image tags via `perl -pi`, commits, and pushes. This git-push-to-devops is the bridge between CI and GitOps.

### Race Protection

When backend and frontend CI run simultaneously (both triggered by a push to `main`), both try to push to the devops repo. The second push fails because the first push has already advanced `HEAD`.

```
Backend CI:  clone → edit backend/deployment.yaml → commit → push ✓
Frontend CI: clone → edit frontend/deployment.yaml → commit → push ✗ (non-fast-forward)
```

**Solution:** `git pull --rebase` before each push attempt, with 3 retries:

```bash
for attempt in 1 2 3; do
  git pull --rebase origin main
  if git push origin main; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "ERROR: All 3 push attempts failed"
    exit 1
  fi
  sleep $((attempt * 2))
done
```

The rebase replays the frontend's commit on top of the backend's push, resolving the conflict automatically (they edit different files).

**Critical:** The `exit 1` on attempt 3 is essential. Without it, the loop exits with code 0 (success) even though the push failed — the deploy reports success but the image tag was never updated.

## Concurrency Groups

```yaml
concurrency:
  group: deploy-prod-backend
  cancel-in-progress: false
```

- **Group name** includes environment and component — backend and frontend deploy independently
- **cancel-in-progress: false** — Never cancel a running deploy. A cancelled deploy can leave the cluster in a partially-synced state

## Runner Flexibility

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
```

The `CI_RUNNER` repository variable controls which runner handles CI:
- **Not set (default):** Uses GitHub-hosted `ubuntu-latest`
- **Set to `self-hosted`:** Uses a self-hosted runner (Mac Mini, Linux box)

This is useful when:
- GitHub Actions minutes are exhausted
- You need access to internal resources during CI
- Build times are unacceptable on GitHub-hosted runners

**Self-hosted runner caveat:** Docker services (like the Postgres integration test) require Docker daemon on the runner. macOS runners need Docker Desktop installed.

## Deploy Step: ArgoCD Sync

After pushing the updated manifest, CI optionally triggers an explicit ArgoCD sync:

```bash
ssh -o StrictHostKeyChecking=no server \
  "kubectl exec -n argocd deploy/argocd-server -- \
    argocd login localhost:8080 --plaintext --username admin --password \$ARGOCD_PASSWORD && \
  kubectl exec -n argocd deploy/argocd-server -- \
    argocd app sync app-backend --timeout 300"
```

**Alternative:** Skip the explicit sync and rely on ArgoCD's auto-sync (polls every 3 minutes). This is simpler and removes the SSH dependency from CI. The trade-off is a 0-3 minute delay before deployment starts.

## Staging vs Production Triggers

| Branch | Target | Manifests Updated | ArgoCD Apps |
|--------|--------|-------------------|-------------|
| `dev` | Staging | `staging/backend/deployment.yaml` | `acme-staging-backend` |
| `main` | Production | `backend/deployment.yaml` | `acme-platform-backend` |

**Workflow:**
1. Develop on feature branches → PR to `dev`
2. Merge to `dev` → auto-deploy to staging
3. Verify on staging
4. PR from `dev` → `main`
5. Merge to `main` → auto-deploy to production

## Adapting for GitLab CI

The pattern translates directly to GitLab CI:

```yaml
# .gitlab-ci.yml
stages:
  - test
  - build
  - deploy

test:
  stage: test
  image: node:22
  script:
    - npm ci
    - npm run typecheck
    - npm run lint
    - npm test

build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  only:
    - dev
    - main

deploy:
  stage: deploy
  script:
    - git clone https://token:$GITOPS_TOKEN@gitlab.com/org/devops.git
    - cd devops
    - sed -i "s|image:.*|image: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA|" backend/deployment.yaml
    - git add -A && git commit -m "ci: update image to $CI_COMMIT_SHORT_SHA"
    - git push
  only:
    - main
```

Key differences:
- GitLab uses `$CI_REGISTRY` instead of GHCR
- `stages` instead of `jobs` with `needs`
- `only` instead of `if: github.ref == ...`
- GitLab CI/CD Variables instead of GitHub Secrets
- Docker-in-Docker (`dind`) service for building images
