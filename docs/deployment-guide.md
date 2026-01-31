# VPS Deployment Guide v2

Step-by-step untuk reset dan deploy ulang K3s cluster dari awal.

## Prerequisites

Di VPS (staging/production):
- Ubuntu 24.04 LTS
- SSH access dengan root/sudo
- Disk partitions sudah ready:
  - Staging: `/dev/sdb1` → `/staging-goapps-backup`
  - Production: `/dev/sdb1` → `/goapps-backup`
- SSL certificates: `ssl-bundle.crt` dan `ssl-bundle.key`

Di local machine:
- Git repo `goapps-infra` sudah di-push ke GitHub

---

## Step 1: Reset K3s (Jika Ada Instalasi Lama)

```bash
# SSH ke VPS
ssh deploy@[staging-]goapps.mutugading.com

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
kubectl get namespaces
```

---

## Step 4: Create Secrets (MANUAL - Tidak di Git!)

Lihat template di `base/secrets/secrets-template.yaml` untuk referensi.

### PostgreSQL

```bash
kubectl create secret generic postgres-secret -n database \
  --from-literal=POSTGRES_USER=goapps_admin \
  --from-literal=POSTGRES_PASSWORD='<STRONG_PASSWORD>' \
  --from-literal=POSTGRES_DB=goapps
```

### MinIO

```bash
kubectl create secret generic minio-secret -n minio \
  --from-literal=MINIO_ROOT_USER=admin \
  --from-literal=MINIO_ROOT_PASSWORD='<STRONG_PASSWORD>'

# Copy ke namespace database
kubectl get secret minio-secret -n minio -o yaml | \
  sed 's/namespace: minio/namespace: database/' | \
  kubectl apply -f -
```

### RabbitMQ

```bash
kubectl create secret generic rabbitmq-secret -n database \
  --from-literal=RABBITMQ_USER=goapps \
  --from-literal=RABBITMQ_PASSWORD='<STRONG_PASSWORD>'
```

### Oracle Credentials (Multiple Schemas)

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

### TLS Certificate

```bash
# Create TLS secret untuk Ingress
kubectl create secret tls goapps-tls -n ingress-nginx \
  --cert=ssl-bundle.crt \
  --key=ssl-bundle.key

# Copy ke namespace monitoring
kubectl get secret goapps-tls -n ingress-nginx -o yaml | \
  sed 's/namespace: ingress-nginx/namespace: monitoring/' | \
  kubectl apply -f -

# Create TLS secret untuk Kubernetes Dashboard
kubectl create secret tls dashboard-tls -n kubernetes-dashboard \
  --cert=ssl-bundle.crt \
  --key=ssl-bundle.key
```

### Grafana Admin & SMTP

```bash
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<GRAFANA_PASSWORD>'

kubectl create secret generic grafana-smtp-secret -n monitoring \
  --from-literal=password='<SMTP_PASSWORD>'
```

### Backblaze B2 (Cloud Backup)

```bash
kubectl create secret generic s3-cloud-credentials -n database \
  --from-literal=S3_ENDPOINT='s3.us-west-004.backblazeb2.com' \
  --from-literal=S3_BUCKET='goapps-backups' \
  --from-literal=AWS_ACCESS_KEY_ID='<B2_KEY_ID>' \
  --from-literal=AWS_SECRET_ACCESS_KEY='<B2_APP_KEY>'
```

### Container Registry Pull Secret

```bash
kubectl create secret docker-registry ghcr-secret -n go-apps \
  --docker-server=ghcr.io \
  --docker-username='<GITHUB_USERNAME>' \
  --docker-password='<GITHUB_TOKEN>'
```

---

## Step 5: Install Monitoring Stack

```bash
./scripts/install-monitoring.sh

# Tunggu semua pods ready
kubectl get pods -n monitoring -w

# Akses Grafana (via Ingress atau port-forward)
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

---

## Step 6: Install ArgoCD (GitOps)

```bash
./scripts/install-argocd.sh

# Catat password dari output!

# Akses ArgoCD UI:
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## Step 7: Apply Base Infrastructure

```bash
# Apply semua base configs
make apply-base

# Atau manual:
kubectl apply -k base/namespaces/
kubectl apply -k base/database/  # includes PostgreSQL, PgBouncer, Redis, RabbitMQ
kubectl apply -k base/backup/
kubectl apply -k base/observability/  # Jaeger

# Apply alert rules
kubectl apply -f base/monitoring/alert-rules/
```

### Verifikasi Services

```bash
# Database Layer
kubectl get pods -n database

# Jaeger Tracing
kubectl get pods -n observability

# Check Redis & RabbitMQ
kubectl exec -it deploy/redis -n database -- redis-cli ping  # PONG
```

---

## Step 8: Apply ArgoCD Applications

```bash
kubectl apply -f argocd/apps/

# Cek status
kubectl get applications -n argocd
```

---

## Step 9: Deploy Services (Via ArgoCD)

ArgoCD akan auto-sync dari Git berdasarkan branch/tag:
- **Staging**: `main` branch → auto deploy
- **Production**: Release tags (`v1.0.0`) → manual approval

---

## Step 10: Verifikasi Final

### Checklist

- [ ] K3s cluster running: `kubectl get nodes`
- [ ] All namespaces created: `kubectl get ns`
- [ ] PostgreSQL running: `kubectl get pods -n database -l app=postgres`
- [ ] PgBouncer running: `kubectl get pods -n database -l app=pgbouncer`
- [ ] Redis running: `kubectl get pods -n database -l app=redis`
- [ ] RabbitMQ running: `kubectl get pods -n database -l app=rabbitmq`
- [ ] MinIO running: `kubectl get pods -n minio`
- [ ] Prometheus/Grafana running: `kubectl get pods -n monitoring`
- [ ] Loki/Promtail running: `kubectl get pods -n monitoring -l app=loki`
- [ ] Jaeger running: `kubectl get pods -n observability`
- [ ] ArgoCD running: `kubectl get pods -n argocd`
- [ ] Backup CronJobs scheduled: `kubectl get cronjobs -n database`
- [ ] Alert rules imported: Check Grafana Alerting

---

## Environment-Specific Paths

| Environment | Backup Mount | Clone Command |
|-------------|--------------|---------------|
| **Staging** | `/staging-goapps-backup` | Use `overlays/staging/backup-patch.yaml` |
| **Production** | `/goapps-backup` | Use `overlays/production/backup-patch.yaml` |

---

## Troubleshooting

### Pod tidak start
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Database connection issues
```bash
kubectl run test-pg --rm -it --image=postgres:18-alpine -- \
  psql -h pgbouncer.database -U goapps_admin -d goapps
```

### Oracle connectivity test
```bash
# Check outbound to Oracle port
kubectl run test-net --rm -it --image=busybox -- /bin/sh -c \
  "nc -vz <ORACLE_IP> 1521"
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
| `make port-forward-jaeger` | Access Jaeger UI |

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                        VPS Cluster                              │
├─────────────┬───────────────────────────────────────────────────┤
│ Namespace   │ Components                                        │
├─────────────┼───────────────────────────────────────────────────┤
│ database    │ PostgreSQL, PgBouncer, Redis, RabbitMQ, Exporter │
│ minio       │ MinIO (Object Storage)                           │
│ monitoring  │ Prometheus, Grafana, Loki, Promtail, Alertmanager│
│ observability│ Jaeger (Tracing)                                 │
│ argocd      │ ArgoCD (GitOps)                                  │
│ go-apps     │ finance-service, iam-service, etc.               │
│ ingress-nginx│ NGINX Ingress Controller                        │
│ k8s-dashboard│ Kubernetes Dashboard                            │
└─────────────┴───────────────────────────────────────────────────┘
```
