# Alternatives

For each technology choice: what we use, why, what the alternatives are, and when you'd pick differently.

## Kubernetes Distribution

| | K3s | K8s (kubeadm) | Managed (EKS/GKE/AKS) |
|---|---|---|---|
| **Control plane footprint** | ~512MB RAM, single binary | ~2GB RAM, multiple components | Zero (managed) |
| **Install** | One `curl` command | kubeadm init + join | Cloud console / Terraform |
| **Bundled ingress** | Traefik | None | ALB/NLB (cloud-specific) |
| **Bundled storage** | local-path-provisioner | None | EBS/PD CSI drivers |
| **Multi-node** | Supported but less tested | Designed for it | Designed for it |
| **Cert compatibility** | CKA/CKAD not applicable | CKA/CKAD applicable | Cloud-specific certs |
| **Monthly cost** | $0 (self-managed) | $0 (self-managed) | $72+ (EKS control plane) |

**Our choice:** K3s — single-node VPS with constrained resources. K3s gives you a full Kubernetes API with 75% less RAM overhead.

**Pick K3s when:** Single node, VPS/bare metal, resource-constrained, small team comfortable with self-management.

**Pick managed when:** Multi-node, team > 3 devs, compliance requirements (SOC2, HIPAA), budget allows $72+/month for control plane alone, or you want automated upgrades/patching.

**Pick kubeadm when:** Multi-node on bare metal, need full K8s feature set, have a dedicated ops team.

## Ingress Controller

| | Traefik | nginx-ingress | HAProxy Ingress |
|---|---|---|---|
| **Config style** | IngressRoute CRDs | Annotations on Ingress | ConfigMap + annotations |
| **Built-in Let's Encrypt** | Yes (ACME resolver) | No (needs cert-manager) | No (needs cert-manager) |
| **Middleware chains** | Native (rate limit, auth, redirect, headers) | Via annotations (less composable) | Via ConfigMap |
| **Dashboard** | Built-in (port 8080) | None | Stats page |
| **K3s integration** | Bundled, zero-config | Manual install | Manual install |
| **Performance at scale** | Good for small-medium | Better for large scale | Best raw throughput |
| **Community size** | Smaller | Largest | Moderate |

**Our choice:** Traefik — it's bundled with K3s, so it's already running. IngressRoute CRDs are more expressive than annotation-based config. Built-in ACME means no cert-manager dependency.

**Pick nginx-ingress when:** You need battle-tested performance at scale (>1000 rps), or your team already knows nginx config deeply.

**Pick Traefik when:** Using K3s (already there), small-medium scale, you want middleware chains and built-in TLS without cert-manager.

## GitOps Tool

| | ArgoCD | FluxCD | Manual (kubectl/helm) |
|---|---|---|---|
| **UI** | Yes (web dashboard) | No (CLI only) | No |
| **Application CRD** | Yes (one resource per app) | GitRepository + Kustomization | N/A |
| **Hooks** | PreSync, Sync, PostSync, SyncFail | Pre/post-deploy via Kustomize | N/A |
| **Drift detection** | Yes (selfHeal reverts manual changes) | Yes (reconciliation loop) | No |
| **Rollback** | One-click in UI or CLI | Git revert | Manual |
| **Multi-tenancy** | Projects + RBAC | Namespace scoping | N/A |
| **Resource usage** | ~256MB RAM (server + controller) | ~128MB RAM (lighter) | 0 |
| **Health checks** | Built-in (Healthy/Progressing/Degraded) | Basic | N/A |

**Our choice:** ArgoCD — the UI is valuable for a small team (see deploy status at a glance), and PreSync/PostSync hooks solve the database migration ordering problem elegantly:

```
PreSync Job (prisma migrate deploy) → Sync (new pods roll out) → PostSync Job (seed)
```

Without hooks, you either run migrations via `kubectl exec` after the deploy (new code serves old schema for an unbounded window) or build migration into the container startup (every replica runs it, race conditions).

**Pick ArgoCD when:** You want a UI, hook-based migration orchestration, or a team where not everyone is comfortable with CLI-only tools.

**Pick FluxCD when:** Lighter footprint, Kustomize/Helm-native workflows, better multi-tenancy (many teams sharing a cluster), or you don't need a UI.

**Avoid manual deploys when:** You have more than one person deploying, or you need an audit trail of what's running.

## Secret Management

| | Infisical | sealed-secrets | external-secrets-operator | HashiCorp Vault |
|---|---|---|---|---|
| **UI** | Yes (web) | No | No | Yes (web) |
| **Audit log** | Yes (who read/wrote what) | No | Depends on backend | Yes |
| **Self-hostable** | Yes (Helm) | Yes (controller) | Yes (controller) | Yes (complex) |
| **K8s integration** | InfisicalSecret CRD + operator | SealedSecret CRD | ExternalSecret CRD | Agent/injector sidecar |
| **Secrets in git** | No (CRD references project/env/path) | Yes (encrypted) | No (CRD references external store) | No |
| **Versioning** | Yes (rollback to any version) | No | Depends on backend | Yes |
| **Machine identity** | Universal auth (clientId/clientSecret) | N/A (cluster-scoped) | Per-provider auth | AppRole, K8s auth |
| **Resource usage** | ~512MB (backend + DB) | ~64MB (controller) | ~128MB (controller) | ~1GB+ (server + consul) |
| **Complexity** | Medium | Low | Medium | High |

**Our choice:** Infisical — self-hosted, gives a UI for non-technical team members to manage secrets, audit log for compliance, and the operator syncs secrets to K8s automatically.

**Pick sealed-secrets when:** You want the simplest solution, secrets-in-git is acceptable, and you don't need a UI or audit log.

**Pick external-secrets-operator when:** You already use AWS Secrets Manager / GCP Secret Manager / Azure Key Vault and want to pull from there.

**Pick Vault when:** Enterprise-grade requirements, complex access policies, dynamic secrets (database credentials rotated automatically). Overkill for small teams.

## Connection Pooling

| | PgBouncer | PgPool-II | Prisma built-in |
|---|---|---|---|
| **Pool mode** | Session / Transaction / Statement | Session | Connection limit only |
| **Overhead** | ~10MB RAM | ~50MB+ RAM | None (in-process) |
| **Features** | Pooling only | Pooling + load balancing + replication | Pooling only |
| **Transaction pooling** | Yes (release connection between transactions) | Limited | No |
| **Non-Prisma clients** | Yes (any PostgreSQL client) | Yes | No (Prisma only) |
| **Deployment** | Separate pod/container | Separate pod | Part of app process |
| **Configuration** | pgbouncer.ini (simple) | pgpool.conf (complex) | prisma schema (url param) |

**Our choice:** PgBouncer with transaction pooling — lightweight, proven, and works with any client. Critical when HPA scales the backend from 2 to 8 replicas, each with Prisma's default 5-connection pool:

```
Without PgBouncer: 8 pods × 5 connections = 40 direct connections (40% of max_connections=100)
With PgBouncer:    8 pods × 5 connections → PgBouncer → 12 server connections (12% of max)
```

**Pick PgBouncer when:** Any HPA-scaled app hitting PostgreSQL. Almost always the right choice.

**Pick PgPool-II when:** You also need read-replica load balancing and don't want a separate tool for it.

**Pick Prisma built-in when:** Single replica, no HPA, simplest possible setup.

## CI/CD Platform

| | GitHub Actions | GitLab CI | Jenkins | Tekton |
|---|---|---|---|---|
| **Integration** | GitHub-native | GitLab-native | Any SCM | Kubernetes-native |
| **Config** | YAML in `.github/workflows/` | `.gitlab-ci.yml` | Jenkinsfile (Groovy) | YAML CRDs |
| **Free tier** | 2000 min/month (public unlimited) | 400 min/month | Self-hosted (free, ops cost) | Self-hosted |
| **Container registry** | GHCR (included) | GitLab Registry (included) | None (needs external) | None |
| **Marketplace** | Large (Actions marketplace) | Smaller | Plugins (huge, often outdated) | None |
| **Self-hosted runners** | Supported | Supported | Default model | Default model |
| **Learning curve** | Low | Low | Medium-High | High |

**Our choice:** GitHub Actions — repos are on GitHub, GHCR is free for private images, and the GitOps push pattern (clone devops repo → update image tag → git push) works cleanly.

**Pick GitLab CI when:** Repos are on GitLab, or you want built-in registry + CI in one tool.

**Pick Jenkins when:** Complex pipelines with many conditional stages, or you need plugins for niche integrations.

**Adapting the GitOps push for GitLab CI:** The pattern is identical — `git clone`, `sed` the image tag, `git push`. Only the CI syntax and registry auth change. The ArgoCD side is unchanged.

## Database Hosting

| | Self-hosted (StatefulSet) | Managed (RDS/Cloud SQL) | Managed (Supabase/Neon) |
|---|---|---|---|
| **Monthly cost** | $0 (uses existing VPS) | $15+ (db.t3.micro) | Free tier, then $25+ |
| **Backups** | Manual (CronJob + S3) | Automated snapshots + PITR | Automated |
| **HA / Replicas** | Manual (operator needed) | One-click | Included |
| **Maintenance** | You (patches, upgrades, monitoring) | Automated | Automated |
| **Performance tuning** | Full access (postgresql.conf) | Limited parameters | Very limited |
| **Connection** | ClusterIP (in-cluster) | VPC peering / public endpoint | Public endpoint |
| **Data residency** | Your server | Cloud region | Cloud region |

**Our choice:** Self-hosted on K3s — the VPS is already paid for, and the team is comfortable with database operations.

**Pick managed when:**
- The data matters more than the infra cost
- You need automated PITR (point-in-time recovery) without building it yourself
- You need replicas for read scaling or HA
- Nobody on the team wants to be the DBA

**Pick self-hosted when:**
- Budget-constrained (VPS cost is fixed regardless)
- Single-node is acceptable (no replica needed yet)
- You want full control over configuration
- Data residency requirements match your VPS location

## Container Registry

| | GHCR | Docker Hub | AWS ECR | Self-hosted (Harbor) |
|---|---|---|---|---|
| **Free tier** | Unlimited public, 500MB private | 1 private repo | 500MB free tier | Free (self-hosted) |
| **Rate limits** | None for authenticated | 100 pulls/6hr (anonymous) | None | None |
| **GitHub integration** | Native (Actions, packages) | Separate auth | Separate auth | Separate auth |
| **Visibility control** | Per-package (public/private) | Per-repo | Per-repo | Per-project |
| **Scanning** | Dependabot (source, not images) | Paid tier | Built-in | Built-in (Trivy) |

**Our choice:** GHCR — free for private images, native GitHub Actions integration, no rate limits.

**Pick ECR when:** AWS-heavy infrastructure, using EKS, want native IAM integration.

**Pick Docker Hub when:** Public images, widest adoption, or you need Docker Scout scanning.

**Pick Harbor when:** Air-gapped environments, strict compliance, or you want image signing and vulnerability scanning in one tool.
