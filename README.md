# goapps-infra

Infrastructure as Code for Go Apps Microservices Platform.

## Overview

This repository contains all Kubernetes manifests, Helm values, and scripts for deploying and managing the goapps platform on K3s clusters.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      ArgoCD (GitOps)                        │
│                 Watches this repo & syncs                   │
└─────────────────────────────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│    Staging    │   │  Production   │   │  Monitoring   │
│   Namespace   │   │   Namespace   │   │   Namespace   │
├───────────────┤   ├───────────────┤   ├───────────────┤
│ finance-svc   │   │ finance-svc   │   │ Prometheus    │
│ (future svcs) │   │ (future svcs) │   │ Grafana       │
└───────────────┘   └───────────────┘   │ Loki          │
        │                    │          │ Alertmanager  │
        └────────────────────┼──────────┴───────────────┘
                             ▼
                    ┌───────────────┐
                    │   Database    │
                    │   Namespace   │
                    ├───────────────┤
                    │ PostgreSQL 18 │
                    │ PgBouncer     │
                    │ MinIO         │
                    └───────────────┘
```

## Quick Start

### Prerequisites
- K3s cluster (staging/production VPS)
- kubectl configured
- Helm 3.x installed

### Bootstrap New Cluster

```bash
# 1. Install K3s
curl -sfL https://get.k3s.io | sh -

# 2. Run bootstrap script
./scripts/bootstrap.sh

# 3. Install monitoring stack
./scripts/install-monitoring.sh

# 4. Install ArgoCD (GitOps)
./scripts/install-argocd.sh

# 5. Apply ArgoCD apps (auto-sync from Git)
kubectl apply -f argocd/apps/
```

### Manual Deployment (without ArgoCD)

```bash
# Apply base configs
kubectl apply -k base/namespaces/
kubectl apply -k base/database/
kubectl apply -k base/backup/

# Apply service for staging
kubectl apply -k services/finance-service/overlays/staging/
```

## Directory Structure

```
goapps-infra/
├── base/                    # Shared Kustomize bases
│   ├── namespaces/          # K8s namespaces
│   ├── database/            # PostgreSQL, PgBouncer, Exporter
│   ├── backup/              # MinIO, CronJobs
│   └── monitoring/          # Helm values, dashboards, alerts
│
├── overlays/                # Environment-specific patches
│   ├── staging/             # 4 core, 8GB RAM
│   └── production/          # 8 core, 16GB RAM
│
├── services/                # Application deployments
│   └── finance-service/
│       ├── base/
│       └── overlays/{staging,production}
│
├── argocd/                  # GitOps configuration
│   ├── apps/                # ArgoCD Application manifests
│   └── projects/            # ArgoCD Projects
│
├── scripts/                 # Automation scripts
│   ├── bootstrap.sh         # Initial cluster setup
│   ├── reset-k3s.sh         # Clean reset VPS
│   ├── install-monitoring.sh
│   └── install-argocd.sh
│
└── docs/                    # Documentation
    ├── setup-guide.md
    ├── backup-restore.md
    └── argocd-guide.md
```

## Environments

| Environment | VPS Specs | Domain | ArgoCD Sync |
|-------------|-----------|--------|-------------|
| Staging | 4 core, 8GB | staging.goapps.mutugading.com | Auto |
| Production | 8 core, 16GB | goapps.mutugading.com | Manual* |

*Production requires manual sync approval for safety.

## Backup Strategy

| Target | Destination | Schedule | Retention |
|--------|-------------|----------|-----------|
| PostgreSQL | MinIO | 3x daily (06:00, 14:00, 22:00) | 7 days |
| PostgreSQL | Backblaze B2 | 3x daily | 7 days |
| PostgreSQL | VPS disk (`/mnt/goapps-backup`) | 3x daily | 7 days |
| MinIO | VPS disk only | Daily (03:00) | 7 days |

> **Note**: MinIO tidak di-backup ke Backblaze karena free tier storage limit.

## Monitoring

- **Grafana**: Dashboards for apps and database
- **Prometheus**: Metrics collection (30-day retention)
- **Loki**: Log aggregation
- **Alertmanager**: Email notifications

### Alert Categories
- Node health (CPU, Memory, Disk)
- Pod status (CrashLoop, restarts)
- HPA scaling
- PVC storage
- PostgreSQL health
- Backup status

## Adding New Service

See [RULES.md](./RULES.md) for step-by-step guide.

```bash
# 1. Create service directory
mkdir -p services/new-service/{base,overlays/{staging,production}}

# 2. Add manifests (copy from finance-service as template)
cp -r services/finance-service/base/* services/new-service/base/

# 3. Update kustomization.yaml with new image/name

# 4. Add ArgoCD Application
cp argocd/apps/finance-service.yaml argocd/apps/new-service.yaml

# 5. Commit and push (ArgoCD auto-syncs)
git add . && git commit -m "feat: add new-service" && git push
```

## Scripts Reference

| Script | Description |
|--------|-------------|
| `bootstrap.sh` | Initial K3s cluster setup |
| `reset-k3s.sh` | Uninstall K3s and clean all data |
| `install-monitoring.sh` | Install Prometheus/Grafana/Loki via Helm |
| `install-argocd.sh` | Install and configure ArgoCD |
| `k8s-health-check.sh` | Cluster health monitoring |

## Secrets Management

Secrets are NOT stored in this repo. Apply manually:

```bash
# Database
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --from-literal=POSTGRES_DB=goapps \
  -n database

# Backup (Backblaze)
kubectl create secret generic s3-cloud-credentials \
  --from-literal=S3_ENDPOINT=<endpoint> \
  --from-literal=S3_BUCKET=<bucket> \
  --from-literal=AWS_ACCESS_KEY_ID=<key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret> \
  -n database
```

## License

Internal use only - Mutugading.
