# SSL Certificate Renewal Runbook

> Panduan update/renewal SSL certificate untuk GoApps Kubernetes cluster.
> SSL termination dilakukan di **NGINX Ingress Controller** — service apps (finance, iam, frontend) TIDAK perlu di-restart.

---

## Infrastructure Layout

GoApps menggunakan **2 VPS terpisah**, masing-masing menjalankan K3s cluster sendiri:

| Environment | VPS | Domain |
|-------------|-----|--------|
| Staging | 4c / 8GB | `staging-goapps.mutugading.com` |
| Production | 8c / 16GB | `goapps.mutugading.com` |

**SSL harus di-update di kedua server secara terpisah.**

---

## Prerequisites

- Akses root ke **kedua VPS** (`sudo su`)
- File SSL baru:
  - `ssl-bundle.crt` (certificate + chain/CA bundle)
  - `ssl-bundle.key` (private key)
- `kubectl` sudah terkonfigurasi di masing-masing server (`/root/.kube/config`)
- File SSL harus di-copy ke **kedua server**

---

## File SSL Location

Letakkan file SSL baru di `/root/SSL-<YEAR>/` pada **kedua server**:

```bash
mkdir -p /root/SSL-$(date +%Y)
# Copy ssl-bundle.crt dan ssl-bundle.key ke folder tersebut
ls -la /root/SSL-$(date +%Y)/
# Pastikan ada: ssl-bundle.crt, ssl-bundle.key
```

---

## Step-by-Step: Update SSL

### Step 1 — Verifikasi dan sanitasi file SSL baru

Jalankan di **kedua server**:

```bash
SSL_DIR="/root/SSL-$(date +%Y)"

# 1a. Cek certificate info (subject, issuer, expiry)
openssl x509 -in ${SSL_DIR}/ssl-bundle.crt -noout -subject -issuer -dates

# 1b. Pastikan key cocok dengan certificate (hash harus sama)
openssl x509 -in ${SSL_DIR}/ssl-bundle.crt -noout -modulus | md5sum
openssl rsa -in ${SSL_DIR}/ssl-bundle.key -noout -modulus | md5sum

# 1c. Sanitasi: hapus trailing empty lines dari key file
#     MinIO AKAN CRASH jika key file punya extra empty lines di akhir.
#     NGINX Ingress lebih toleran, tapi lebih baik dibersihkan untuk semua.
sed -i '/^$/d' ${SSL_DIR}/ssl-bundle.key

# 1d. Verifikasi key sudah bersih (harus akhiri dengan "EY-----" + 1 newline, tanpa extra line)
xxd ${SSL_DIR}/ssl-bundle.key | tail -3
```

Jika kedua hash di step 1b **tidak sama**, file cert dan key tidak cocok — jangan lanjutkan.

### Step 2 — Backup secret lama

Jalankan di **kedua server**:

```bash
kubectl get secret goapps-tls -n ingress-nginx -o yaml > /root/goapps-tls-backup-$(date +%Y%m%d).yaml
kubectl get secret minio-tls -n minio -o yaml > /root/minio-tls-backup-$(date +%Y%m%d).yaml
```

---

### Step 3a — Update Ingress TLS: SERVER PRODUCTION

SSH ke **server production**, lalu:

```bash
SSL_DIR="/root/SSL-$(date +%Y)"

for NS in ingress-nginx goapps-production monitoring; do
  echo "Updating goapps-tls in: ${NS}"
  kubectl create secret tls goapps-tls \
    --cert=${SSL_DIR}/ssl-bundle.crt \
    --key=${SSL_DIR}/ssl-bundle.key \
    -n ${NS} \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

### Step 3b — Update Ingress TLS: SERVER STAGING

SSH ke **server staging**, lalu:

```bash
SSL_DIR="/root/SSL-$(date +%Y)"

for NS in ingress-nginx goapps-staging monitoring; do
  echo "Updating goapps-tls in: ${NS}"
  kubectl create secret tls goapps-tls \
    --cert=${SSL_DIR}/ssl-bundle.crt \
    --key=${SSL_DIR}/ssl-bundle.key \
    -n ${NS} \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

---

### Step 4 — Restart NGINX Ingress Controller

Jalankan di **kedua server**:

```bash
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx
```

> **Catatan**: TIDAK perlu restart finance-service, iam-service, atau frontend.
> SSL termination sepenuhnya di NGINX Ingress.

---

### Step 5 — Verifikasi Ingress SSL baru aktif

**Dari server production:**

```bash
echo | openssl s_client -connect goapps.mutugading.com:443 -servername goapps.mutugading.com 2>/dev/null | openssl x509 -noout -subject -dates
```

**Dari server staging:**

```bash
echo | openssl s_client -connect staging-goapps.mutugading.com:443 -servername staging-goapps.mutugading.com 2>/dev/null | openssl x509 -noout -subject -dates
```

Pastikan `notAfter` menunjukkan tanggal expiry certificate baru.

**Verifikasi via browser** — buka semua URL berikut dan pastikan HTTPS valid (gembok hijau):

| Service | Production | Staging |
|---------|-----------|---------|
| App | `https://goapps.mutugading.com` | `https://staging-goapps.mutugading.com` |
| Grafana | `https://goapps.mutugading.com/grafana` | `https://staging-goapps.mutugading.com/grafana` |
| ArgoCD | `https://goapps.mutugading.com/argocd` | `https://staging-goapps.mutugading.com/argocd` |

---

### Step 6 — Update MinIO TLS

MinIO **menggunakan TLS** secara terpisah dari Ingress. Certificate di-mount langsung ke pod MinIO
dari secret `minio-tls` ke `/root/.minio/certs/`.

**Penting**: Secret `minio-tls` menggunakan key names **berbeda** dari `goapps-tls`:
- `minio-tls`: `public.crt` + `private.key` (menggunakan `kubectl create secret generic`)
- `goapps-tls`: `tls.crt` + `tls.key` (menggunakan `kubectl create secret tls`)

Jalankan di **kedua server**:

```bash
SSL_DIR="/root/SSL-$(date +%Y)"

# MinIO butuh key: public.crt dan private.key (BUKAN tls.crt/tls.key)
kubectl create secret generic minio-tls \
  --from-file=public.crt=${SSL_DIR}/ssl-bundle.crt \
  --from-file=private.key=${SSL_DIR}/ssl-bundle.key \
  -n minio \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/minio -n minio
kubectl rollout status deployment/minio -n minio
```

### Step 7 — Verifikasi MinIO TLS

MinIO diakses via **NodePort** (HTTPS langsung ke pod, bukan lewat Ingress):

| Port | Fungsi |
|------|--------|
| 30090 | Console (Web UI) |
| 30091 | API (S3) |

**Verifikasi via command:**

```bash
# Cek SSL certificate MinIO
echo | openssl s_client -connect localhost:30090 2>/dev/null | openssl x509 -noout -subject -dates
```

**Verifikasi via browser:**

| Environment | MinIO Console URL |
|-------------|-------------------|
| Production | `https://goapps.mutugading.com:30090/` |
| Staging | `https://staging-goapps.mutugading.com:30090/` |

> **Catatan**: Ingress juga memiliki path `/minio/` yang mengarah ke MinIO console (port 9001),
> tapi MinIO dikonfigurasi untuk redirect ke NodePort `:30090`. Gunakan URL NodePort di atas.

---

## Quick Reference (Copy-Paste)

### Server Production

```bash
#!/bin/bash
SSL_DIR="/root/SSL-$(date +%Y)"

echo "=== [PRODUCTION] Verifikasi SSL files ==="
openssl x509 -in ${SSL_DIR}/ssl-bundle.crt -noout -subject -dates
echo ""

echo "=== [PRODUCTION] Sanitasi key file (hapus trailing empty lines) ==="
sed -i '/^$/d' ${SSL_DIR}/ssl-bundle.key
echo "Key file sanitized"
echo ""

echo "=== [PRODUCTION] Backup secret lama ==="
kubectl get secret goapps-tls -n ingress-nginx -o yaml > /root/goapps-tls-backup-$(date +%Y%m%d).yaml
kubectl get secret minio-tls -n minio -o yaml > /root/minio-tls-backup-$(date +%Y%m%d).yaml
echo ""

echo "=== [PRODUCTION] Update Ingress TLS secrets ==="
for NS in ingress-nginx goapps-production monitoring; do
  echo "Updating goapps-tls in: ${NS}"
  kubectl create secret tls goapps-tls \
    --cert=${SSL_DIR}/ssl-bundle.crt \
    --key=${SSL_DIR}/ssl-bundle.key \
    -n ${NS} \
    --dry-run=client -o yaml | kubectl apply -f -
done
echo ""

echo "=== [PRODUCTION] Restart NGINX Ingress ==="
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx
echo ""

echo "=== [PRODUCTION] Update MinIO TLS secret ==="
kubectl create secret generic minio-tls \
  --from-file=public.crt=${SSL_DIR}/ssl-bundle.crt \
  --from-file=private.key=${SSL_DIR}/ssl-bundle.key \
  -n minio \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/minio -n minio
kubectl rollout status deployment/minio -n minio
echo ""

echo "=== [PRODUCTION] Verifikasi SSL aktif ==="
echo "--- Ingress (NGINX) ---"
echo | openssl s_client -connect goapps.mutugading.com:443 -servername goapps.mutugading.com 2>/dev/null | openssl x509 -noout -subject -dates
echo "--- MinIO (NodePort 30090) ---"
echo | openssl s_client -connect localhost:30090 2>/dev/null | openssl x509 -noout -subject -dates
```

### Server Staging

```bash
#!/bin/bash
SSL_DIR="/root/SSL-$(date +%Y)"

echo "=== [STAGING] Verifikasi SSL files ==="
openssl x509 -in ${SSL_DIR}/ssl-bundle.crt -noout -subject -dates
echo ""

echo "=== [STAGING] Sanitasi key file (hapus trailing empty lines) ==="
sed -i '/^$/d' ${SSL_DIR}/ssl-bundle.key
echo "Key file sanitized"
echo ""

echo "=== [STAGING] Backup secret lama ==="
kubectl get secret goapps-tls -n ingress-nginx -o yaml > /root/goapps-tls-backup-$(date +%Y%m%d).yaml
kubectl get secret minio-tls -n minio -o yaml > /root/minio-tls-backup-$(date +%Y%m%d).yaml
echo ""

echo "=== [STAGING] Update Ingress TLS secrets ==="
for NS in ingress-nginx goapps-staging monitoring; do
  echo "Updating goapps-tls in: ${NS}"
  kubectl create secret tls goapps-tls \
    --cert=${SSL_DIR}/ssl-bundle.crt \
    --key=${SSL_DIR}/ssl-bundle.key \
    -n ${NS} \
    --dry-run=client -o yaml | kubectl apply -f -
done
echo ""

echo "=== [STAGING] Restart NGINX Ingress ==="
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx
echo ""

echo "=== [STAGING] Update MinIO TLS secret ==="
kubectl create secret generic minio-tls \
  --from-file=public.crt=${SSL_DIR}/ssl-bundle.crt \
  --from-file=private.key=${SSL_DIR}/ssl-bundle.key \
  -n minio \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/minio -n minio
kubectl rollout status deployment/minio -n minio
echo ""

echo "=== [STAGING] Verifikasi SSL aktif ==="
echo "--- Ingress (NGINX) ---"
echo | openssl s_client -connect staging-goapps.mutugading.com:443 -servername staging-goapps.mutugading.com 2>/dev/null | openssl x509 -noout -subject -dates
echo "--- MinIO (NodePort 30090) ---"
echo | openssl s_client -connect localhost:30090 2>/dev/null | openssl x509 -noout -subject -dates
```

---

## Namespace & Secret Mapping

### Server Production

| Namespace | Secret Name | Key Names | Digunakan Oleh |
|-----------|-------------|-----------|----------------|
| `ingress-nginx` | `goapps-tls` | `tls.crt`, `tls.key` | Production ingress overlay (NGINX) |
| `goapps-production` | `goapps-tls` | `tls.crt`, `tls.key` | finance-service, iam-service, frontend ingress |
| `monitoring` | `goapps-tls` | `tls.crt`, `tls.key` | Grafana, Prometheus ingress |
| `minio` | `minio-tls` | `public.crt`, `private.key` | MinIO S3 storage (mounted to pod) |

### Server Staging

| Namespace | Secret Name | Key Names | Digunakan Oleh |
|-----------|-------------|-----------|----------------|
| `ingress-nginx` | `goapps-tls` | `tls.crt`, `tls.key` | Staging ingress overlay (NGINX) |
| `goapps-staging` | `goapps-tls` | `tls.crt`, `tls.key` | finance-service, iam-service, frontend ingress |
| `monitoring` | `goapps-tls` | `tls.crt`, `tls.key` | Grafana, Prometheus ingress |
| `minio` | `minio-tls` | `public.crt`, `private.key` | MinIO S3 storage (mounted to pod) |

---

## Service Access URLs

### Production (`goapps.mutugading.com`)

| Service | URL | Akses Via |
|---------|-----|-----------|
| App (Frontend) | `https://goapps.mutugading.com` | Ingress |
| Grafana | `https://goapps.mutugading.com/grafana` | Ingress |
| Prometheus | `https://goapps.mutugading.com/prometheus` | Ingress (Basic Auth) |
| ArgoCD | `https://goapps.mutugading.com/argocd` | Ingress |
| MinIO Console | `https://goapps.mutugading.com:30090/` | NodePort (direct TLS) |
| MinIO API | `https://goapps.mutugading.com:30091/` | NodePort (direct TLS) |

### Staging (`staging-goapps.mutugading.com`)

| Service | URL | Akses Via |
|---------|-----|-----------|
| App (Frontend) | `https://staging-goapps.mutugading.com` | Ingress |
| Grafana | `https://staging-goapps.mutugading.com/grafana` | Ingress |
| Prometheus | `https://staging-goapps.mutugading.com/prometheus` | Ingress |
| ArgoCD | `https://staging-goapps.mutugading.com/argocd` | Ingress |
| MinIO Console | `https://staging-goapps.mutugading.com:30090/` | NodePort (direct TLS) |
| MinIO API | `https://staging-goapps.mutugading.com:30091/` | NodePort (direct TLS) |

---

## Troubleshooting

### SSL masih menunjukkan certificate lama

```bash
# Cek apakah secret sudah terupdate
kubectl get secret goapps-tls -n ingress-nginx -o jsonpath='{.metadata.resourceVersion}'

# Pastikan NGINX sudah restart
kubectl get pods -n ingress-nginx

# Force restart jika masih lama
kubectl delete pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

### Certificate dan key tidak cocok

```bash
# Hash harus identical
openssl x509 -in ssl-bundle.crt -noout -modulus | md5sum
openssl rsa -in ssl-bundle.key -noout -modulus | md5sum
```

### Error: secret already exists

Ini normal — flag `--dry-run=client -o yaml | kubectl apply -f -` sudah handle update otomatis.

### Warning: missing kubectl.kubernetes.io/last-applied-configuration

Ini normal — muncul jika secret sebelumnya dibuat via `kubectl create` bukan `kubectl apply`. Annotation akan otomatis ditambahkan.

### MinIO pod CrashLoopBackOff setelah update TLS

MinIO sangat sensitif terhadap format file SSL. Penyebab umum:

**1. `The private key contains additional data`**

File `ssl-bundle.key` punya trailing empty lines. Fix:

```bash
# Hapus empty lines dari key
sed -i '/^$/d' /root/SSL-$(date +%Y)/ssl-bundle.key

# Verifikasi (harus akhiri EY----- tanpa extra line)
xxd /root/SSL-$(date +%Y)/ssl-bundle.key | tail -3

# Apply ulang secret + restart
SSL_DIR="/root/SSL-$(date +%Y)"
kubectl create secret generic minio-tls \
  --from-file=public.crt=${SSL_DIR}/ssl-bundle.crt \
  --from-file=private.key=${SSL_DIR}/ssl-bundle.key \
  -n minio \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/minio -n minio
kubectl rollout status deployment/minio -n minio
```

**2. Key names salah di secret**

MinIO mount certificate dari secret dengan key names `public.crt` dan `private.key`.
Jika menggunakan `kubectl create secret tls` (bukan `generic`), key names akan jadi
`tls.crt` dan `tls.key` — MinIO tidak akan menemukan certificate-nya.

```bash
# Cek key names di secret (harus: public.crt, private.key)
kubectl get secret minio-tls -n minio -o jsonpath='{.data}' | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))"
```

**3. Rollback jika tidak bisa di-fix**

```bash
kubectl apply -f /root/minio-tls-backup-YYYYMMDD.yaml
kubectl rollout restart deployment/minio -n minio
kubectl rollout status deployment/minio -n minio
```

### NGINX pod CrashLoopBackOff setelah update TLS

Certificate mungkin invalid. Rollback ke backup:

```bash
kubectl apply -f /root/goapps-tls-backup-YYYYMMDD.yaml
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
```

### Grafana CrashLoopBackOff (tidak terkait SSL)

Jika Grafana CrashLoopBackOff dengan error `Datasource provisioning error: data source not found`,
ini bukan masalah SSL. Restart biasanya cukup:

```bash
kubectl rollout restart deployment/prometheus-grafana -n monitoring
kubectl rollout status deployment/prometheus-grafana -n monitoring
```

---

## Reminder Schedule

SSL certificate biasanya berlaku 6-12 bulan. Set reminder untuk renewal **2 minggu sebelum expiry**.

Cek tanggal expiry saat ini:

```bash
# Dari server production
echo | openssl s_client -connect goapps.mutugading.com:443 2>/dev/null | openssl x509 -noout -enddate

# Dari server staging
echo | openssl s_client -connect staging-goapps.mutugading.com:443 2>/dev/null | openssl x509 -noout -enddate

# MinIO (jalankan di server masing-masing)
echo | openssl s_client -connect localhost:30090 2>/dev/null | openssl x509 -noout -enddate
```

---

## Changelog

| Tanggal | Keterangan |
|---------|------------|
| 2026-04-04 | Initial runbook. SSL renewed (notAfter: Oct 17 2026). Wildcard cert `*.mutugading.com` dari Sectigo. |
| 2026-04-04 | Added key file sanitasi step. MinIO crashed karena `ssl-bundle.key` punya trailing empty lines (`The private key contains additional data`). Step 1 sekarang otomatis `sed -i '/^$/d'` key file sebelum apply. |
