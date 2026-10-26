# CronJob CLI Runner Pattern

How to move scheduled tasks from in-process `node-cron` to Kubernetes CronJobs.

## Why

With `node-cron`, every pod replica runs every cron job independently. At 4 replicas,
a job scheduled every 5 minutes fires 4 times — once per pod. This causes duplicate
notifications, double-processed queues, and race conditions.

Kubernetes CronJobs solve this: the scheduler creates exactly one Pod per run, and
`concurrencyPolicy: Forbid` prevents overlap if a run takes longer than the interval.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Same Docker image as the main backend          │
│                                                 │
│  Deployment (API server):                       │
│    CMD: node dist/server.js                     │
│                                                 │
│  CronJob (scheduled task):                      │
│    CMD: node dist/jobs/runner.js <job-name>     │
│         ↓                                       │
│    1. Connect to database                       │
│    2. Run the named job function                │
│    3. Disconnect + exit                         │
│                                                 │
│  Same env vars, same image, same secrets.       │
│  Only the entrypoint differs.                   │
└─────────────────────────────────────────────────┘
```

## Step 1: Create the Runner

```typescript
// src/jobs/runner.ts

import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

// Map job names to functions
const jobs: Record<string, () => Promise<void>> = {
  "broadcast-recovery": async () => {
    // Retry failed broadcast notifications
    const failed = await prisma.notification.findMany({
      where: { status: "FAILED", retryCount: { lt: 3 } },
    });
    for (const n of failed) {
      // ... retry logic
    }
    console.log(`Processed ${failed.length} failed broadcasts`);
  },

  "tat-scheduler": async () => {
    // Process TAT deadlines
    // ...
  },

  "session-cleanup": async () => {
    const result = await prisma.session.deleteMany({
      where: { expiresAt: { lt: new Date() } },
    });
    console.log(`Cleaned up ${result.count} expired sessions`);
  },

  // Add more jobs here...
};

async function main() {
  const jobName = process.argv[2];

  if (!jobName || !jobs[jobName]) {
    console.error(`Unknown job: ${jobName}`);
    console.error(`Available jobs: ${Object.keys(jobs).join(", ")}`);
    process.exit(1);
  }

  console.log(`[${new Date().toISOString()}] Starting job: ${jobName}`);

  try {
    await prisma.$connect();
    console.log("PostgreSQL connected via Prisma");

    await jobs[jobName]();

    console.log(`[${new Date().toISOString()}] Job completed: ${jobName}`);
  } catch (error) {
    console.error(`[${new Date().toISOString()}] Job failed: ${jobName}`, error);
    process.exit(1);
  } finally {
    await prisma.$disconnect();
  }
}

main();
```

## Step 2: Build Configuration

Add the runner to your TypeScript build. In `tsconfig.json`, ensure `src/jobs/` is
included. The compiled output lands at `dist/jobs/runner.js`.

Test locally:

```bash
npx tsx src/jobs/runner.ts session-cleanup
```

## Step 3: CronJob Manifest

```yaml
# cronjobs.yaml (in your devops repo)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backend-session-cleanup
  namespace: {{NAMESPACE}}
spec:
  schedule: "0 3 * * *"          # 03:00 UTC daily
  concurrencyPolicy: Forbid       # Skip if previous run still active
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 120   # Kill if running > 2 minutes
      backoffLimit: 1              # Retry once on failure
      template:
        spec:
          restartPolicy: Never
          imagePullSecrets:
            - name: ghcr-secret
          containers:
            - name: session-cleanup
              image: ghcr.io/{{GH_REPO_OWNER}}/{{BACKEND_IMAGE_NAME}}:latest
              command: ["node", "dist/jobs/runner.js", "session-cleanup"]
              env:
                - name: NODE_ENV
                  value: "production"
                - name: DATABASE_URL
                  valueFrom:
                    secretKeyRef:
                      name: backend-secrets
                      key: DATABASE_URL
              envFrom:
                - secretRef:
                    name: backend-secrets
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  cpu: 250m
                  memory: 256Mi
```

## Step 4: Remove node-cron from server.ts

Once the CronJob is verified on staging:

```typescript
// BEFORE — remove these lines from server.ts:
import cron from "node-cron";
cron.schedule("0 3 * * *", () => sessionCleanup());

// AFTER — nothing. The CronJob handles it.
```

## Adding a New CronJob

1. Add the job function to `src/jobs/runner.ts` in the `jobs` map
2. Test locally: `npx tsx src/jobs/runner.ts your-job-name`
3. Add a CronJob manifest to `cronjobs.yaml` in your devops repo
4. Update CI to replace the image tag in `cronjobs.yaml` (same `perl -pi` pattern)
5. Deploy to staging first, verify in pod logs
6. Remove the `node-cron` schedule from `server.ts`

## Key Details

- **Same image:** CronJobs use the exact same Docker image as the Deployment.
  The only difference is the entrypoint command.
- **Same secrets:** CronJobs mount the same `backend-secrets` via `envFrom`.
- **`concurrencyPolicy: Forbid`:** If a run is still active when the next schedule
  fires, the new run is skipped. Prevents pile-up.
- **`activeDeadlineSeconds`:** Hard kill if the job hangs. Set per-job based on
  expected runtime (120s for cleanup, 1800s for data migrations).
- **`startingDeadlineSeconds`:** For frequent jobs (every 5 min), set this to
  slightly less than the interval (e.g. 200s). If the scheduler can't start the
  job within this window (node was down), it skips rather than queueing.
- **Image tag updates:** CI must update the tag in `cronjobs.yaml` alongside
  `deployment.yaml` — they must always run the same image version.
