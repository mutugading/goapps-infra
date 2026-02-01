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

> **Note:** Backup directory sudah di-mount ke disk terpisah (/dev/sdb1, ~60GB):
> - **Staging VPS**: `/staging-goapps-backup`
> - **Production VPS**: `/goapps-backup`

### Untuk Staging VPS:

```bash
# Verify disk mount
df -h /staging-goapps-backup
# Expected: /dev/sdb1  59G  24K  56G  1% /staging-goapps-backup

# Buat subdirektori backup
sudo mkdir -p /staging-goapps-backup/postgres
sudo mkdir -p /staging-goapps-backup/minio
sudo chown -R $USER:$USER /staging-goapps-backup
```

### Untuk Production VPS:

```bash
# Verify disk mount
df -h /goapps-backup
# Expected: /dev/sdb1  59G  24K  56G  1% /goapps-backup

# Buat subdirektori backup
sudo mkdir -p /goapps-backup/postgres
sudo mkdir -p /goapps-backup/minio
sudo chown -R $USER:$USER /goapps-backup
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
# STAGING VPS - jalankan:
./scripts/bootstrap.sh

# PRODUCTION VPS - jalankan dengan ENVIRONMENT=production:
ENVIRONMENT=production ./scripts/bootstrap.sh

# Tunggu ~2-3 menit sampai selesai
# Script akan:
# - Install K3s v1.34.x
# - Install Helm
# - Create namespaces:
#   - Staging: database, monitoring, minio, argocd, goapps-staging
#   - Production: database, monitoring, minio, argocd, goapps-production
```

> ⚠️ **PENTING:** Jika lupa set ENVIRONMENT=production di production VPS, buat namespace manual:
> ```bash
> kubectl create namespace goapps-production
> ```

### Verifikasi Bootstrap

```bash
# Cek node status
kubectl get nodes
# Output: node Ready

# Cek namespaces
kubectl get ns
# Output: database, monitoring, minio, goapps-staging, argocd, observability, dll.
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
# For staging:
kubectl create secret generic oracle-credentials -n goapps-staging \
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


```bash
# For Prod:
kubectl create secret generic oracle-credentials -n goapps-production \
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

```bash
# Future add schema (delete and recreate):
kubectl delete secret oracle-credentials -n goapps-staging
kubectl create secret generic oracle-credentials -n goapps-staging \
  --from-literal=ORACLE_HOST='<ORACLE_IP>' \
  --from-literal=ORACLE_PORT='1521' \
  --from-literal=ORACLE_SERVICE='ORCLPDB1' \
  --from-literal=ORACLE_MGTHRIS_USER='mgthris' \
  --from-literal=ORACLE_MGTHRIS_PASSWORD='<PASSWORD>' \
  --from-literal=ORACLE_MGTAPPS_USER='mgtapps' \
  --from-literal=ORACLE_MGTAPPS_PASSWORD='<PASSWORD>' \
  --from-literal=ORACLE_MGTDAT_USER='mgtdat' \
  --from-literal=ORACLE_MGTDAT_PASSWORD='<PASSWORD>' \
  --from-literal=ORACLE_MGTFIN_USER='mgtfin' \
  --from-literal=ORACLE_MGTFIN_PASSWORD='<PASSWORD>'
# Note: Tambahkan semua schema yang diperlukan
```

### TLS Secret (SSL Certificate)

```bash
# Siapkan SSL files (cert + private key):

# File yang dibutuhkan:
# - ssl-bundle.crt     = Certificate bundle (chain)
# - mutugading.com.key = Private key

# Dari desktop Linux Anda, jalankan:
# Untuk STAGING
scp /home/hom/Documents/SSL-2025-20251115T013232Z-1-001/SSL-2025/SSL-2025/STAR_mutugading_com/ssl-bundle.crt \
    /home/hom/Documents/SSL-2025-20251115T013232Z-1-001/SSL-2025/SSL-2025/STAR_mutugading_com/mutugading.com.key \
    deploy@staging-goapps.mutugading.com:~/

# Untuk PRODUCTION
scp /home/hom/Documents/SSL-2025-20251115T013232Z-1-001/SSL-2025/SSL-2025/STAR_mutugading_com/ssl-bundle.crt \
    /home/hom/Documents/SSL-2025-20251115T013232Z-1-001/SSL-2025/SSL-2025/STAR_mutugading_com/mutugading.com.key \
    deploy@goapps.mutugading.com:~/
```

```bash
# STAGING VPS - SSH ke staging, lalu:

# Verifikasi file terlebih dahulu
ls -la $HOME/ssl-bundle.crt $HOME/mutugading.com.key

kubectl create secret tls goapps-tls -n monitoring \
  --cert=$HOME/ssl-bundle.crt \
  --key=$HOME/mutugading.com.key

# Copy ke namespace lain (STAGING)
APP_NS="goapps-staging"
for ns in argocd ingress-nginx $APP_NS kubernetes-dashboard; do
  kubectl create ns $ns 2>/dev/null || true
  kubectl get secret goapps-tls -n monitoring -o yaml | \
    sed "s/namespace: monitoring/namespace: $ns/" | \
    kubectl apply -f -
done

# Cleanup file SSL (untuk keamanan)
rm $HOME/ssl-bundle.crt $HOME/mutugading.com.key
```

```bash
# PRODUCTION VPS - SSH ke production, lalu:

# Verifikasi file terlebih dahulu
ls -la $HOME/ssl-bundle.crt $HOME/mutugading.com.key

kubectl create secret tls goapps-tls -n monitoring \
  --cert=$HOME/ssl-bundle.crt \
  --key=$HOME/mutugading.com.key

# Copy ke namespace lain (PRODUCTION)
APP_NS="goapps-production"
for ns in argocd ingress-nginx $APP_NS kubernetes-dashboard; do
  kubectl create ns $ns 2>/dev/null || true
  kubectl get secret goapps-tls -n monitoring -o yaml | \
    sed "s/namespace: monitoring/namespace: $ns/" | \
    kubectl apply -f -
done

# Cleanup file SSL (untuk keamanan)
rm $HOME/ssl-bundle.crt $HOME/mutugading.com.key
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
# For staging (use goapps-production for production VPS):

# STAGING VPS
kubectl create secret docker-registry ghcr-secret -n goapps-staging \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_USERNAME> \
  --docker-password=<GITHUB_PAT_TOKEN>

# PRODUCTION VPS
kubectl create secret docker-registry ghcr-secret -n goapps-production \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_USERNAME> \
  --docker-password=<GITHUB_PAT_TOKEN>
```

### Prometheus Basic Auth (untuk Staging & Production)

```bash
# Install htpasswd jika belum ada
sudo apt install apache2-utils -y

# STAGING VPS - Generate htpasswd
# Use bcrypt for stronger password hashing (you will be prompted for the password):
htpasswd -nBC 10 prometheus_admin > auth

kubectl create secret generic prometheus-basic-auth -n monitoring \
  --from-file=auth
rm auth
```

```bash
# PRODUCTION VPS - Generate htpasswd
# Use bcrypt for stronger password hashing (you will be prompted for the password):
htpasswd -nBC 10 prometheus_admin > auth

kubectl create secret generic prometheus-basic-auth -n monitoring \
  --from-file=auth
rm auth
```

> **Note:** Password untuk staging dan production HARUS berbeda untuk keamanan.

### Verifikasi Secrets

```bash
kubectl get secrets -n database
kubectl get secrets -n minio
kubectl get secrets -n monitoring
kubectl get secrets -n goapps-staging    # For staging VPS
# kubectl get secrets -n goapps-production  # For production VPS
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

# Apply backup & MinIO CronJobs
kubectl apply -k base/backup/

# Apply Kubernetes Dashboard admin
kubectl apply -k base/kubernetes-dashboard/

# Apply alert rules (menggunakan kustomize)
kubectl apply -k base/monitoring/alert-rules/
```

### Step 9.1: Create PostgreSQL Role untuk Exporter

> **PENTING:** Tanpa role `postgres`, monitoring exporter tidak bisa collect metrics!

```bash
# STAGING VPS - ganti <PASSWORD> dengan password postgres secret Anda
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps -c \
  "CREATE ROLE postgres LOGIN SUPERUSER PASSWORD '<POSTGRES_PASSWORD>';"

# PRODUCTION VPS - ganti <PASSWORD> dengan password postgres secret Anda
kubectl exec -it postgres-0 -n database -- psql -U goapps -d goapps -c \
  "CREATE ROLE postgres LOGIN SUPERUSER PASSWORD '<POSTGRES_PASSWORD>';"
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

> **Note:** Jika RabbitMQ menunjukkan 0/1 Ready tapi logs normal, itu karena readiness probe timeout.
> Fix dengan: `kubectl rollout restart statefulset rabbitmq -n database`

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

## Step 12: Install NGINX Ingress Controller

> **PENTING:** K3s menggunakan Traefik sebagai default ingress controller, tetapi konfigurasi ingress kita menggunakan NGINX. Anda HARUS install NGINX Ingress Controller terlebih dahulu!

```bash
# Install NGINX Ingress Controller
./scripts/install-nginx-ingress.sh

# Tunggu sampai controller ready
kubectl get pods -n ingress-nginx

# Verifikasi service mendapat External IP
kubectl get svc -n ingress-nginx
# Output: ingress-nginx-controller dengan External IP atau LoadBalancer
```

### Copy TLS Secret ke ingress-nginx namespace

```bash
kubectl get secret goapps-tls -n monitoring -o yaml | \
  sed 's/namespace: monitoring/namespace: ingress-nginx/' | \
  kubectl apply -f -
```

---

## Step 13: Apply Ingress

### Untuk STAGING VPS:

```bash
kubectl apply -f overlays/staging/ingress.yaml

# Verifikasi ingress
kubectl get ingress -A
```

Akses via browser (setelah DNS pointing):
- Grafana: `https://staging-goapps.mutugading.com/grafana`
- Prometheus: `https://staging-goapps.mutugading.com/prometheus`
- ArgoCD: `https://staging-goapps.mutugading.com/argocd`

### Untuk PRODUCTION VPS:

> ⚠️ **PENTING:** Jangan apply ingress staging di production! Gunakan file yang benar:

```bash
kubectl apply -f overlays/production/ingress.yaml

# Verifikasi ingress
kubectl get ingress -A
```

Akses via browser (setelah DNS pointing):
- Grafana: `https://goapps.mutugading.com/grafana`
- Prometheus: `https://goapps.mutugading.com/prometheus` (dengan Basic Auth)
- ArgoCD: `https://goapps.mutugading.com/argocd`

---

## Step 14: Verifikasi Final

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

> **Note:** Port forward hanya bekerja langsung di VPS. Untuk akses dari komputer lokal, gunakan SSH tunnel.

**Opsi 1: Langsung dari VPS (jika ada GUI/browser di VPS)**
```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Buka browser di VPS: http://localhost:3000
```

**Opsi 2: SSH Tunnel dari komputer lokal**
```bash
# Di komputer lokal Anda (bukan di VPS), jalankan:
# Untuk STAGING:
ssh -L 3000:localhost:3000 deploy@staging-goapps.mutugading.com "kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"

# Untuk PRODUCTION:
ssh -L 3000:localhost:3000 deploy@goapps.mutugading.com "kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"

# Lalu buka browser di lokal: http://localhost:3000
# Login: admin / <GRAFANA_PASSWORD>
```

**Opsi 3: Akses via Ingress (Recommended)**

Setelah NGINX Ingress terinstall dan DNS pointing:
- Staging: `https://staging-goapps.mutugading.com/grafana`
- Production: `https://goapps.mutugading.com/grafana`

### Access ArgoCD (Port Forward)

```bash
# SSH Tunnel dari komputer lokal:
# Untuk STAGING:
ssh -L 8080:localhost:8080 deploy@staging-goapps.mutugading.com "kubectl port-forward svc/argocd-server -n argocd 8080:443"

# Untuk PRODUCTION:
ssh -L 8080:localhost:8080 deploy@goapps.mutugading.com "kubectl port-forward svc/argocd-server -n argocd 8080:443"

# Buka browser di lokal: https://localhost:8080
# Login: admin / <ARGOCD_PASSWORD>
```

Alternatif via Ingress:
- Staging: `https://staging-goapps.mutugading.com/argocd`
- Production: `https://goapps.mutugading.com/argocd`

---

## Step 15: Deploy Finance Service

Setelah infrastructure ready:

```bash
kubectl apply -k services/finance-service/overlays/staging/

# Monitor (namespace is goapps-staging, not go-apps)
kubectl get pods -n goapps-staging -w
kubectl get hpa -n goapps-staging
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

## NGINX Ingress tidak bekerja / Ingress tidak punya Address

Jika `kubectl get ingress -A` menunjukkan ingress tanpa ADDRESS:

```bash
# 1. Pastikan NGINX Ingress Controller terinstall
kubectl get pods -n ingress-nginx
# Jika tidak ada pods, install dulu:
./scripts/install-nginx-ingress.sh

# 2. Pastikan TLS secret ada di namespace yang benar
kubectl get secret goapps-tls -n monitoring
kubectl get secret goapps-tls -n ingress-nginx  # Harus ada juga di sini

# 3. Copy secret ke ingress-nginx jika belum ada
kubectl get secret goapps-tls -n monitoring -o yaml | \
  sed 's/namespace: monitoring/namespace: ingress-nginx/' | \
  kubectl apply -f -
```

## Finance Service ImagePullBackOff

Error ini terjadi karena Docker image belum tersedia di GHCR:

```bash
# Cek detail error
kubectl describe pod -n goapps-staging -l app=finance-service

# Pastikan secret ghcr-secret ada
kubectl get secret ghcr-secret -n goapps-staging
```

**Solusi:** Pastikan tim Backend sudah push Docker image ke:
- `ghcr.io/mutugading/goapps-backend/finance-service:develop` (untuk staging)
- `ghcr.io/mutugading/goapps-backend/finance-service:latest` (untuk production)

## Production VPS menggunakan Ingress Staging (salah)

Jika tidak sengaja apply `overlays/staging/ingress.yaml` di Production VPS:

```bash
# Hapus ingress staging yang salah
kubectl delete ingress grafana-ingress prometheus-ingress argocd-ingress -n monitoring --ignore-not-found
kubectl delete ingress argocd-ingress -n argocd --ignore-not-found

# Apply ingress production yang benar
kubectl apply -f overlays/production/ingress.yaml
```

## localhost refused to connect saat Port Forward

Port forward dari VPS tidak bisa diakses langsung dari komputer lokal.

**Solusi:**
1. Gunakan SSH Tunnel (lihat Step 14)
2. Atau akses via Ingress setelah NGINX Ingress terinstall

---

# Quick Reference

| Service | Access |
|---------|--------|
| Grafana | `https://[staging-]goapps.mutugading.com/grafana` |
| Prometheus | `https://[staging-]goapps.mutugading.com/prometheus` |
| ArgoCD | `https://[staging-]goapps.mutugading.com/argocd` |
| K8s Dashboard | `kubectl proxy` → `http://localhost:8001/...` |
