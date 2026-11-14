# CLAUDE.md -- GoApps Infrastructure Repository

> Single source of truth for Claude Code working on `goapps-infra`.
> Last updated 2026-10-12: backup destinations, MinIO image source, ArgoCD infra sync policy, disk-pressure incident (see §10, §9, §17).
> Read this before making any changes.

---

## Agent Skills (read first — use them without being asked)

Claude Code skills installed at user level (`~/.claude/skills/`). Invoke the matching skill automatically when the task fits; the user should not have to name it. **Missing skill → recommend installing it.** Other devs may not have these skills yet. At the start of a task, if a skill listed below is not in the session's skill list, do not silently skip it:
1. Tell the user which skill is missing and why it helps this task (one line).
2. Give the exact install command from "Setting up a new machine" below (public skills: `npx skills add <owner/repo@skill> -g -y`; they load on the next session start). If the skill is not in that list, run `find-skills` / `npx skills find <topic>` and recommend only well-known sources.
3. Offer to run the install for them; run it only if they agree. Internal skills (`review-pr`, `triage-issue`, `feature-flow`, `backend`, `frontend`, `proto`, `infra`) can't be installed via npx — ask the user to copy them from a teammate's `~/.claude/skills/`.
4. Meanwhile, continue the task using this CLAUDE.md as the baseline.

| When | Skill |
|------|-------|
| Review a PR (any goapps repo, incl. paired cross-repo PRs) | `review-pr` — draft first in `../docs/pr-review-drafts/`, post only after user approval |
| Triage an issue / fill labels, assignee, project fields (Status, Prio, Size, Estimate, Iteration, Start, Due) | `triage-issue` — draft first, apply only after approval |
| Non-trivial feature / bug / refactor end-to-end | `feature-flow` (resume-check first) |
| Can't find a skill for a task | `find-skills` |
| Security-sensitive change | `security-review`, `differential-review`; dependency changes: `supply-chain-risk-auditor` |
| CI workflows (`.github/workflows/*`) | `github-actions-hardening`, `gha-security-review` |
| Receiving review feedback / before merging own work | `receiving-code-review`, `requesting-code-review` |
| K8s manifests / overlays | `kustomize`, `kubernetes-specialist` + team skill `infra` |
| ArgoCD / GitOps | `argocd-gitops`, `gitops-workflow` |
| Helm charts | `helm-chart-scaffolding` |
| Security hardening (RBAC, PSS, NetworkPolicy, prod overlays) | `kubernetes-security-audit` |
| Prometheus metrics / labels | `prometheus-label-strategy` |
| Dockerfile | `multi-stage-dockerfile` |

Setting up a new machine (public skills; `review-pr`, `triage-issue`, `feature-flow` and the team skills `backend`/`frontend`/`proto`/`infra` are internal, so copy them from a teammate's `~/.claude/skills/`):
```bash
npx skills add samber/cc-skills-golang vercel-labs/skills@find-skills obra/superpowers@receiving-code-review obra/superpowers@requesting-code-review getsentry/skills@security-review getsentry/skills@gha-security-review trailofbits/skills@differential-review trailofbits/skills@supply-chain-risk-auditor github/awesome-copilot@github-actions-hardening github/awesome-copilot@multi-stage-dockerfile -g -y
npx skills add jeffallan/claude-skills@kubernetes-specialist bagelhole/devops-security-agent-skills@kustomize bagelhole/devops-security-agent-skills@argocd-gitops wshobson/agents@gitops-workflow wshobson/agents@helm-chart-scaffolding securityskills/skills@kubernetes-security-audit grafana/skills@prometheus-label-strategy -g -y
```

Precedence: this CLAUDE.md > external skill. External skills fill gaps and flag industry best-practice issues the repo rules don't cover yet; when they conflict with a repo rule, follow the repo rule and mention the conflict to the user.

---

## Table of Contents

1. [Quick Overview](#1-quick-overview)
2. [Key Commands](#2-key-commands)
3. [Directory Structure](#3-directory-structure)
4. [Environments](#4-environments)
5. [Database Architecture](#5-database-architecture)
6. [Monitoring Stack](#6-monitoring-stack)
7. [Observability](#7-observability)
8. [Deployment Pattern](#8-deployment-pattern)
9. [ArgoCD Configuration](#9-argocd-configuration)
10. [Backup Strategy](#10-backup-strategy)
11. [CI/CD Pipelines](#11-cicd-pipelines)
12. [Secrets Management](#12-secrets-management)
13. [Linting and Validation](#13-linting-and-validation)
14. [Naming Conventions](#14-naming-conventions)
15. [Adding a New Service](#15-adding-a-new-service)
16. [Emergency Procedures](#16-emergency-procedures)
17. [Operational Lessons Learned](#17-operational-lessons-learned)

---

## 1. Quick Overview

This repository manages the Kubernetes infrastructure for the GoApps platform. It runs on **K3s** (lightweight Kubernetes) and uses **Kustomize** for manifest templating, **ArgoCD** for GitOps-based deployment, and a full monitoring stack (Prometheus, Grafana, Loki, Jaeger).

**What this repo controls:**
- Kubernetes namespaces and base infrastructure (databases, caches, message queues)
- Service deployments for finance-service, iam-service, and frontend
- Environment overlays for staging and production
- Monitoring, alerting, logging, and tracing
- Backup CronJobs for PostgreSQL and MinIO
- ArgoCD application definitions for GitOps sync
- Ingress and TLS configuration (NGINX + wildcard cert)

**What this repo does NOT do:**
- Application code (that lives in goapps-backend and goapps-frontend)
- Database migrations (run from goapps-backend via `make migrate-up`)
- Proto definitions (goapps-shared-proto)

---

## 2. Key Commands

### Makefile Targets

```bash
# Bootstrap and Installation
make bootstrap              # Initial K3s cluster setup from scratch
make install-monitoring     # Install Prometheus/Grafana/Loki stack
make install-argocd         # Install ArgoCD for GitOps

# Manual Apply (use ArgoCD in production, these are for emergency/initial setup)
make apply-base             # Apply namespaces + database + backup base configs
make apply-staging          # Apply base + staging overlays
make apply-production       # Apply base + production overlays

# Service Deployments (manual, prefer ArgoCD)
make deploy-finance-staging
make deploy-finance-production
make deploy-iam-staging
make deploy-iam-production

# Status and Monitoring
make status                 # Show nodes, pods (all namespaces), HPA, ArgoCD apps
make logs-postgres          # Tail PostgreSQL logs
make logs-argocd            # Tail ArgoCD server logs

# Port Forwarding
make port-forward-grafana   # Grafana UI on localhost:3000
make port-forward-argocd    # ArgoCD UI on localhost:8080

# Backup
make backup-now             # Trigger manual PostgreSQL backup CronJob

# Validation
make lint                   # Dry-run validate all base kustomizations

# Danger Zone
make reset                  # Uninstall K3s entirely (DESTRUCTIVE, requires confirmation)
```

### Local K3s cluster

Cluster k3s lokal mirip staging (Colima profile `k8s`, context `colima-k8s`, ns `goapps-local`). Target ada di `local.mk`:

```bash
make local-help     # daftar target local-*
```

Runbook lengkap: [docs/LOCAL_K3S_GUIDE.md](docs/LOCAL_K3S_GUIDE.md).

### Kustomize Commands

```bash
# Validate a kustomization builds without errors
kustomize build base/database/
kustomize build services/finance-service/overlays/staging/
kustomize build overlays/staging/

# Apply a kustomization directly
kubectl apply -k services/finance-service/overlays/staging/

# Preview what would be applied
kustomize build services/frontend/overlays/production/ | kubectl diff -f -
```

### kubectl Quick Reference

```bash
# Check cluster state
kubectl get pods -A                          # All pods across namespaces
kubectl get pods -n goapps-staging           # Staging app pods
kubectl get pods -n database                 # Database pods
kubectl get hpa -A                           # All HorizontalPodAutoscalers
kubectl get pvc -A                           # All PersistentVolumeClaims
kubectl get cronjobs -n database             # Backup CronJobs

# Debug a pod
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous # Previous container (after crash)
kubectl top pod <pod> -n <namespace>         # Resource usage

# Database access
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity"

# Database access per-environment (single shared postgres-0, not per-service):
# `goapps` and `ppc_db` are two DATABASES inside the SAME postgres instance --
# not two servers. One tunnel per environment reaches both; only `-d` changes.
# | Env        | Pod          | User      | Database | IAM tables schema |
# | Local      | -            | iam/finance | iam_db/finance_db | public |
# | Staging    | postgres-0   | stgapps   | goapps / ppc_db | public |
# | Production | postgres-0   | (check secret) | goapps / ppc_db | public |
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps -c "SELECT * FROM public.mst_user LIMIT 5;"
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps -c "\dn"   # list schemas
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d ppc_db -c "\dt"   # PPC tables
kubectl exec -it deploy/iam-service -n goapps-staging -- /app/migrate -path /app/migrations -database "$DATABASE_URL" up

# Rollback
kubectl rollout undo deployment/<name> -n <namespace>
kubectl rollout history deployment/<name> -n <namespace>
```

### ArgoCD Commands

ArgoCD CLI requires port-forwarding first (no direct CLI access in production):

```bash
# Port forward first
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Then use argocd CLI
argocd app list
argocd app sync finance-service-staging
argocd app sync finance-service-production
argocd app get finance-service-staging
argocd app rollback <app-name>
```

### Bootstrap Scripts

```bash
./scripts/bootstrap.sh              # Full K3s setup from scratch
./scripts/install-nginx-ingress.sh  # NGINX Ingress Controller
./scripts/install-monitoring.sh     # Prometheus + Grafana + Loki
./scripts/install-argocd.sh         # ArgoCD + Image Updater
./scripts/install-image-updater.sh  # ArgoCD Image Updater standalone
./scripts/install-runner.sh         # GitHub Actions self-hosted runner
./scripts/finance-setup.sh          # Finance service initial setup
./scripts/iam-setup.sh              # IAM service initial setup
./scripts/ppc-setup.sh              # PPC service initial setup (see below)
./scripts/validate-manifests.sh     # Validate all manifests
./scripts/fix-staging.sh            # Fix staging environment issues
./scripts/fix-production.sh         # Fix production environment issues
./scripts/reset-k3s.sh              # Uninstall K3s (DESTRUCTIVE)
```

#### PPC setup (`ppc-setup.sh`)

PPC owns a dedicated `ppc_db` database, so it needs an extra `createdb` step the other services do not:

```bash
./scripts/ppc-setup.sh <namespace> [createdb|migrate|seed|all]

./scripts/ppc-setup.sh goapps-staging createdb   # create ppc_db (idempotent; NO deployment needed)
./scripts/ppc-setup.sh goapps-staging migrate    # needs a running ppc-service (image tag read from it)
./scripts/ppc-setup.sh goapps-staging seed       # staging/dev only
./scripts/ppc-setup.sh goapps-staging all        # createdb + migrate + seed
```

**Production: `createdb` + `migrate` only — never `seed`.** Full procedure in `docs/runbooks/ppc-service-deployment.md`.

Job `component=` labels are `createdb`, `migration`, `seeder` (not `migrate`/`seed`); `ppc-setup.sh` passes them explicitly. `iam-setup.sh` derives them from the job name and therefore matches nothing — masked by `|| true`, so it silently waits out its 60s timeout. Known, unfixed.

---

## 3. Directory Structure

```
goapps-infra/
├── CLAUDE.md                          # This file
├── RULES.md                           # Development rules and conventions
├── Makefile                           # Common operations
├── .yamllint.yml                      # YAML lint configuration
│
├── base/                              # Base Kubernetes manifests (env-agnostic)
│   ├── namespaces/                    # Namespace definitions
│   │   ├── kustomization.yaml
│   │   └── namespaces.yaml            # database, monitoring, minio, goapps-staging, goapps-production
│   ├── database/
│   │   ├── kustomization.yaml         # Aggregates all database components
│   │   ├── postgres/                  # PostgreSQL 18 StatefulSet
│   │   │   ├── statefulset.yaml       # 20Gi PVC, custom postgresql.conf
│   │   │   ├── service.yaml
│   │   │   ├── configmap.yaml         # Init schemas, postgresql.conf
│   │   │   ├── vpa.yaml              # VerticalPodAutoscaler
│   │   │   └── kustomization.yaml
│   │   ├── pgbouncer/                 # PgBouncer connection pooler
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── configmap.yaml         # Pool config (transaction mode, 100 pool)
│   │   │   ├── hpa.yaml
│   │   │   ├── vpa.yaml
│   │   │   └── kustomization.yaml
│   │   ├── redis/                     # Redis 7 (emptyDir, non-persistent)
│   │   │   ├── deployment.yaml
│   │   │   └── kustomization.yaml
│   │   ├── rabbitmq/                  # RabbitMQ 3 (5Gi PVC, management UI)
│   │   │   ├── deployment.yaml
│   │   │   └── kustomization.yaml
│   │   ├── exporter/                  # PostgreSQL Prometheus exporter
│   │   │   ├── deployment.yaml
│   │   │   ├── queries.yaml           # Custom metric queries
│   │   │   └── kustomization.yaml
│   │   └── oracle/                    # External Oracle DB references
│   │       ├── external-services.yaml
│   │       └── kustomization.yaml
│   ├── backup/
│   │   ├── kustomization.yaml
│   │   ├── cronjobs/                  # Backup CronJobs
│   │   │   ├── postgres-backup.yaml   # PostgreSQL 3x/day -> backup disk only
│   │   │   ├── minio-backup.yaml      # MinIO app buckets daily -> backup disk
│   │   │   └── kustomization.yaml
│   │   ├── minio/                     # MinIO S3 storage (50Gi, TLS, image: ghcr.io/coollabsio/minio -- see §10)
│   │   │   ├── deployment.yaml
│   │   │   └── kustomization.yaml
│   │   └── scripts/                   # Backup scripts (currently empty)
│   ├── monitoring/
│   │   ├── helm-values/
│   │   │   ├── prometheus-stack.yaml  # kube-prometheus-stack Helm values
│   │   │   └── loki-stack.yaml        # Loki + Promtail Helm values
│   │   ├── dashboards/                # Grafana dashboard JSON files
│   │   │   ├── grafana-dashboard-go-apps.json
│   │   │   ├── grafana-dashboard-go-apps-configmap.yaml
│   │   │   ├── grafana-dashboard-postgres.json
│   │   │   ├── grafana-dashboard-postgres-configmap.yaml
│   │   │   └── grafana-dashboard-loki.json
│   │   └── alert-rules/               # Grafana/Prometheus alert rules
│   │       ├── grafana-alert-rules.yaml
│   │       ├── grafana-alertrules-configmap.yaml
│   │       ├── complete-alerts.yaml
│   │       ├── postgres-alerts.yaml
│   │       └── kustomization.yaml
│   ├── observability/
│   │   └── jaeger/                    # Jaeger all-in-one (OTLP, 10K traces in-memory)
│   │       ├── deployment.yaml
│   │       └── kustomization.yaml
│   ├── ingress/                       # NGINX Ingress + TLS
│   │   ├── tls-config.yaml            # Wildcard cert references
│   │   └── kustomization.yaml
│   ├── argocd/                        # ArgoCD NodePort service
│   │   ├── nodeport-service.yaml
│   │   └── kustomization.yaml
│   ├── argocd-image-updater/          # Auto image tag updates
│   │   └── kustomization.yaml
│   ├── kubernetes-dashboard/          # K8s Dashboard admin access
│   │   ├── admin-user.yaml
│   │   └── kustomization.yaml
│   └── secrets/                       # Secret TEMPLATES only (never real values)
│       ├── secrets-template.yaml
│       └── kustomization.yaml
│
├── overlays/                          # Environment-specific overrides for shared infra
│   ├── staging/
│   │   ├── ingress.yaml               # staging-goapps.mutugading.com
│   │   ├── backup-patch.yaml         # DEAD -- referenced by no kustomization
│   │   ├── backup/
│   │   │   └── kustomization.yaml
│   │   └── minio/
│   │       ├── kustomization.yaml
│   │       └── minio-patch.yaml
│   └── production/
│       ├── ingress.yaml               # goapps.mutugading.com + Basic Auth on Prometheus
│       ├── backup-patch.yaml         # DEAD -- referenced by no kustomization
│       ├── backup/
│       │   └── kustomization.yaml
│       └── minio/
│           ├── kustomization.yaml
│           └── minio-patch.yaml
│
├── services/                          # Application service deployments
│   ├── finance-service/
│   │   ├── base/
│   │   │   ├── deployment.yaml        # gRPC :50051, HTTP :8080, Metrics :8090
│   │   │   ├── service.yaml
│   │   │   ├── hpa.yaml               # min 1 (prod patches to 2), max 3, 70% CPU
│   │   │   ├── ingress.yaml
│   │   │   ├── migrate-job.yaml       # DB migration Job
│   │   │   ├── seed-job.yaml          # Data seeder Job
│   │   │   ├── servicemonitor.yaml    # Prometheus ServiceMonitor
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── staging/
│   │       │   ├── kustomization.yaml
│   │       │   └── patches/
│   │       │       ├── replicas.yaml
│   │       │       ├── resources.yaml
│   │       │       ├── env-cors.yaml
│   │       │       └── ingress-host.yaml
│   │       └── production/
│   │           ├── kustomization.yaml
│   │           └── patches/           # (same structure, higher resources)
│   ├── iam-service/
│   │   ├── base/
│   │   │   ├── deployment.yaml        # gRPC :50052, HTTP :8081, Metrics :8091
│   │   │   ├── service.yaml
│   │   │   ├── hpa.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── migrate-job.yaml
│   │   │   ├── seed-job.yaml          # Seeds admin user + menus + permissions
│   │   │   ├── servicemonitor.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── staging/
│   │       │   ├── kustomization.yaml
│   │       │   └── patches/
│   │       │       ├── replicas.yaml
│   │       │       ├── resources.yaml
│   │       │       ├── env-cors.yaml
│   │       │       ├── env-storage.yaml  # MinIO/S3 config
│   │       │       └── ingress-host.yaml
│   │       └── production/
│   │           ├── kustomization.yaml
│   │           └── patches/
│   └── frontend/
│       ├── base/
│       │   ├── deployment.yaml        # HTTP :3000
│       │   ├── service.yaml
│       │   ├── hpa.yaml
│       │   ├── ingress.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── staging/
│           │   ├── kustomization.yaml
│           │   └── patches/
│           │       ├── replicas.yaml
│           │       ├── resources.yaml
│           │       ├── env-backend.yaml   # gRPC host/port for BFF
│           │       └── ingress-host.yaml
│           └── production/
│               ├── kustomization.yaml
│               └── patches/
│
├── argocd/                            # ArgoCD application definitions
│   ├── projects/
│   │   └── goapps-project.yaml        # AppProject: allowed repos + destinations
│   └── apps/
│       ├── shared/
│       │   └── infra-apps.yaml        # Shared infra (database, monitoring, jaeger, image-updater)
│       ├── staging/
│       │   ├── finance-service.yaml   # Auto-sync, image updater annotations
│       │   ├── iam-service.yaml
│       │   ├── frontend.yaml
│       │   ├── infra-backup.yaml
│       │   └── infra-minio.yaml
│       └── production/
│           ├── finance-service.yaml   # Manual sync, requires approval
│           ├── iam-service.yaml
│           ├── frontend.yaml
│           ├── infra-backup.yaml
│           └── infra-minio.yaml
│
├── scripts/                           # Bootstrap and maintenance scripts
│   ├── bootstrap.sh                   # Full K3s cluster setup
│   ├── install-nginx-ingress.sh
│   ├── install-monitoring.sh
│   ├── install-argocd.sh
│   ├── install-image-updater.sh
│   ├── install-runner.sh              # GitHub self-hosted runner
│   ├── finance-setup.sh
│   ├── iam-setup.sh
│   ├── validate-manifests.sh
│   ├── fix-staging.sh
│   ├── fix-production.sh
│   └── reset-k3s.sh                  # DESTRUCTIVE: wipes cluster
│
├── docs/                              # Operational documentation
│   ├── deployment-guide.md
│   ├── INFRA_STABILITY_GUIDE.md
│   ├── LOCAL_VALIDATION_GUIDE.md
│   ├── vps-reset-guide.md
│   ├── secrets-env-inventory.md       # Secret keys -> env vars per workload (names only)
│   └── runbooks/
│       ├── ppc-service-deployment.md      # New-service deployment, end to end
│       ├── database-port-forward.md       # Tunnel goapps / ppc_db to localhost
│       └── monitoring-alerting-activation-2026-07.md
│
└── .github/
    ├── workflows/
    │   ├── ci.yml                     # Validate manifests + yamllint + Trivy scan
    │   ├── sync-argocd.yml            # Auto-sync staging, manual production
    │   └── health-check.yml           # Every 6 hours: nodes, pods, PVCs, backups
    ├── actions/
    │   └── install-argocd-cli/        # Reusable action for ArgoCD CLI
    ├── ISSUE_TEMPLATE/                # Bug, feature, incident, new-service templates
    └── PULL_REQUEST_TEMPLATE.md
```

---

## 4. Environments

| Property | Staging | Production |
|----------|---------|------------|
| Domain | `staging-goapps.mutugading.com` | `goapps.mutugading.com` |
| VPS | 4 CPU / 8GB RAM | 8 CPU / 16GB RAM |
| Namespace | `goapps-staging` | `goapps-production` |
| ArgoCD Sync | Automatic (prune + selfHeal) | Manual approval required |
| Service Replicas | 1 | 3 |
| Resource Limits | Lower (dev-friendly) | Higher (production-grade) |
| Backup Paths | `/staging-goapps-backup/` | `/goapps-backup/` |

### Namespace Layout

| Namespace | Purpose |
|-----------|---------|
| `database` | PostgreSQL, PgBouncer, Redis, RabbitMQ, exporters |
| `monitoring` | Prometheus, Grafana, Loki, Promtail |
| `observability` | Jaeger distributed tracing |
| `minio` | MinIO S3-compatible object storage |
| `argocd` | ArgoCD server and controllers |
| `ingress-nginx` | NGINX Ingress Controller |
| `goapps-staging` | Staging app pods (finance, iam, frontend) |
| `goapps-production` | Production app pods |

### Deployment Rules

1. **Always test in staging first** -- minimum 24 hours before production
2. Production sync requires manual approval via ArgoCD or workflow dispatch
3. Use overlays for environment differences -- never duplicate base manifests

---

## 5. Database Architecture

### PostgreSQL 18

- **Type**: StatefulSet (single pod)
- **Storage**: 20Gi PersistentVolumeClaim
- **Access**: `postgres.database.svc.cluster.local:5432` (internal only)
- **Schemas**: **every application table lives in `public`.** `base/database/postgres/configmap.yaml` (`init-schemas.sql`) does create four extra schemas — `export`, `auth`, `hr`, `finance` — but they are **empty**: no migration in `goapps-backend/services/*/migrations/postgres/` issues a `CREATE SCHEMA` or a schema-qualified `CREATE TABLE`. Do not assume a table is reachable as `finance.x` or `hr.x`; qualify with `public.` or nothing at all. (The `finance.*` / `hr.*` strings that appear in IAM migrations are **permission codes**, e.g. `finance.cost.caljob.create` — not schema names.)
- **Timezone**: `Asia/Jakarta`

Key configuration (`configmap.yaml`):

| Setting | Value | Purpose |
|---------|-------|---------|
| `max_connections` | 200 | PgBouncer pooling + direct; raised for the Phase C calc engine |
| `shared_buffers` | 1GB | Shared page cache |
| `effective_cache_size` | 3GB | Planner hint |
| `work_mem` | 16MB | Per-operation sort/hash memory |
| `maintenance_work_mem` | 512MB | VACUUM, CREATE INDEX |
| `wal_buffers` | 16MB | WAL staging |
| `max_wal_size` | 1GB | Checkpoint spacing |

> Values above are read straight from `base/database/postgres/configmap.yaml`. The table in
> `RULES.md` ("Database Management → PostgreSQL Configuration") is **stale** — it still lists
> 150 / 256MB / 128MB. Treat the configmap as the source of truth.

### PgBouncer (Connection Pooler)

- **Mode**: Transaction pooling
- **Pool size**: 100 connections
- **Access**: `pgbouncer.database.svc.cluster.local:5432`
- **HPA**: Enabled
- **VPA**: Enabled

**All services on the shared `goapps` database MUST connect via PgBouncer, never directly to PostgreSQL.**

**Documented exception — PPC.** PgBouncer is configured with `DB_NAME: goapps` and no `[databases]` block, so it cannot front `ppc_db` at all. `ppc-service` therefore connects directly to `postgres.database.svc.cluster.local:5432` (see `services/ppc-service/base/deployment.yaml`). This is acceptable because PPC's HPA is pinned `minReplicas: 1 / maxReplicas: 1`, capping its connection count. If PPC is ever scaled past 1 replica, add a `[databases]` entry for `ppc_db` to PgBouncer first.

```yaml
# CORRECT
DATABASE_HOST: "pgbouncer.database.svc.cluster.local"
DATABASE_PORT: "5432"

# WRONG -- never do this in services
DATABASE_HOST: "postgres.database.svc.cluster.local"
```

### Redis 7

- **Type**: Deployment (non-StatefulSet)
- **Storage**: emptyDir (data lost on restart -- cache only)
- **Access**: `redis.database.svc.cluster.local:6379`
- **DB 0**: Application cache (including email verification OTPs)
- **DB 1**: Token blacklist (shared between IAM and other services for JWT invalidation)

### RabbitMQ 3

- **Storage**: 5Gi PVC
- **Management UI**: Port 15672
- **Note**: Single pod (no clustering) -- single point of failure risk

### Adding a New Schema

> **Rarely what you want.** The platform does not actually use per-module schemas — all tables
> are in `public` (see "Schemas" above), and `init-schemas.sql` only runs on **first initdb** of an
> empty data directory, so editing it does nothing to an existing volume. Prefer a plain migration.

Edit `base/database/postgres/configmap.yaml` and add to `init-schemas.sql`:

```sql
CREATE SCHEMA IF NOT EXISTS new_schema;
GRANT ALL PRIVILEGES ON SCHEMA new_schema TO postgres;
```

Then restart PostgreSQL (data is preserved):

```bash
kubectl rollout restart statefulset/postgres -n database
```

---

## 6. Monitoring Stack

Installed via Helm charts. Configuration in `base/monitoring/helm-values/`.

### Prometheus (kube-prometheus-stack)

- **Retention**: 15 days **or** 15GB, whichever hits first (`retention` / `retentionSize` in `base/monitoring/helm-values/prometheus-stack.yaml`; an earlier version of this doc said 30 days)
- **Storage**: 20Gi PVC (on the root disk -- ~6.4G used on production, 2026-10-12)
- **ServiceMonitor**: Auto-discovery enabled for **all** ServiceMonitors in **all** namespaces. `serviceMonitorSelectorNilUsesHelmValues: false` is set in `base/monitoring/helm-values/prometheus-stack.yaml`, so a `release: prometheus` label is **NOT** required (an earlier version of this doc claimed it was — it is false for this cluster).
- **Scrape interval**: 30s default

### Grafana

- **Storage**: 10Gi PVC
- **SMTP**: Configured for email alerts
- **Dashboards** (auto-loaded via sidecar with `grafana_dashboard: "1"` label):
  - GoApps Service Dashboard (`grafana-dashboard-go-apps.json`)
  - PostgreSQL Dashboard (`grafana-dashboard-postgres.json`)
  - Loki Log Dashboard (`grafana-dashboard-loki.json`)
- **Datasources**: Prometheus + Loki — managed EXCLUSIVELY via Helm values (`grafana.additionalDataSources` in `helm-values/prometheus-stack.yaml`); never apply datasource ConfigMaps (see INFRA_STABILITY_GUIDE.md)

### Loki + Promtail

- **Purpose**: Centralized log aggregation
- **Helm values**: `base/monitoring/helm-values/loki-stack.yaml`
- **Promtail**: DaemonSet that ships logs from all pods to Loki

### Alert Rules

Located in `base/monitoring/alert-rules/`. Only these are in `kustomization.yaml`:
- `complete-alerts.yaml` -- Comprehensive alert set (Grafana **unified-alerting** rules, keyed by `title:`, not Prometheus `alert:` rules)
- `postgres-alerts.yaml` -- PostgreSQL-specific alerts (includes a `ppc_db` deadlock rule alongside the `goapps` one)
- `cost-calc-alerts.yaml` -- finance-cost-worker specific
- `grafana-alertrules-configmap.yaml` -- `deleteRules:` tombstone; do not remove, do not extend

`grafana-alert-rules.yaml` also exists in that directory but is **not** in `kustomization.yaml` and is applied by nothing. Leave it alone.

To add a new alert, create a ConfigMap with the **`grafana_alert: "1"`** label (NOT `grafana_dashboard: "1"` — that label is for dashboards) or edit the existing alert rule files.

⚠️ **Additive only.** `base/monitoring/` is under no ArgoCD Application (see §9) — nothing reconciles it and nothing restores it. Never regenerate a dashboard JSON from a Grafana export; edit surgically.

### Adding a ServiceMonitor for a New Service

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service-monitor
  namespace: monitoring
  # No `release: prometheus` label needed — Prometheus selects all
  # ServiceMonitors in all namespaces (see above).
spec:
  selector:
    matchLabels:
      app: my-service
  namespaceSelector:
    matchNames:
      - goapps-staging
      - goapps-production
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

Name the endpoint after an **existing** ServicePort. A service whose gateway serves `/metrics` on the same port as its API (ppc-service: both on 8082) has **no** separate `metrics` port — Kubernetes enforces ServicePort uniqueness on `(protocol, port)`, not on name, so a second 8082 entry makes the whole Service unappliable. Use `port: http` there.

### `base/monitoring/` IS OUTSIDE GITOPS -- apply it by hand, on BOTH hosts

**Almost none of `base/monitoring` is managed by ArgoCD.** `argocd/apps/shared/infra-apps.yaml` covers only `base/database` and `base/observability/jaeger`, and no workflow applies the directory.

The **one** exception, added 2026-09-15: `argocd/apps/{staging,production}/infra-grafana-backup.yaml` point at `overlays/{staging,production}/grafana-backup`, which pulls in `base/monitoring/grafana-backup/`. That subdirectory alone has `selfHeal: true` and *is* reconciled. It was carved out deliberately -- it contains only a CronJob and its RBAC, no Grafana state, so a sync can never overwrite dashboards or alert config. Note those two Applications are not applied by anything either; they were `kubectl apply -f`'d by hand once per cluster.

Everything else under `base/monitoring/` -- **dashboards, alert rules, helm values** -- still reaches a cluster **only** via a manual `kubectl apply`, and "sync the Application" is not a fix — there is no Application to sync. What runs in the cluster is a snapshot of whoever last applied it, which is why `ppc-service` was missing from the dashboard filter for weeks while being correct in git.

Staging and production are **separate clusters** — run the apply on both hosts:

```bash
kubectl apply -f base/monitoring/dashboards/grafana-dashboard-go-apps-configmap.yaml
```

The file is environment-agnostic (there is no production overlay, and `namespace: monitoring` is hardcoded inside it). The dashboard's own `namespace` variable carries **both** `goapps-staging` and `goapps-production` with staging pre-selected, so the same ConfigMap ships to both clusters and you switch environment from the dropdown *inside* Grafana — production's Grafana defaulting to `goapps-staging` is expected, not a mis-apply.

Two consequences worth internalizing:

- **No `selfHeal`.** An in-cluster edit is never reverted from git, and a git change is never auto-applied. Permanent drift risk — but also why the Grafana alert config has never been silently overwritten by a sync.
- Applying a **single dashboard ConfigMap** is safe (one resource, one data key, in-place update, no `--prune`, not `-k`). What is *not* safe, and must never be done casually, is `kubectl apply -k base/monitoring/alert-rules/`, any `delete`, or regenerating these files from a Grafana export.

**If you must run `apply -k base/monitoring/alert-rules/`** (done 2026-09-15 to ship `grafana-db-backup-failed`), it is survivable but verify, do not assume:

```bash
kubectl apply -k base/monitoring/alert-rules            # expect "configured", never "created"
GPOD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n monitoring "$GPOD" -c grafana-sc-alerts --tail=30 | grep -i "complete-alert\|error"
```

The `grafana-sc-alerts` sidecar rewrites `/etc/grafana/provisioning/alerting/` within ~1 min. **No `helm upgrade`, no pod restart, no PVC touch** — which is exactly why this path is safe and the Helm route is not. A `created` instead of `configured` means you are on the wrong cluster or the ConfigMap was deleted: stop.

### Dashboard service filter is a HARDCODED list -- add every new service by hand

The `service` template variable in `base/monitoring/dashboards/grafana-dashboard-go-apps.json` is **`type: custom`** — a literal comma-separated list, not a Prometheus `label_values()` query:

```json
"query": "finance-service,iam-service,ppc-service,frontend",
```

**There is no auto-discovery.** A new service emitting perfectly good metrics simply never appears in the dropdown until its name is added to that string. Edit **both** the `.json` and the `-configmap.yaml` beside it — Grafana's sidecar reads the ConfigMap; the loose `.json` is only the source copy, and they drift silently.

If a service is present in the ConfigMap but still missing from the dropdown, Grafana has stale state rather than stale config:

```bash
kubectl get cm grafana-dashboard-go-apps -n monitoring \
  -o jsonpath='{.data.go-apps-microservices\.json}' | grep -o 'finance-service,iam-service[^"]*'
```

Missing there ⇒ sync the `infra-apps` Application. Present there ⇒ `kubectl rollout restart deploy/prometheus-grafana -n monitoring`.

### Alerting is namespace-scoped, NOT per-service -- new services are covered automatically

`base/monitoring/alert-rules/complete-alerts.yaml` selects on namespace, never on service name:

```
KubePodCrashLooping   kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", namespace!~"database"}
KubePodNotReady       kube_pod_status_phase{phase="Pending", namespace=~"goapps-staging|goapps-production|..."}
KubeDeploymentReplicasMismatch, PodOOMKilled, PodRestartingTooOften, HPAMaxedOut, ...
```

Any Deployment in `goapps-staging` / `goapps-production` inherits all of them the moment it exists. **Silence after a rollout means the rollout succeeded** — these rules fire only on `CrashLoopBackOff`, `Pending`, unavailable replicas, or OOMKills. The email flood people associate with "a new image went out" is the signature of a *failing* rollout, not a routine notification. Do not read a quiet inbox as missing coverage.

Only genuinely service-specific alerts need authoring. Note that `postgres-alerts.yaml` currently carries **only one** `ppc_db`-specific rule — `postgres-deadlocks-ppc` ("PostgreSQL Deadlocks Detected (ppc_db)"). There are **no** `ppc_db` size, connection-count, or backup rules; an earlier version of this doc claimed there were.

⚠️ **`grafana-alert-rules.yaml` is NOT in `alert-rules/kustomization.yaml`** — only `complete-alerts`, `grafana-alertrules-configmap`, `postgres-alerts`, `cost-calc-alerts` are applied. It appears to be a superseded copy of `grafana-alertrules-configmap.yaml`. Left in place deliberately: **never delete, rename, regenerate, or reformat Grafana alert config** — this configuration was lost once before and had to be rebuilt from scratch. Never add a uid to `deleteRules:`.

---

## 7. Observability

### Jaeger (Distributed Tracing)

- **Deployment**: All-in-one (collector + query + UI in single pod)
- **Protocol**: OTLP (OpenTelemetry)
- **Collector endpoint**: `jaeger-collector.observability.svc.cluster.local:4317`
- **Storage**: In-memory only (**5000** traces max -- `MEMORY_MAX_TRACES: "5000"` in `base/observability/jaeger/deployment.yaml`)
- **Namespace**: `observability`

Services configure tracing via environment variables:

```yaml
TRACING_ENABLED: "true"
JAEGER_ENDPOINT: "jaeger-collector.observability.svc.cluster.local:4317"
```

---

## 8. Deployment Pattern

Every service follows the **base + overlays** pattern with Kustomize:

```
services/<service-name>/
├── base/                    # Environment-agnostic manifests
│   ├── kustomization.yaml   # Lists all resources + commonLabels
│   ├── deployment.yaml      # Container spec, ports, probes, base env vars
│   ├── service.yaml         # ClusterIP service (gRPC, HTTP, metrics ports)
│   ├── hpa.yaml             # HPA: min 1, max 3, 70% CPU (prod overlay patches min to 2)
│   ├── ingress.yaml         # Ingress rules (host set via overlay patch)
│   ├── migrate-job.yaml     # One-time DB migration Job (optional)
│   ├── seed-job.yaml        # One-time data seed Job (optional)
│   └── servicemonitor.yaml  # Prometheus scrape config
└── overlays/
    ├── staging/
    │   ├── kustomization.yaml    # namespace: goapps-staging, image tag, patches
    │   └── patches/
    │       ├── replicas.yaml     # 1 replica
    │       ├── resources.yaml    # Lower CPU/memory limits
    │       ├── env-cors.yaml     # Staging CORS origins
    │       └── ingress-host.yaml # staging-goapps.mutugading.com
    └── production/
        ├── kustomization.yaml    # namespace: goapps-production
        └── patches/
            ├── replicas.yaml     # 3 replicas
            ├── resources.yaml    # Higher CPU/memory limits
            ├── env-cors.yaml     # Production CORS origins
            └── ingress-host.yaml # goapps.mutugading.com
```

### Service Ports Convention

| Service | gRPC | HTTP/Gateway | Metrics |
|---------|------|-------------|---------|
| finance-service | 50051 | 8080 | 8090 |
| iam-service | 50052 | 8081 | 8091 |
| ppc-service | 50053 | 8082 | **8082 (same port, served by the HTTP gateway)** |
| frontend | -- | 3000 | -- |

**PPC is the exception to the separate-metrics-port pattern**: `/metrics` is registered on the gateway mux (`services/ppc/internal/delivery/httpdelivery/gateway.go`), so `service.yaml` declares only `grpc` + `http` and `servicemonitor.yaml` scrapes `port: http`. Adding a second ServicePort on 8082 makes the Service **unappliable** — Kubernetes enforces uniqueness on `(protocol, port)`, not on port name, and neither `kustomize build` nor `kubeconform` catches it. Only `kubectl apply --dry-run=server` does.

### Health Probes

Backend services use gRPC health checks:

```yaml
livenessProbe:
  grpc:
    port: 50051
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  grpc:
    port: 50051
  initialDelaySeconds: 5
  periodSeconds: 5
```

Frontend uses HTTP health checks on port 3000.

### Image Pull

All **application** images come from `ghcr.io/mutugading/` and require `imagePullSecrets`:

```yaml
imagePullSecrets:
  - name: ghcr-secret
```

**Third-party images are not guaranteed to stay pullable.** MinIO deleted `minio/minio` and `minio/mc` from Docker Hub (Sept 2026) and then closed anonymous pulls on `quay.io/minio/*` (401); `dl.min.io` binaries return 410. A node keeps running off its **cached** copy, so the breakage stays invisible until kubelet garbage-collects the image (e.g. under DiskPressure) -- then every pod or Job using it sits in `ImagePullBackOff`. See §10 "MinIO image source" for what the backup stack uses now.

---

## 9. ArgoCD Configuration

### Project

Defined in `argocd/projects/goapps-project.yaml`:
- **Source repos**: `goapps-infra.git`, `goapps-backend.git`
- **Destinations**: All namespaces on the local cluster
- **Role**: `admin` role for `goapps-admins` group

### Application Definitions

Located in `argocd/apps/`:

| Application | Path | Sync Policy |
|-------------|------|-------------|
| `infra-database` (in `argocd/apps/shared/infra-apps.yaml`) | `base/database` | Auto |
| `infra-observability` (in `argocd/apps/shared/infra-apps.yaml`) | `base/observability/jaeger` | Auto |
| `finance-service-staging` | `services/finance-service/overlays/staging` | Auto (prune + selfHeal) |
| `iam-service-staging` | `services/iam-service/overlays/staging` | Auto (prune + selfHeal) |
| `ppc-service-staging` | `services/ppc-service/overlays/staging` | Auto (prune + selfHeal) |
| `frontend-staging` | `services/frontend/overlays/staging` | Auto (prune + selfHeal) |
| `finance-service-production` | `services/finance-service/overlays/production` | Manual |
| `iam-service-production` | `services/iam-service/overlays/production` | Manual |
| `ppc-service-production` | `services/ppc-service/overlays/production` | Manual |
| `frontend-production` | `services/frontend/overlays/production` | Manual |
| `infra-backup` (staging cluster) | `overlays/staging/backup` | Auto (prune + selfHeal) |
| `infra-minio` (staging cluster) | `overlays/staging/minio` | Auto (prune + selfHeal) |
| `infra-backup` (production cluster) | `overlays/production/backup` | **Auto (prune + selfHeal)** |
| `infra-minio` (production cluster) | `overlays/production/minio` | **Auto (prune + selfHeal)** |

⚠️ **The infra backup/MinIO Applications are auto-sync on production too** (`argocd/apps/production/infra-{backup,minio}.yaml`), and are named `infra-backup` / `infra-minio` in *both* clusters -- no `-staging`/`-production` suffix. A merge to `main` touching `base/backup/` or the backup/minio overlays reaches production within ~3 min **without** a manual sync, so test those changes on staging first. It also means a `kubectl edit` on a backup CronJob is reverted by selfHeal -- change it in git. An earlier version of this table listed the production ones as Manual.

⚠️ **`argocd/apps/shared/infra-apps.yaml` declares exactly two Applications: `infra-database` and `infra-observability`.** An earlier version of this doc claimed it also covered monitoring and image-updater — it does **not**.

- **`base/monitoring/` is under NO ArgoCD Application.** It is applied **imperatively** by `scripts/install-monitoring.sh`. Nothing reconciles it, nothing restores it after a manual change, and a Grafana-side edit silently diverges from git. Treat all monitoring changes as additive and surgical.
- The ArgoCD Image Updater is likewise installed by script (`scripts/install-image-updater.sh` / `install-argocd.sh`), not by an Application.
- Bringing monitoring under GitOps is tracked as a **separate effort**. It must deduplicate the double-prefixed ConfigMaps that `install-monitoring.sh` generates *before* `prune` is ever enabled, or ArgoCD will delete ConfigMaps it does not own.

### ArgoCD Image Updater

Automatically detects new Docker image tags and updates Kustomize overlays:

```yaml
# Annotations on ArgoCD Application resources:
argocd-image-updater.argoproj.io/image-list: finance=ghcr.io/mutugading/finance-service
argocd-image-updater.argoproj.io/finance.update-strategy: newest-build
argocd-image-updater.argoproj.io/finance.allow-tags: regexp:^[a-f0-9]{7,40}$
argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/git-creds
argocd-image-updater.argoproj.io/write-back-target: kustomization
argocd-image-updater.argoproj.io/git-branch: main
```

Flow: New image pushed to GHCR (Git SHA tag) -> Image Updater detects it -> Updates `kustomization.yaml` in git -> ArgoCD syncs the change to cluster.

### Sync Retry Policy

All staging apps have retry with exponential backoff:

```yaml
retry:
  limit: 5
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
```

---

## 10. Backup Strategy

| Target | Frequency | Schedule (WIB) | Retention | Destinations |
|--------|-----------|----------------|-----------|-------------|
| PostgreSQL | 3x daily | 04:00, 12:00, 20:00 (low-traffic, 8h apart) | 7 days | **Dedicated backup disk only** (+ Backblaze B2 only if the optional `s3-cloud-credentials` secret exists) |
| MinIO app buckets (`export-files`, `goapps-{env}`) | Daily | 03:00 | Mirror (no prune) | Dedicated backup disk |

**Backup disk** = a separate block device mounted at `/goapps-backup` (production, `sdb`) / `/staging-goapps-backup` (staging). It is **not** the root disk that holds the PVCs.

**Postgres dumps no longer go to MinIO** (both envs, since 2026-10-08/12). Both backup overlays blank `MINIO_ENDPOINT` for the three postgres CronJobs, so `backup.sh` skips the MinIO upload and prune, and `postgres-backups` is dropped from `MINIO_BUCKETS`. Reason: the `postgres-backups` bucket lived inside the MinIO PVC on the **root** disk; at ~24G it pushed production into DiskPressure (see §17). The bucket is left empty, not deleted.

**Backblaze B2 is optional and silent.** The `S3_*` env vars use `optional: true` secret refs, so with no `s3-cloud-credentials` secret the upload is skipped with no log line and no error. Do not assume an off-host copy exists -- check `kubectl get secret s3-cloud-credentials -n database` and look for `Uploaded to Cloud S3` in a job log.

### MinIO image source

Every MinIO reference (`base/backup/minio/deployment.yaml`, the `copy-mc` init container in the three postgres CronJobs, `minio-backup.yaml`, `minio-ilm-setup.yaml`) uses
`ghcr.io/coollabsio/minio:RELEASE.2025-10-15T17-29-55Z@sha256:69b55a1c...` -- an anonymous public rebuild of the upstream AGPL release with the same layout as the old `minio/minio` (`/usr/bin/minio`, `/usr/bin/mc`, `sh`, `cp`), so it also serves as the `mc` image. It is pinned by digest because it is a **third-party mirror**; the planned follow-up is to copy it to `ghcr.io/mutugading/minio` and point there. Do **not** switch to `quay.io/minio/aistor/*` (commercial AIStor) or `cgr.dev/chainguard/minio` (non-root, no shell/`cp` -- breaks `copy-mc`) without reworking the manifests.

### Backup CronJobs

Defined in `base/backup/cronjobs/`:
- `postgres-backup.yaml` -- Three CronJobs (morning, afternoon, evening)
- `minio-backup.yaml` -- Daily MinIO bucket backup

Guards on every backup CronJob (added 2026-10-12, see §17):
- `activeDeadlineSeconds` -- 3h postgres / 2h minio mirror. A Job that cannot finish (e.g. `ImagePullBackOff`) turns **Failed** instead of sitting "Running" forever. With `concurrencyPolicy: Forbid`, a forever-Running Job silently skips every later schedule.
- `startingDeadlineSeconds: 3600` -- a run missed by more than 1h is skipped, not fired late. Stops several CronJobs firing catch-up runs at once.
- Dump filename = `${ENVIRONMENT}_{goapps,ppc_db}_<YYYYmmdd_HHMMSS>_<pod-hash>.sql.gz`. The pod-hash suffix keeps concurrent runs from ever sharing a file; older files have no suffix. Prefix globs (`*_goapps_*`) and `ls -t` ordering still work.
- A dump is considered good only when the log shows `VERIFY OK ... completion marker present` and the job ends `Backup completed successfully!`. Local retention (`find -mtime +7 -delete`) runs **only** after a fully successful run, so a run of failures also means old files pile up.

### Manual Backup

```bash
make backup-now
# Creates a one-off Job from the morning CronJob template
```

Manual-run pitfalls (all hit on 2026-10-12):
- **Never delete a running backup Job** to "clean up" -- the pod is killed mid-`pg_dump` and leaves a truncated `.sql.gz` (no shell trap removes it). Check with `gzip -t`; delete only files that fail it.
- `kubectl logs -f` right after `create job` fails with `PodInitializing` while the `copy-mc` init container runs -- wait with `kubectl wait --for=condition=Ready pod -l job-name=<job>` first. A `failed to create fsnotify watcher: too many open files` from `logs -f` is the **host's** inotify limit, not the backup; raised on production via `/etc/sysctl.d/99-inotify.conf` (`max_user_instances=512`, `max_user_watches=524288`).
- Do not start a manual run next to a scheduled one (04:00/12:00/20:00 WIB) -- two `pg_dump`s double the load on `postgres-0`. A production `goapps` dump took ~37 min at 1.8G (2026-10-12) and grows ~0.5G per 10 days.

### Backup Verification (Weekly Checklist)

```bash
kubectl get cronjobs -n database              # Check schedules and last run
kubectl get jobs -n database                  # Check recent job status -- anything not Complete is a problem
kubectl get pods -n database | grep -E 'ImagePull|Init:|Error'   # must be empty
gzip -t "$(ls -t /goapps-backup/postgres/*_goapps_*.sql.gz | head -1)" && echo OK   # newest dump is intact
find /goapps-backup/postgres -name '*.sql.gz' -mtime +7 | wc -l                     # 0 = retention is running
# MinIO bucket `postgres-backups` should stay at 0B (dumps are no longer uploaded)
# Backblaze B2 console -- only if s3-cloud-credentials exists (see above)
# Check VPS disk (path differs per host -- see note below):
#   production: ls -la /goapps-backup/postgres/
#   staging:    ls -la /staging-goapps-backup/postgres/
```

### Restore Testing (Monthly)

```bash
# 1. Get latest backup
BACKUP=$(ls -t /staging-goapps-backup/postgres/*.sql.gz | head -1)   # staging; production uses /goapps-backup/postgres

# 2. Create test database
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "CREATE DATABASE goapps_restore_test"

# 3. Restore
kubectl exec -it postgres-0 -n database -- bash -c "gunzip -c ${BACKUP} | psql -U postgres -d goapps_restore_test"

# 4. Verify tables exist and have data
# 5. Drop test database
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "DROP DATABASE goapps_restore_test"
```

---

## 11. CI/CD Pipelines

### CI Pipeline (`.github/workflows/ci.yml`)

Triggered on: push to `main`/`develop`, PRs to `main`.

| Job | What it does |
|-----|-------------|
| `validate` | `kustomize build` on all base/, overlays/, and service manifests |
| `lint` | `yamllint` with `.yamllint.yml` config (non-blocking currently) |
| `security` | Trivy config scan for CRITICAL/HIGH issues (non-blocking currently) |

### ArgoCD Sync Pipeline (`.github/workflows/sync-argocd.yml`)

Triggered on: push to `main` (paths: `base/**`, `overlays/**`, `services/**`, `argocd/**`) or manual dispatch.

- **Staging**: Automatic on push. Runs on self-hosted runner (`staging` label). Syncs `infra-apps`, `finance-service-staging`, `frontend-staging`, `iam-service-staging`. Waits for healthy (600s timeout).
- **Production**: Manual dispatch only (choose `production` or `all`). Runs on self-hosted runner (`production` label). Requires `sync-staging` to succeed first when using `all`.

Authentication: Uses `ARGOCD_AUTH_TOKEN` secrets (`ARGOCD_TOKEN_STAGING`, `ARGOCD_TOKEN_PRODUCTION`). ArgoCD CLI runs inside the ArgoCD server pod via `kubectl exec`.

### Health Check Pipeline (`.github/workflows/health-check.yml`)

Triggered: Every 6 hours (cron) or manual dispatch.

Checks per environment:
- Node status (Ready/NotReady)
- Critical pod status (CrashLoopBackOff detection)
- PVC status
- CronJob and backup job status

Production checks are stricter (exit 1 on failures vs warnings for staging).

---

## 12. Secrets Management

**Golden Rule: NEVER commit secrets to Git.**

### Secret Templates

`base/secrets/secrets-template.yaml` contains placeholder templates showing required secret keys. These are NOT real values.

### Creating Secrets in Cluster

```bash
# PostgreSQL
kubectl create secret generic postgres-secret -n database \
  --from-literal=POSTGRES_USER='postgres' \
  --from-literal=POSTGRES_PASSWORD='<password>' \
  --from-literal=POSTGRES_DB='goapps'

# JWT Auth
kubectl create secret generic goapps-auth-secret -n goapps-staging \
  --from-literal=JWT_ACCESS_SECRET='<secret>' \
  --from-literal=JWT_REFRESH_SECRET='<secret>'

# GHCR Image Pull
kubectl create secret docker-registry ghcr-secret -n goapps-staging \
  --docker-server=ghcr.io \
  --docker-username=<user> \
  --docker-password=<token>

# TLS Wildcard
kubectl create secret tls goapps-tls -n <namespace> \
  --cert=tls.crt --key=tls.key

# MinIO
kubectl create secret generic minio-secret -n minio \
  --from-literal=MINIO_ROOT_USER='<user>' \
  --from-literal=MINIO_ROOT_PASSWORD='<password>'
```

### Secrets Inventory

| Secret | Namespace(s) | Keys |
|--------|-------------|------|
| `postgres-secret` | `database` | POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB |
| `goapps-auth-secret` | `goapps-staging`, `goapps-production` | JWT_ACCESS_SECRET, JWT_REFRESH_SECRET |
| `goapps-tls` | multiple | tls.crt, tls.key (wildcard cert) |
| `ghcr-secret` | `goapps-staging`, `goapps-production` | .dockerconfigjson |
| `minio-secret` | `minio`, `database` | MINIO_ROOT_USER, MINIO_ROOT_PASSWORD |
| `grafana-admin-secret` | `monitoring` | admin-user, admin-password |
| `grafana-smtp-secret` | `monitoring` | password |
| `goapps-internal-token` | `goapps-staging`, `goapps-production` | INTERNAL_SERVICE_TOKEN |
| `ppc-internal-token` | `goapps-staging`, `goapps-production` | PPC_INTERNAL_TOKEN |
| `oracle-credentials` | `goapps-staging`, `goapps-production` | ORACLE_HOST, ORACLE_PORT, ORACLE_SERVICE, ORACLE_USER, ORACLE_PASSWORD, ORACLE_MGTHRIS_USER/PASSWORD, ORACLE_MGTAPPS_USER/PASSWORD, ORACLE_MGTDAT_USER/PASSWORD (production-verified; HRIS = MGTHRIS) |
| `finance-db-secret`, `iam-db-secret`, `ppc-db-secret` | `goapps-staging` | APP_USER, APP_PASSWORD (per-service app role; production still uses `postgres-secret`) |
| `goapps-chat-secret` | `goapps-staging`, `goapps-production` | CHAT_MASTER_KEY |
| `rabbitmq-secret` | `database`, `goapps-staging`, `goapps-production` | RABBITMQ_USER, RABBITMQ_PASSWORD |
| `smtp-secret` | `goapps-staging`, `goapps-production` | SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM_ADDRESS |
| `git-creds` | `argocd` | Used by ArgoCD Image Updater for git write-back |

`ppc-internal-token`'s single key `PPC_INTERNAL_TOKEN` is consumed twice by both `ppc-service` `deployment.yaml` and `seed-job.yaml` — as `PPC_INTERNAL_TOKEN` and as `PPC_JWT_SERVICE_SECRET`. Its **value must equal** the `INTERNAL_SERVICE_TOKEN` in `goapps-internal-token` in the same namespace, because finance/IAM validate the incoming token against their own. Different value per environment. See `docs/runbooks/ppc-service-deployment.md`.

**Full env var → secret key mapping per workload** (e.g. `ORACLE_HRIS_USER` ← `oracle-credentials/ORACLE_MGTHRIS_USER`): `docs/secrets-env-inventory.md`. Check it before adding an env var or secret -- reuse an existing key instead of guessing a name, and update it in the same PR.

### Referencing Secrets in Deployments

```yaml
env:
  - name: DATABASE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: POSTGRES_PASSWORD
```

---

## 13. Linting and Validation

### yamllint Configuration (`.yamllint.yml`)

```yaml
extends: default
rules:
  line-length:
    max: 200            # Generous for K8s manifests
    level: warning
  truthy:
    allowed-values: ['true', 'false', 'yes', 'no']
  comments:
    min-spaces-from-content: 1
  indentation:
    spaces: 2
    indent-sequences: true
  document-start: disable
  empty-lines:
    max: 2
ignore: |
  .git/
  node_modules/
```

### Validation Commands

```bash
# Lint all YAML
yamllint -c .yamllint.yml .

# Validate specific kustomization
kustomize build base/database/
kustomize build services/finance-service/overlays/staging/

# Dry-run against cluster
kubectl apply --dry-run=client -k base/database/

# Full manifest validation script
./scripts/validate-manifests.sh

# Trivy security scan
trivy config --severity CRITICAL,HIGH .
```

### Alat Validasi

- **Versi yang direkomendasikan (sama dengan CI):** kustomize v5.3.0 (`KUSTOMIZE_VERSION` di `ci.yml`), kubeconform v0.6.7, actionlint 1.7.1. Cek dengan `command -v`, jangan `find /`.
- **Pasang:** `scripts/install-infra-tools.sh` (default ke `~/.local/bin`, override dengan `BIN_DIR`; checksum SHA256 diverifikasi). Mendukung Linux dan macOS (amd64/arm64). Skrip tidak mengubah rc file; kalau `BIN_DIR` belum ada di `PATH`, skrip mencetak instruksi `export PATH=...`.
- **Validasi manifest:** `kustomize build <overlay> | kubeconform -strict -summary`
- **Validasi workflow:** `actionlint`

### CI Validation

The CI pipeline (`ci.yml`) runs three validation jobs on every push/PR:
1. **Validate Manifests** -- `kustomize build` on every directory with a `kustomization.yaml`
2. **Lint YAML** -- `yamllint` (currently non-blocking with `|| true`)
3. **Security Scan** -- Trivy config scan for CRITICAL/HIGH (currently non-blocking)

---

## 14. Naming Conventions

### Kubernetes Resources

| Resource | Pattern | Examples |
|----------|---------|---------|
| Namespace | `<purpose>` or `<app>-<env>` | `database`, `monitoring`, `goapps-staging` |
| Deployment | `<service-name>` | `finance-service`, `frontend`, `pgbouncer` |
| StatefulSet | `<app-name>` | `postgres`, `rabbitmq` |
| Service | `<deployment-name>` | `finance-service`, `postgres`, `redis` |
| ConfigMap | `<app>-config` | `postgres-config`, `grafana-config` |
| Secret | `<app>-secret` | `postgres-secret`, `minio-secret` |
| HPA | `<deployment>-hpa` | `finance-service-hpa`, `pgbouncer-hpa` |
| VPA | `<deployment>-vpa` | `postgres-vpa`, `pgbouncer-vpa` |
| PVC | `<app>-data` | `postgres-data`, `grafana-data` |
| CronJob | `<purpose>-<schedule>` | `postgres-backup-morning`, `minio-backup-daily` |
| Ingress | `<app>-ingress` | `grafana-ingress`, `argocd-ingress` |
| ServiceMonitor | `<service>-monitor` | `finance-service-monitor` |

### ArgoCD Application Names

| Pattern | Examples |
|---------|---------|
| `<service>-<env>` | `finance-service-staging`, `frontend-production` |
| `infra-<component>` | `infra-database`, `infra-monitoring`, `infra-backup` |

### Required Labels (All Resources)

```yaml
labels:
  app: <service-name>
  app.kubernetes.io/name: <service-name>
  app.kubernetes.io/part-of: goapps
  app.kubernetes.io/component: <type>    # backend, frontend, database, cache, queue
```

### Required Annotations (Prometheus Scraping)

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8090"
  prometheus.io/path: "/metrics"
```

### Git Conventions

Branch names: `infra/<description>`, `feat/<service>`, `fix/<issue>`, `hotfix/<issue>`

Commit format: `<type>(<scope>): <description>`
- Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`
- Examples: `feat(iam-service): add staging deployment`, `fix(backup): correct minio endpoint`

---

## 15. Adding a New Service

Follow these steps in order:

### Step 1: Create Directory Structure

```bash
SERVICE_NAME="my-service"
mkdir -p services/${SERVICE_NAME}/{base,overlays/{staging,production}/patches}
```

### Step 2: Create Base Manifests

Create these files in `services/${SERVICE_NAME}/base/`:
- `deployment.yaml` -- Container spec with gRPC/HTTP/metrics ports, probes, env vars, resource limits
- `service.yaml` -- ClusterIP service exposing gRPC (50051), HTTP (8080), metrics (8090)
- `hpa.yaml` -- HPA with min 1, max 3, CPU 70% (production overlay patches `minReplicas: 2`)

> **Capacity check before choosing `maxReplicas`.** This is a SINGLE-NODE cluster
> (~16Gi) shared with the `database`, `monitoring`, `observability` and `minio`
> namespaces. Memory *limits* are already overcommitted well past 100%, and K8s
> schedules on **requests** — so a fan-out that the scheduler cheerfully admits
> can still OOM-kill the node, taking Grafana and Postgres down with it (incident
> 2026-08-13). Multiply `maxReplicas x memory limit` and check it against the node
> before merging, especially for queue-driven (external-metric) HPAs, which can
> jump to max without any CPU signal.
- `kustomization.yaml` -- Lists resources + commonLabels
- `servicemonitor.yaml` -- Prometheus scrape config (optional)
- `ingress.yaml` -- Ingress rules (optional, host set via overlay patch)

Use existing services (`finance-service` or `iam-service`) as templates.

### Step 3: Create Overlays

Staging overlay (`overlays/staging/kustomization.yaml`):
- Set `namespace: goapps-staging`
- Reference `../../base`
- Add patches for replicas, resources, env, ingress host
- Set image tag

Production overlay: same structure with higher resources, 3 replicas, production domain.

### Step 4: Create ArgoCD Application -- AND APPLY IT BY HAND (see Step 8)

Add `argocd/apps/staging/<service>.yaml` and `argocd/apps/production/<service>.yaml`.

Staging gets `syncPolicy.automated` with prune + selfHeal. Production gets no automated sync (manual).

Include ArgoCD Image Updater annotations for automatic image tag updates.

Committing the file is **not** enough to create the Application -- see Step 8.

### Step 5: Add Database Schema (If Needed)

Edit `base/database/postgres/configmap.yaml` to add the new schema.

### Step 6: Add to Sync Workflow

Update `.github/workflows/sync-argocd.yml` to include the new service in the sync steps.

### Step 7: Add a build workflow in `goapps-backend` -- DO NOT SKIP

A new backend service also needs its own `goapps-backend/.github/workflows/<service>.yml` (model it on `iam-service.yml`), or **no image is ever built**. Everything downstream then fails silently:

- No image in GHCR ->
- ArgoCD Image Updater's `allow-tags: regexp:^[a-f0-9]{7,40}$` never matches ->
- the overlay's `newTag` is never rewritten and still points at a nonexistent tag ->
- `ImagePullBackOff`.

Nothing in `goapps-infra` detects this: the manifests are valid, `kustomize build` passes, ArgoCD reports the Application Synced. This omission is exactly what happened to `ppc-service` (gap D-1) — manifests, overlays and ArgoCD Applications all existed for weeks with no workflow behind them.

The workflow's `paths:` filter must also list every shared directory the service imports (e.g. `services/shared/**`, `pkg/**`), or a change there will not rebuild the service.

### Step 8: Apply the ArgoCD Application manually -- ONE-TIME, DO NOT SKIP

**Nothing in this repo applies `argocd/apps/**` for you.** There is no app-of-apps root Application, and `sync-argocd.yml` only syncs Applications that *already exist* in the cluster. A new service's Application CR sits in git -- valid, reviewed, merged -- and is never created:

```
$ argocd app get ppc-service-staging
applications.argoproj.io "ppc-service-staging" not found
```

```bash
kubectl apply -f argocd/apps/staging/<service>.yaml
kubectl apply -f argocd/apps/production/<service>.yaml
```

A `metadata.finalizers` warning on apply is expected and harmless.

This bit `ppc-service` on 2026-07-29 in **both** environments. It is the same class of failure as Step 7: a correct artifact in git that nothing ever applies to the cluster.

### Step 9: Migrate IAM too -- the menu and permissions live in a DIFFERENT database

A service's own `<service>-setup.sh migrate` targets its own database and its own version table (e.g. `ppc_db` / `schema_migrations_ppc`). But the sidebar **menu entries, permissions and roles** are seeded by **IAM** migrations against the `goapps` database and `schema_migrations_iam` -- a different database *and* a different version table.

Skip this and the new pages load fine by direct URL while the sidebar stays permanently empty. That is exactly what happened to `ppc-service` on 2026-07-29 in both environments (IAM migrations `000079`-`000081`).

```bash
./scripts/iam-setup.sh goapps-staging migrate

kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps \
  -c "SELECT version, dirty FROM schema_migrations_iam;"   # verify by VERSION, not by script output
```

Verify by version number: `iam-setup.sh`'s `kubectl wait` derives its `component=` label from the job name, matches no pod, and burns its timeout masked by `|| true` -- the migration still runs, but the script's output tells you nothing.

If a seed migration widens a CHECK constraint via `DROP CONSTRAINT` + `ADD CONSTRAINT` (e.g. `chk_permission_action` to admit a new action verb), compare production's live definition against staging's **before** running it there -- a drifted production constraint would be replaced wholesale:

```bash
kubectl exec -it postgres-0 -n database -- psql -U <prod-user> -d <prod-db> -c \
  "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'chk_permission_action';"
```

Users with an existing session must log out and back in -- the sidebar comes from `useMenuTree()` and permissions resolve at session start.

### Step 10: Verify against the ORG repo, not your fork

Every ArgoCD Application tracks `repoURL: https://github.com/mutugading/goapps-infra.git`. If your local `origin` is a personal fork, **verifying `origin/main` proves nothing about what ArgoCD sees.** A merged-to-fork-only fix leaves the cluster reading the old, possibly broken manifest. Query the org directly:

```bash
# quote the URL -- an unquoted `?` is glob-expanded by zsh and gh fails with
# "no matches found", which reads as a false ABSENT
gh api "repos/mutugading/goapps-infra/contents/services/<service>/base/service.yaml?ref=main" \
  --jq '.content' | base64 -d
```

For files that ArgoCD Image Updater writes back to (`*/kustomization.yaml` `newTag`), do **not** trust `git diff a..b` -- the direction is easy to misread as an image rollback. Compare per side instead:

```bash
git show origin/main:services/<service>/overlays/staging/kustomization.yaml | grep newTag
git show HEAD:services/<service>/overlays/staging/kustomization.yaml | grep newTag
git log --oneline --date=short --format='%h %ad %s' -3 origin/main -- <path>   # newest wins
```

---

## 16. Emergency Procedures

### Pod CrashLoopBackOff

```bash
kubectl describe pod <pod> -n <namespace>       # Check events
kubectl logs <pod> -n <namespace>                # Current logs
kubectl logs <pod> -n <namespace> --previous     # Previous crash logs
kubectl top pod <pod> -n <namespace>             # Check for OOM
kubectl rollout undo deployment/<name> -n <namespace>  # Rollback
```

### Database Connection Issues

```bash
kubectl get pods -n database -l app=postgres     # Check PostgreSQL
kubectl get pods -n database -l app=pgbouncer    # Check PgBouncer
kubectl logs postgres-0 -n database --tail=100
kubectl logs deploy/pgbouncer -n database
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity"
```

### Dirty Migration Fix

If a migration fails and leaves the schema_migrations table dirty:

```bash
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "UPDATE schema_migrations_<service> SET dirty = false"
```

### Rollback Deployment

```bash
# Via kubectl
kubectl rollout undo deployment/<name> -n <namespace>
kubectl rollout undo deployment/<name> -n <namespace> --to-revision=2

# Via ArgoCD
argocd app rollback <app-name>
```

---

## 17. Operational Lessons Learned

These are hard-won lessons from production operations:

| Area | Lesson |
|------|--------|
| RabbitMQ | Needs minimum 500m CPU, 512Mi memory, 30s probe timeouts. Always add `startupProbe`. |
| Frontend (Next.js) | Minimum 500m CPU limit or pod will cycle continuously. **500m is the failure floor, not a target** -- both overlays now set 750m. A CPU limit is a throttling ceiling, not a scheduler reservation, so headroom above the floor costs no node allocatable. |
| Dirty migrations | Fix with `UPDATE schema_migrations_{service} SET dirty = false` in psql. |
| Migrate vs pg_dump locks | **Incident (prod)**: `finance-setup.sh ... migrate` hung -- the 06:00/14:00/22:00 `postgres-backup-*` CronJob's `pg_dump` held ACCESS SHARE locks, golang-migrate's `TRUNCATE schema_migrations_<svc>` queued for ACCESS EXCLUSIVE, and postgres-exporter/other queries piled up behind it; the script timed out at 120s while the Job kept running. **Guard**: all `services/*/base/migrate-job.yaml` set `options=-c lock_timeout=10s -c statement_timeout=0` on the direct-postgres DATABASE_URL (lib/pq passes `options` through; PgBouncer would NOT support it) so lock waits fail fast. `scripts/lib/db-guard.sh` (sourced by finance/iam/ppc-setup.sh) refuses to run *migrate* while a `postgres-backup-*` Job is active or a `pg_dump` session exists (`FORCE_MIGRATE=1` overrides, `WAIT_FOR_BACKUP=1` polls 30s up to 30m), migrate wait is 300s, and on failure prints Job/pod/log/`pg_stat_activity` diagnostics plus how to delete the still-running Job and check `schema_migrations_<svc>` dirty state. Seeds/backfills unchanged. |
| Old K8s Jobs | Failed Jobs from old CronJob runs trigger Grafana backup alerts. Delete stale jobs manually. A Job's pod spec is frozen at creation: Jobs created **before** an image fix keep pulling the old image forever -- delete them after the fix lands. |
| ArgoCD CLI | Requires port-forward first. Production has no CLI -- use the ArgoCD dashboard. |
| Kustomize commonLabels | Adding to existing deployments breaks them (immutable label selector). Only set on initial creation. |
| VPA CRD | Must be installed in the cluster before any VPA resource is referenced in `kustomization.yaml`. |
| Redis emptyDir | Data is lost on pod restart. Do not store anything that cannot be regenerated. |
| NetworkPolicies | Required by RULES.md but not yet implemented -- known gap. |
| ~~Backup CronJob env~~ | **Resolved.** The base sets `ENVIRONMENT=base`; `overlays/{staging,production}/backup/kustomization.yaml` patch it to `staging` / `production` (env index 0), and staging dumps are named `staging_*.sql.gz` (verified 2026-10-12). Applying the base without an overlay is still wrong (see "Backup path targeting"). |
| Pod Disruption Budgets | None defined -- needed for StatefulSets (PostgreSQL, RabbitMQ, MinIO) to survive node drains safely. |
| Resource Quotas | No per-namespace ResourceQuota resources -- risk of one namespace exhausting cluster resources. |
| Queue-driven HPA fan-out | `finance-cost-worker` scales on an **external** metric (RabbitMQ queue depth), so it can jump to `maxReplicas` with no CPU signal at all. At its old cap (base 50 / prod 20) x 768Mi it alone committed 15360Mi on a ~16Gi node. Memory **requests** for that fan-out are only ~5120Mi, so the scheduler admits every pod and the node OOM-kills instead -- which is how the 2026-08-13 incident took out Grafana in the `monitoring` namespace alongside the finance workers. Capped at prod 7 / staging 4. **Always multiply `maxReplicas x memory limit` against the node before merging an HPA.** |
| Memory limits vs requests | Node-wide memory *limits* are overcommitted to ~154% even after the fan-out fix. This is tolerable only because requests stay near 33%; do not read a healthy `kubectl describe node` requests figure as proof there is room. |
| ~~PostgreSQL ServiceMonitor~~ | **Resolved — this gap no longer exists.** `base/database/exporter/deployment.yaml` ships a `ServiceMonitor` named `postgres-exporter` (namespace `monitoring`, `namespaceSelector: database`, port `metrics`, interval 30s) alongside the Deployment and Service. |
| App service accounts | Workloads run under the default K8s service account -- no dedicated RBAC service accounts per app. |
| Backup path targeting (understated before) | Not merely a doc typo. The **effective** paths come from `overlays/{staging,production}/backup/kustomization.yaml`, which patch `hostPath` to `/staging-goapps-backup/postgres` and `/goapps-backup/postgres`. The **base** (`base/backup/cronjobs/postgres-backup.yaml:210,312,414`, `minio-backup.yaml:88`) still says `/mnt/goapps-backup` -- applying base **without** an overlay writes to a path that is not the mounted backup disk. `scripts/bootstrap.sh:82-84` also still mounts at `/mnt/goapps-backup` / `/mnt/stgapps-backup`, so a **newly bootstrapped host would reproduce the mismatch** even though the two existing hosts were fixed by hand. |
| Dead overlay files | `overlays/staging/backup-patch.yaml` and `overlays/production/backup-patch.yaml` are **not referenced by any kustomization** (the live patches are in `overlays/{staging,production}/backup/kustomization.yaml`). They are stale leftovers -- do not edit them expecting an effect; they are candidates for deletion. |
| RabbitMQ clustering | Single pod, no clustering -- SPOF for the message queue. |
| Jaeger storage | In-memory only (**5000** trace cap, `MEMORY_MAX_TRACES`) -- consider persistent storage for production. |
| Root-disk DiskPressure (2026-10-08) | Production root disk (77G) passed kubelet's ~15%-free eviction threshold. The node got a `disk-pressure` taint, pods were evicted and could not reschedule (single node), **ingress-nginx died**, and goapps/ArgoCD/Grafana all returned `ERR_CONNECTION_REFUSED` while MinIO (direct NodePort 30090) stayed up. Cause: all PVCs (`local-path`, `/var/lib/rancher/k3s/storage`) share the root disk, and the MinIO PVC held ~24G of redundant postgres dumps. Fix: stopped uploading dumps to MinIO (§10). Signature to recognise: `FreeDiskSpaceFailed ... only found 0 bytes eligible to free` events (image GC cannot help when PVC data is the cause). `du` on `/var` double-counts PVCs via the kubelet bind mounts -- measure `/var/lib/rancher/k3s/storage/*` with `sudo sh -c 'du -sh ...'`. Root disk was 57-65% afterwards; Postgres PVC is 14G of 20Gi and growing. No disk alert exists yet. |
| MinIO images gone from public registries (2026-10-08..12) | See §8 "Image Pull" / §10 "MinIO image source". The DiskPressure GC above evicted the cached `minio/mc`, so all postgres backup Jobs stuck in `Init:ImagePullBackOff`; with `Forbid` they blocked every schedule and production had **no backup for 3 days**. The interim `quay.io` repoint also failed (401). Fixed by the ghcr mirror + the CronJob deadlines in §10. |
| Catch-up runs collide (2026-10-12) | Deleting the stuck Jobs released all three missed postgres schedules in the **same second**; they wrote one `..._063750.sql.gz` and corrupted it (`gzip: invalid compressed data`). Fixed by `startingDeadlineSeconds` + the pod-hash filename suffix (§10). |
| MinIO / ingress TLS | Wildcard `*.mutugading.com` (Sectigo) renewed 2026-10, `notAfter` **2027-02-12**. Procedure: `docs/runbooks/ssl-renewal.md`. `minio-tls` uses keys `public.crt`/`private.key` (generic secret), not `tls.crt`/`tls.key`. Verify MinIO on 30090 **and** 30091; `mc` "certificate will expire" warnings in an old Job log predate the MinIO pod restart and are not current. |
