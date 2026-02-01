# VPS Reset Guide - Step by Step

## Overview

Panduan ini akan memandu Anda untuk:
1. Reset K3s cluster (jika ada instalasi lama)
2. Install K3s fresh
3. Deploy semua infrastructure dari goapps-infra
4. Verifikasi semua berjalan dengan baik

**Waktu yang dibutuhkan:** ~30-45 menit per VPS

---

## Prerequisites

Pastikan Anda memiliki:
- SSH access ke VPS staging dan production
- SSL certificates (`ssl-bundle.crt`, `ssl-bundle.key`)
- Kredensial Oracle, PostgreSQL, MinIO, dll.

---

# STAGING VPS

## Step 1: Login SSH

```bash
ssh deploy@staging-goapps.mutugading.com
# atau
ssh deploy@<IP_STAGING>
```

---

## Step 2: Cek Status K3s Lama (Jika Ada)

```bash
# Cek apakah K3s terinstall
which k3s
sudo systemctl status k3s

# Lihat pods yang running
sudo kubectl get pods -A
```

---

## Step 3: Reset K3s (Uninstall)

```bash
# Stop K3s service
sudo systemctl stop k3s

# Jalankan uninstall script
sudo /usr/local/bin/k3s-uninstall.sh

# Verifikasi sudah bersih
ls /var/lib/rancher    # Harusnya: No such file or directory
ls /etc/rancher        # Harusnya: No such file or directory
sudo docker ps         # Harusnya tidak ada container k3s
```

> **Catatan:** Jika ada error "k3s-uninstall.sh not found", berarti K3s belum terinstall.

---

## Step 4: Siapkan Backup Directory

```bash
# Buat direktori backup untuk staging
sudo mkdir -p /staging-goapps-backup/postgres
sudo mkdir -p /staging-goapps-backup/minio
sudo chown -R $USER:$USER /staging-goapps-backup
```

---

## Step 5: Clone Repository

```bash
cd ~
rm -rf goapps-infra  # Hapus jika ada clone lama
git clone https://github.com/mutugading/goapps-infra.git
cd goapps-infra

# Pastikan scripts executable
chmod +x scripts/*.sh
```

---

## Step 6: Bootstrap K3s

```bash
# Jalankan bootstrap script
./scripts/bootstrap.sh

# Tunggu ~2-3 menit sampai selesai
# Script akan:
# - Install K3s v1.31.x
# - Install Helm
# - Create namespaces (database, monitoring, minio, go-apps, argocd, observability)
```

### Verifikasi Bootstrap

```bash
# Cek node status
kubectl get nodes
# Output: node Ready

# Cek namespaces
kubectl get ns
# Output: database, monitoring, minio, go-apps, argocd, observability, dll.
```

---

## Step 7: Create Secrets

**PENTING:** Secrets TIDAK boleh ada di Git!

### PostgreSQL Secret

```bash
kubectl create secret generic postgres-secret -n database \
  --from-literal=POSTGRES_USER=goapps_admin \
  --from-literal=POSTGRES_PASSWORD='<PASSWORD_ANDA>' \
  --from-literal=POSTGRES_DB=goapps
```

### MinIO Secret

```bash
kubectl create secret generic minio-secret -n minio \
  --from-literal=MINIO_ROOT_USER=admin \
  --from-literal=MINIO_ROOT_PASSWORD='<PASSWORD_ANDA>'

# Copy ke namespace database (untuk backup)
kubectl get secret minio-secret -n minio -o yaml | \
  sed 's/namespace: minio/namespace: database/' | \
  kubectl apply -f -
```

### RabbitMQ Secret

```bash
kubectl create secret generic rabbitmq-secret -n database \
  --from-literal=RABBITMQ_USER=goapps \
  --from-literal=RABBITMQ_PASSWORD='<PASSWORD_ANDA>'
```

### Oracle Credentials

```bash
kubectl create secret generic oracle-credentials -n go-apps \
  --from-literal=ORACLE_HOST='<ORACLE_IP>' \
  --from-literal=ORACLE_PORT='1521' \
  --from-literal=ORACLE_SERVICE='ORCLPDB1' \
  --from-literal=ORACLE_MGTHRIS_USER='mgthris' \
  --from-literal=ORACLE_MGTHRIS_PASSWORD='<PASSWORD>' \
  --from-literal=ORACLE_MGTAPPS_USER='mgtapps' \
  --from-literal=ORACLE_MGTAPPS_PASSWORD='<PASSWORD>' \
  --from-literal=ORACLE_MGTDAT_USER='mgtdat' \
  --from-literal=ORACLE_MGTDAT_PASSWORD='<PASSWORD>'
```

### TLS Secret (SSL Certificate)

```bash
# Upload SSL files ke VPS dulu, lalu:
kubectl create secret tls goapps-tls -n monitoring \
  --cert=ssl-bundle.crt \
  --key=ssl-bundle.key

# Copy ke namespace lain
for ns in argocd ingress-nginx go-apps; do
  kubectl create ns $ns 2>/dev/null || true
  kubectl get secret goapps-tls -n monitoring -o yaml | \
    sed "s/namespace: monitoring/namespace: $ns/" | \
    kubectl apply -f -
done
```

### Grafana & SMTP Secret

```bash
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<PASSWORD>'

kubectl create secret generic grafana-smtp-secret -n monitoring \
  --from-literal=password='<SMTP_PASSWORD>'
```

### GitHub Container Registry (GHCR)

```bash
kubectl create secret docker-registry ghcr-secret -n go-apps \
  --docker-server=ghcr.io \
  --docker-username='<GITHUB_USERNAME>' \
  --docker-password='<GITHUB_TOKEN>'
```

### Prometheus Basic Auth (untuk Production)

```bash
# Generate htpasswd (ganti USERNAME dan PASSWORD)
htpasswd -c auth prometheus_admin
# atau manual:
echo "prometheus_admin:$(openssl passwd -apr1 'PASSWORD')" > auth

kubectl create secret generic prometheus-basic-auth -n monitoring \
  --from-file=auth
rm auth
```

### Verifikasi Secrets

```bash
kubectl get secrets -n database
kubectl get secrets -n minio
kubectl get secrets -n monitoring
kubectl get secrets -n go-apps
```

---

## Step 8: Install Monitoring Stack

```bash
# Set Grafana password (REQUIRED - script will fail without this)
export GRAFANA_PASSWORD='<YOUR_SECURE_PASSWORD>'

./scripts/install-monitoring.sh

# Tunggu ~5 menit
# Script akan install:
# - Prometheus + Grafana (kube-prometheus-stack)
# - Loki + Promtail (loki-stack)

# Monitor progress:
kubectl get pods -n monitoring -w
```

### Verifikasi Monitoring

```bash
# Semua pods harus Running
kubectl get pods -n monitoring

# Cek Grafana
kubectl get svc -n monitoring | grep grafana
```

---

## Step 9: Apply Base Infrastructure

```bash
# Apply database components
kubectl apply -k base/database/

# Tunggu PostgreSQL ready
kubectl get pods -n database -w

# Apply backup CronJobs
kubectl apply -k base/backup/

# Apply Kubernetes Dashboard admin
kubectl apply -k base/kubernetes-dashboard/

# Apply observability (Jaeger)
kubectl apply -k base/observability/

# Apply alert rules
kubectl apply -f base/monitoring/alert-rules/

# Apply dashboards
kubectl apply -f base/monitoring/dashboards/
```

### Verifikasi Database Layer

```bash
# PostgreSQL
kubectl get pods -n database -l app=postgres
kubectl logs -n database statefulset/postgres --tail=20

# PgBouncer
kubectl get pods -n database -l app=pgbouncer

# Redis
kubectl get pods -n database -l app=redis

# RabbitMQ
kubectl get pods -n database -l app=rabbitmq
```

---

## Step 10: Install ArgoCD

```bash
./scripts/install-argocd.sh

# Tunggu ArgoCD ready
kubectl get pods -n argocd -w

# Catat password yang muncul!
```

### Get ArgoCD Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
```

---

## Step 11: Apply ArgoCD Applications

```bash
kubectl apply -f argocd/apps/
kubectl apply -f argocd/projects/

# Cek status
kubectl get applications -n argocd
```

---

## Step 12: Apply Ingress (Staging)

```bash
kubectl apply -f overlays/staging/ingress.yaml
```

---

## Step 13: Verifikasi Final

### Checklist

```bash
echo "=== NODE STATUS ==="
kubectl get nodes

echo "=== NAMESPACES ==="
kubectl get ns

echo "=== DATABASE PODS ==="
kubectl get pods -n database

echo "=== MONITORING PODS ==="
kubectl get pods -n monitoring

echo "=== ARGOCD PODS ==="
kubectl get pods -n argocd

echo "=== OBSERVABILITY PODS ==="
kubectl get pods -n observability

echo "=== MINIO PODS ==="
kubectl get pods -n minio

echo "=== CRONJOBS ==="
kubectl get cronjobs -n database

echo "=== SERVICES ==="
kubectl get svc -A

echo "=== INGRESS ==="
kubectl get ingress -A
```

### Test PostgreSQL

```bash
kubectl exec -it postgres-0 -n database -- psql -U goapps_admin -d goapps -c "SELECT 1"
```

### Test Redis

```bash
kubectl exec -it deploy/redis -n database -- redis-cli ping
# Output: PONG
```

### Access Grafana (Port Forward)

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Buka browser: http://localhost:3000
# Login: admin / <GRAFANA_PASSWORD>
```

### Access ArgoCD (Port Forward)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Buka browser: https://localhost:8080
# Login: admin / <ARGOCD_PASSWORD>
```

---

## Step 14: Deploy Finance Service

Setelah infrastructure ready:

```bash
kubectl apply -k services/finance-service/overlays/staging/

# Monitor
kubectl get pods -n go-apps -w
kubectl get hpa -n go-apps
```

---

# PRODUCTION VPS

Ulangi langkah yang sama dengan perbedaan:

| Item | Staging | Production |
|------|---------|------------|
| Backup dir | `/staging-goapps-backup` | `/goapps-backup` |
| Ingress file | `overlays/staging/ingress.yaml` | `overlays/production/ingress.yaml` |
| Prometheus | No auth | Basic Auth |
| Service overlay | `staging` | `production` |

```bash
# Login production
ssh deploy@goapps.mutugading.com

# Backup directory production
sudo mkdir -p /goapps-backup/postgres
sudo mkdir -p /goapps-backup/minio

# Apply production ingress
kubectl apply -f overlays/production/ingress.yaml

# Deploy finance service production
kubectl apply -k services/finance-service/overlays/production/
```

---

# Troubleshooting

## Pod tidak start

```bash
kubectl describe pod <POD_NAME> -n <NAMESPACE>
kubectl logs <POD_NAME> -n <NAMESPACE>
```

## PostgreSQL connection refused

```bash
# Cek service
kubectl get svc -n database
# Test dari dalam cluster
kubectl run test-pg --rm -it --image=postgres:18-alpine -- \
  psql -h postgres.database -U goapps_admin -d goapps
```

## K3s tidak start setelah reboot

```bash
sudo systemctl start k3s
sudo systemctl enable k3s
```

## Reset password ArgoCD

```bash
kubectl -n argocd patch secret argocd-initial-admin-secret \
  -p '{"data": {"password": "'$(echo -n 'newpassword' | base64)'"}}'
```

---

# Quick Reference

| Service | Access |
|---------|--------|
| Grafana | `https://[staging-]goapps.mutugading.com/grafana` |
| Prometheus | `https://[staging-]goapps.mutugading.com/prometheus` |
| ArgoCD | `https://[staging-]goapps.mutugading.com/argocd` |
| K8s Dashboard | `kubectl proxy` → `http://localhost:8001/...` |
