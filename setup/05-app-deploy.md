# 05 — First Application Deployment

Deploy your backend and frontend for the first time. After this, CI handles all future deploys automatically.

**Time:** ~20 minutes

---

## Step 1: Create GHCR image pull secret

Your container images are stored in GitHub Container Registry (private). Kubernetes needs credentials to pull them.

```bash
# Production namespace
kubectl -n {{NAMESPACE}} create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username={{GHCR_ORG}} \
  --docker-password='YOUR_GITHUB_PAT' \
  --docker-email='your@email.com'

# Staging namespace
kubectl -n {{STAGING_NAMESPACE}} create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username={{GHCR_ORG}} \
  --docker-password='YOUR_GITHUB_PAT' \
  --docker-email='your@email.com'
```

**Verify:**

```bash
kubectl -n {{NAMESPACE}} get secret ghcr-secret -o jsonpath='{.type}'
```

Expected: `kubernetes.io/dockerconfigjson`

## Step 2: Build and push backend image

On your local machine (or in CI — this is a one-time manual step):

```bash
cd your-backend-repo

# Login to GHCR
echo 'YOUR_GITHUB_PAT' | docker login ghcr.io -u {{GHCR_ORG}} --password-stdin

# Build
docker build -t ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-be:initial -f Dockerfile .

# Push
docker push ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-be:initial
```

> If building on Apple Silicon (M1/M2/M3) for an amd64 server:
> ```bash
> docker buildx build --platform linux/amd64 -t ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-be:initial --push .
> ```

## Step 3: Update the image tag in the manifest

Edit `templates/backend/deployment.yaml` — set the image to your just-pushed tag:

```yaml
image: ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-be:initial
```

## Step 4: Deploy the backend

If ArgoCD is managing this (recommended):

```bash
# Push the manifest to your devops repo
cd your-devops-repo
git add backend/
git commit -m "feat: initial backend deployment"
git push origin main
```

ArgoCD will auto-sync within ~3 minutes. Watch it:

```bash
kubectl -n argocd exec deploy/argocd-server -- \
  argocd app get {{PROJECT_NAME}}-backend --plaintext | head -20
```

If not using ArgoCD yet (manual apply):

```bash
kubectl apply -f templates/backend/deployment.yaml -n {{NAMESPACE}}
```

**Verify pods are running:**

```bash
kubectl -n {{NAMESPACE}} get pods -l app={{PROJECT_NAME}}-backend
```

Expected:

```
NAME                                  READY   STATUS    RESTARTS   AGE
{{PROJECT_NAME}}-backend-xxx-yyy      1/1     Running   0          30s
```

If `STATUS` is not `Running`:

```bash
# Check events
kubectl -n {{NAMESPACE}} describe pod -l app={{PROJECT_NAME}}-backend

# Check logs
kubectl -n {{NAMESPACE}} logs -l app={{PROJECT_NAME}}-backend --tail=50
```

## Step 5: Verify backend health

```bash
kubectl -n {{NAMESPACE}} exec -it deploy/{{PROJECT_NAME}}-backend -- wget -qO- http://localhost:5000/api/health
```

Or port-forward and test from local:

```bash
kubectl -n {{NAMESPACE}} port-forward svc/{{PROJECT_NAME}}-backend 5000:5000
curl http://localhost:5000/api/health
```

Expected: `{"status":"ok"}` or your app's health response.

## Step 6: Build and push frontend image

```bash
cd your-frontend-repo

docker build \
  --build-arg VITE_API_BASE_URL=/api \
  -t ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-fe:initial \
  -f Dockerfile .

docker push ghcr.io/{{GHCR_ORG}}/{{PROJECT_NAME}}-fe:initial
```

## Step 7: Deploy the frontend

Same process — update the image tag in `templates/frontend/deployment.yaml`, push to devops repo (or `kubectl apply`).

**Verify:**

```bash
kubectl -n {{NAMESPACE}} get pods -l app={{PROJECT_NAME}}-frontend
```

Expected: `1/1 Running`.

## Step 8: Apply the Ingress

```bash
kubectl apply -f templates/ingress.yaml
```

This creates Traefik IngressRoutes:
- `https://{{DOMAIN}}/api/*` → backend service
- `https://{{DOMAIN}}/*` → frontend service (SPA)

**Verify from your local machine:**

```bash
# Frontend (should return HTML)
curl -s -o /dev/null -w "%{http_code}" https://{{DOMAIN}}/

# Backend health
curl https://{{DOMAIN}}/api/health
```

Expected: `200` for both.

---

## Troubleshooting

### ImagePullBackOff

```bash
kubectl -n {{NAMESPACE}} describe pod -l app={{PROJECT_NAME}}-backend | grep -A5 "Events"
```

Causes:
- **Wrong image name:** Check the full image path in the Deployment
- **GHCR auth failed:** Recreate the `ghcr-secret` with the correct PAT
- **Image doesn't exist:** Verify on GitHub Packages page
- **Image is private but secret is missing:** Check `imagePullSecrets` in the Deployment spec

### CrashLoopBackOff

```bash
kubectl -n {{NAMESPACE}} logs -l app={{PROJECT_NAME}}-backend --previous
```

Causes:
- **Missing env vars:** Check `backend-secrets` has all required keys
- **Database not reachable:** Test connectivity from the pod
- **Port conflict:** Ensure the container port matches what the app listens on

### CrashLoopBackOff, and three ReplicaSets' worth of pods

A rolling update does not retire the previous revision until the new pods go **Ready**. If they
never do, each `kubectl apply` or `rollout restart` stacks another ReplicaSet on top, and you end
up reading logs from a pod that is two revisions out of date while chasing a bug you already
fixed.

```bash
kubectl -n {{NAMESPACE}} get rs -l app={{PROJECT_NAME}}-backend
```

More than one with a non-zero desired count means you are looking at a pile-up. Clear every
revision at once — `rollout restart` would just add a fourth:

```bash
kubectl -n {{NAMESPACE}} scale deploy/{{PROJECT_NAME}}-backend --replicas=0
kubectl -n {{NAMESPACE}} wait --for=delete pod -l app={{PROJECT_NAME}}-backend --timeout=90s
kubectl -n {{NAMESPACE}} scale deploy/{{PROJECT_NAME}}-backend --replicas=1
```

### The app refuses to start against an empty database

Some applications check for a bootstrap row — an organization, a tenant, a default admin — and
exit rather than run half-configured:

```
No organization found - run `npm run seed` before starting the API
```

This is correct behaviour and no amount of restarting fixes it. Seed it once, as a Job, from
**outside** the directory ArgoCD watches — a plain Job inside it gets re-created forever by
`selfHeal`. See the adoption notes in [docs/05-argocd.md](../docs/05-argocd.md).

Read the seed before you run it against a real database. The ones worth running are idempotent
(`findOne` then skip, or `findOneAndUpdate`), and the ones worth being careful about are not.

### A config value that defaults to something that works in development

Check every setting the app reads for a default that is only correct on a laptop. The classic:

```js
SMTP_HOST: z.string().default('localhost'),
SMTP_PORT: z.coerce.number().default(1025),
```

That is a dev mailbox. In the cluster there is nothing on `localhost:1025`, so the schema
validates, the app starts healthy, the health check passes — and **every email fails at send
time**, which is the first time anyone finds out. Invites and password resets are usually where
it bites, and invite tokens are normally stored hashed, so a failed invite email cannot be
recovered from the database either.

Grep the env schema for `.default(` before going live and confirm every one of them is correct
in production, not merely present:

```bash
kubectl -n {{NAMESPACE}} exec deploy/{{PROJECT_NAME}}-backend -- \
  node -e 'const n=require("net").connect({host:process.env.SMTP_HOST,port:+process.env.SMTP_PORT});
           n.on("connect",()=>{console.log("reachable");n.end()});
           n.on("error",e=>console.log("UNREACHABLE:",e.code))'
```

### Service not reachable

```bash
# Check service exists and has endpoints
kubectl -n {{NAMESPACE}} get svc {{PROJECT_NAME}}-backend
kubectl -n {{NAMESPACE}} get endpoints {{PROJECT_NAME}}-backend
```

If endpoints is `<none>`, the Service selector doesn't match the pod labels.

### 502 Bad Gateway from Traefik

The IngressRoute is routing to the Service, but the backend is returning errors:

```bash
# Check Traefik logs
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=20
```

Common causes:
- Backend pod is not ready yet (readiness probe failing)
- Wrong port in the IngressRoute or Service

---

## What you have now

- Backend running with database connectivity
- Frontend serving the SPA
- Traefik routing traffic to both
- GHCR pulling private images

**Next:** [06-cicd-setup.md](./06-cicd-setup.md) — automate deployments with GitHub Actions.
