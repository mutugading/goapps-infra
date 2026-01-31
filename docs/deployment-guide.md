# VPS Deployment Guide

Step-by-step untuk reset dan deploy ulang K3s cluster dari awal.

## Prerequisites

Di VPS (staging/production):
- Ubuntu 22.04 LTS
- SSH access dengan root/sudo
- Disk partitions sudah ready:
  - `/dev/sdb` → backup partition (opsional, tapi recommended)

Di local machine:
- Git repo `goapps-infra` sudah di-push ke GitHub

---

## Step 1: Reset K3s (Jika Ada Instalasi Lama)

```bash
# SSH ke VPS
ssh user@vps-ip

# Cek apakah K3s sudah terinstall
which k3s

# Jika ada, jalankan uninstall script
sudo /usr/local/bin/k3s-uninstall.sh

# Verifikasi sudah bersih
ls /var/lib/rancher  # Harusnya: No such file or directory
ls /etc/rancher       # Harusnya: No such file or directory
```

---

## Step 2: Clone Repository

```bash
# Clone goapps-infra
cd ~
git clone https://github.com/mutugading/goapps-infra.git
cd goapps-infra

# Pastikan scripts executable
chmod +x scripts/*.sh
```

---

## Step 3: Bootstrap K3s Cluster

```bash
# Jalankan bootstrap (install K3s, Helm, namespaces)
./scripts/bootstrap.sh

# Tunggu sampai selesai, verifikasi:
kubectl get nodes
# NAME    STATUS   ROLES                  AGE   VERSION
# vps-1   Ready    control-plane,master   1m    v1.xx.x

kubectl get namespaces
# NAME              STATUS   AGE
# database          Active   1m
# monitoring        Active   1m
# minio             Active   1m
# goapps-staging    Active   1m   (atau goapps-production)
```

---

## Step 4: Create Secrets (MANUAL - Tidak di Git!)

### Database Secrets (namespace: database)

```bash
# PostgreSQL
kubectl create secret generic postgres-secret \
  --namespace=database \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD='YOUR_SECURE_PASSWORD' \
  --from-literal=POSTGRES_DB=goapps

# MinIO
kubectl create secret generic minio-secret \
  --namespace=minio \
  --from-literal=MINIO_ROOT_USER=minioadmin \
  --from-literal=MINIO_ROOT_PASSWORD='YOUR_MINIO_PASSWORD'

# Copy minio-secret ke namespace database (untuk backup jobs)
kubectl get secret minio-secret -n minio -o yaml | \
  sed 's/namespace: minio/namespace: database/' | \
  kubectl apply -f -

# Backblaze B2 (untuk PostgreSQL backup ke cloud)
kubectl create secret generic s3-cloud-credentials \
  --namespace=database \
  --from-literal=S3_ENDPOINT='s3.us-west-004.backblazeb2.com' \
  --from-literal=S3_BUCKET='goapps-backups' \
  --from-literal=AWS_ACCESS_KEY_ID='YOUR_B2_KEY_ID' \
  --from-literal=AWS_SECRET_ACCESS_KEY='YOUR_B2_APP_KEY'
```

### Verifikasi Secrets

```bash
kubectl get secrets -n database
kubectl get secrets -n minio
```

---

## Step 5: Install Monitoring Stack

```bash
# Install Prometheus, Grafana, Loki
./scripts/install-monitoring.sh

# Tunggu semua pods ready
kubectl get pods -n monitoring -w

# Setelah semua Running, akses Grafana:
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80

# Buka browser: http://localhost:3000
# Login: admin / (password dari script output)
```

---

## Step 6: Install ArgoCD (GitOps)

```bash
# Install ArgoCD
./scripts/install-argocd.sh

# Catat password yang muncul di output!

# Akses ArgoCD UI:
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Buka browser: https://localhost:8080
# Login: admin / (password dari script output)
```

---

## Step 7: Apply Base Infrastructure

```bash
# Apply semua base configs (database, backup, etc)
make apply-base

# Atau manual:
kubectl apply -k base/namespaces/
kubectl apply -k base/database/
kubectl apply -k base/backup/

# Apply alert rules
kubectl apply -f base/monitoring/alert-rules/
```

### Verifikasi Database

```bash
# Tunggu PostgreSQL ready
kubectl get pods -n database -w

# Cek PostgreSQL berjalan
kubectl logs statefulset/postgres -n database

# Test koneksi
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c "SELECT 1"

# Cek schemas sudah dibuat
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c "\dn"
# Harusnya ada: export, auth, hr, finance
```

---

## Step 8: Apply ArgoCD Applications

```bash
# Apply ArgoCD apps (mereka akan auto-sync dari Git)
kubectl apply -f argocd/apps/

# Cek status di ArgoCD UI atau:
kubectl get applications -n argocd
```

---

## Step 9: Deploy Finance Service

### Option A: Via ArgoCD (Recommended)

ArgoCD sudah auto-sync dari Git. Cek status:

```bash
kubectl get applications -n argocd
# finance-service-staging   Synced   Healthy
```

### Option B: Manual Deployment

```bash
# Staging
kubectl apply -k services/finance-service/overlays/staging/

# Production
kubectl apply -k services/finance-service/overlays/production/
```

### Verifikasi Service

```bash
# Cek pods
kubectl get pods -n goapps-staging
kubectl get pods -n goapps-production

# Cek services
kubectl get svc -n goapps-staging
kubectl get svc -n goapps-production

# Cek HPA
kubectl get hpa -n goapps-staging
```

---

## Step 10: Setup Ingress (Opsional)

Jika menggunakan domain:

```bash
# Install Traefik (K3s sudah include) atau custom Ingress
# Contoh: nginx-ingress

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

---

## Step 11: Verifikasi Final

### Checklist

- [ ] K3s cluster running: `kubectl get nodes`
- [ ] All namespaces created: `kubectl get ns`
- [ ] PostgreSQL running: `kubectl get pods -n database`
- [ ] MinIO running: `kubectl get pods -n minio`
- [ ] PgBouncer running: `kubectl get pods -n database`
- [ ] Prometheus/Grafana running: `kubectl get pods -n monitoring`
- [ ] ArgoCD running: `kubectl get pods -n argocd`
- [ ] Finance service deployed: `kubectl get pods -n goapps-staging`
- [ ] Backup CronJobs scheduled: `kubectl get cronjobs -n database`
- [ ] Alert rules imported: Check Grafana Alerting

### Test Backup Manual

```bash
# Trigger PostgreSQL backup manually
kubectl create job --from=cronjob/postgres-backup-morning \
  postgres-backup-test-$(date +%Y%m%d%H%M%S) -n database

# Check job status
kubectl get jobs -n database
kubectl logs job/postgres-backup-test-xxx -n database
```

---

## Troubleshooting

### Pod tidak start
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### PostgreSQL connection refused
```bash
# Cek PostgreSQL running
kubectl get pods -n database
# Cek service
kubectl get svc -n database
# Test dari dalam cluster
kubectl run test-pg --rm -it --image=postgres:18-alpine -- \
  psql -h postgres.database.svc.cluster.local -U postgres -d goapps
```

### ArgoCD sync failed
```bash
# Cek app status
argocd app get <app-name>
# Force sync
argocd app sync <app-name> --force
```

### Backup failed
```bash
# Cek CronJob
kubectl describe cronjob postgres-backup-morning -n database
# Cek recent job logs
kubectl logs job/postgres-backup-morning-xxx -n database
```

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `make status` | Cluster overview |
| `make logs-postgres` | PostgreSQL logs |
| `make backup-now` | Manual backup trigger |
| `make port-forward-grafana` | Access Grafana locally |
| `make port-forward-argocd` | Access ArgoCD locally |

---

## Staging vs Production

| Aspect | Staging | Production |
|--------|---------|------------|
| VPS | 4 core, 8GB | 8 core, 16GB |
| Namespace | goapps-staging | goapps-production |
| Replicas | 1 | 2+ |
| ArgoCD Sync | Auto | Manual (safety) |
| Domain | staging.goapps.mutugading.com | goapps.mutugading.com |

---

## Backup Strategy Summary

| Target | Destination | Schedule | Retention |
|--------|-------------|----------|-----------|
| PostgreSQL | MinIO | 3x daily | 7 days |
| PostgreSQL | Backblaze B2 | 3x daily | 7 days |
| PostgreSQL | VPS disk | 3x daily | 7 days |
| MinIO | VPS disk only | Daily | 7 days |
