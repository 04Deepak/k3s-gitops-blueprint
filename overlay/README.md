# Prisma / Express / Vite React Overlay

Additional patterns specific to projects built with:

- **Backend:** Node.js + Express + Prisma ORM + TypeScript
- **Frontend:** Vite + React + TypeScript

These extend the generic K3s templates with app-framework-specific Dockerfiles,
nginx configuration, and patterns like the CronJob CLI runner.

## Files

| File | Purpose |
|------|---------|
| `backend-prisma.Dockerfile` | Multi-stage Dockerfile with Prisma generate, migration support, health checks |
| `frontend-vite.Dockerfile` | Multi-stage Dockerfile with Vite build + nginx runtime |
| `nginx.conf` | Fully commented nginx config: SPA routing, API proxy, security headers, SSE support |
| `cronjob-runner-pattern.md` | How to implement a CLI runner for K8s CronJobs (replaces node-cron) |
| `gitops-push.md` | The GitOps image-tag push pattern with race protection |

## Usage

Copy the Dockerfiles into your app repos. The nginx.conf goes alongside the frontend Dockerfile.
Read the pattern docs before implementing CronJobs or CI deploy steps.
