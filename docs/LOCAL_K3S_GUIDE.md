# Local K3s Cluster Guide (staging-like, Colima profile `k8s`)

Runbook untuk menjalankan stack GoApps di cluster k3s lokal yang meniru staging. Semua target ada di `local.mk` (`make local-help`).

## 1. Tujuan & non-tujuan

**Tujuan**: menguji manifest Kustomize (overlay `local`), Ingress, dan alur BFF -> gRPC di cluster nyata di laptop, tanpa menyentuh staging/production.

**Non-tujuan**:
- Bukan pengganti `make run` / `docker compose` untuk dev harian.
- Tidak men-deploy `base/database` (PostgreSQL/Redis/RabbitMQ/MinIO dipakai dari data layer host).
- Tidak ada ArgoCD, monitoring, backup. Fitur Oracle/ERP/HRIS tidak berjalan (kredensial dummy).
- Bukan lingkungan production-grade (HA, TLS, dsb).

## 2. Arsitektur

Dua Colima profile:

| Profile | Isi | Catatan |
|---------|-----|---------|
| `default` | Data layer (compose v2): PG `5440`, pgbouncer `6440`, redis `6379`, rabbitmq `5672`, minio `9000` | **TIDAK DISENTUH** oleh target `local-*` |
| `k8s` | k3s `v1.34.13+k3s1`, 4 CPU / 8 GiB, traefik dimatikan | Context kubectl `colima-k8s`, namespace `goapps-local` |

Ingress: ingress-nginx chart `4.15.1`, Service `LoadBalancer` via servicelb (klipper), Colima mem-forward ke Mac `:80` / `:443`.

```
Browser -> Mac :80 -> VM k8s (ingress-nginx) -> frontend / finance / iam / ppc (ns goapps-local)
                                                     |
                      pod -> Service+EndpointSlice -> 192.168.5.2 (host Mac) -> container profile default
```

### Jalur pod -> host

`192.168.5.2` (= `host.lima.internal`) adalah gateway VM `k8s`; port forward profile `default` bind di `*` Mac sehingga terjangkau. Dibuat sebagai Service + EndpointSlice di `base/local/external`:

| Service (DNS di cluster) | Port Service -> host | Tujuan |
|--------------------------|----------------------|--------|
| `pgbouncer-vps.database` | 5432 -> 6440 | pgbouncer v2 (runtime, role `*_app`) |
| `postgres-v2.database` | 5432 -> 5440 | PG v2 langsung (khusus Job migrate/seed, role owner) |
| `redis.database` | 6379 -> 6379 | goapps-redis |
| `rabbitmq.database` | 5672 -> 5672 | RabbitMQ |
| `minio.minio` | 9000 (+console 9001) | MinIO |

IP `192.168.5.3` (node) dan `10.42.0.1` (gateway pod) TIDAK bisa dipakai.

## 3. Prasyarat

- `brew install colima kubectl kustomize helm` (docker CLI juga diperlukan).
- Container data layer di profile `default` sedang jalan (`goapps-v2-postgres`, pgbouncer, `goapps-redis`, rabbitmq, minio). Docker colima: `export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock`.
- **Hentikan Redis Homebrew**: `brew services stop redis`. Redis native menempati `127.0.0.1:6379` di Mac sehingga `192.168.5.2:6379` dari pod sampai ke redis native (bukan `goapps-redis`), data/versi salah.
- Port `80`/`443` Mac kosong.
- Repo `goapps-backend` dan `goapps-frontend` ada sebagai sibling (`BACKEND_DIR`, `FRONTEND_DIR` default `../goapps-*`).

## 4. Quick start

```bash
cd goapps-infra
make local-secrets      # buat base/local/credentials/*.local.env (tidak menimpa yang ada)
make local-cluster-up   # start profile k8s + install ingress-nginx
make local-build        # build image :local ke docker daemon profile k8s
make local-deploy       # apply namespaces/external/credentials + semua overlays/local
make local-status
```

Satu langkah untuk rebuild + deploy: `make local-all`.

## 5. Target make

| Target | Fungsi |
|--------|--------|
| `local-help` | Daftar target |
| `local-cluster-up` | Start profile `k8s` (jika belum) + install ingress-nginx |
| `local-cluster-down` | `colima stop -p k8s` |
| `local-secrets` | Generate `*.local.env` yang belum ada |
| `local-base` | Apply namespaces, external endpoints, credentials |
| `local-build [SVC=img]` | Build image `ghcr.io/mutugading/<img>:local`. `SVC` = nama IMAGE (`finance-service`, `iam-service`, `ppc-service`, `finance-cost-orchestrator`, `finance-cost-worker`, `goapps-frontend`); `finance-worker` memakai image finance-service |
| `local-deploy [RESTART=1]` | Apply semua `services/*/overlays/local`; `RESTART=1` rollout restart |
| `local-all` | `local-build` lalu `local-deploy RESTART=1` |
| `local-status` | pods/svc/ingress + `colima list` |
| `local-logs SVC=<deployment>` | Follow log deployment |
| `local-scale-zero` / `local-scale-one` | Scale semua deployment ke 0 / 1 |
| `local-migrate SVC=<finance-service\|iam-service\|ppc-service> CONFIRM=yes` | Jalankan Job migrasi |
| `local-seed SVC=... CONFIRM=yes` | Jalankan Job seeder |
| `local-validate` | `kustomize build` semua overlay local (read-only) |
| `local-destroy CONFIRM=yes` | Hapus profile `k8s` (menolak profile `default`) |

Variabel yang bisa di-override: `LOCAL_CTX`, `LOCAL_PROFILE`, `K3S_VERSION`, `LOCAL_NS`, `LOCAL_CPU`, `LOCAL_MEM`, `LOCAL_DISK`, `BACKEND_DIR`, `FRONTEND_DIR`, `LOCAL_SERVICES`.

## 6. URL & login

- Frontend: http://goapps.localhost
- API: http://api.goapps.localhost/api/v1/{iam,finance,ppc}
- Login (LOCAL ONLY, jangan dipakai di staging/prod): `admin` / `LocalAdmin#2026`

```bash
curl -s -X POST http://api.goapps.localhost/api/v1/iam/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"LocalAdmin#2026"}'   # token di data.access_token
```

## 7. Secrets

- Lokasi: `base/local/credentials/`. File `*.local.env.example` di-commit; `*.local.env` NYATA di-gitignore (entri `*.local.env`).
- Direktori sengaja bukan `secrets/` karena `.gitignore` lama `**/secrets/` akan menyembunyikan file example.
- `make local-secrets` hanya membuat file yang belum ada. Password DB/rabbit/minio mengikuti dev compose backend; JWT/internal token/chat key acak lokal.
- Oracle/ERP berisi dummy (`oracle.invalid`) -> fitur Oracle/HRIS nonaktif. `ORACLE_MGTHRIS_*` belum disediakan.
- SMTP menuju `192.168.5.2:1025`: butuh mailpit jalan di host bila email diuji.

## 8. Migrate / seed (opt-in)

Tidak dijalankan otomatis. DB v2 lokal adalah DB BERSAMA (juga dipakai `make run`), jadi migrate/seed menulis ke sana:

```bash
make local-migrate SVC=finance-service CONFIRM=yes
make local-seed    SVC=iam-service CONFIRM=yes
```

Job memakai role owner via `postgres-v2.database` (koneksi langsung, sslmode disable) dan hanya menerapkan Job berlabel `component=migration|seeder`.

## 9. RAM & hemat resource

VM `k8s` dialokasikan 8 GiB / 4 CPU di atas profile `default`. Bila laptop berat: `make local-scale-zero` (pod mati, cluster tetap), lalu `make local-scale-one`; atau `make local-cluster-down` untuk mematikan VM sepenuhnya.

## 10. Safety

- Semua `kubectl` memakai `--context colima-k8s`, helm `--kube-context`; Makefile tidak pernah `use-context`.
- **`colima start` meng-switch current-context ke `colima-k8s`.** Cek `kubectl config current-context` sebelum menjalankan perintah manual ke staging/prod.
- `local-destroy` menolak profile `default` dan butuh `CONFIRM=yes`.
- Jangan menjalankan perintah ke profile `default` selain start/stop container data layer.
- Image staging berarsitektur amd64, lokal arm64 (Apple Silicon): image `:local` dibangun native arm64, tidak identik dengan image staging.

## 11. Troubleshooting

- **Image pull timeout dari `registry.k8s.io` di dalam cluster**: pull lewat daemon Docker profile k8s lalu hapus pod: `DOCKER_HOST=unix://$HOME/.colima/k8s/docker.sock docker pull <image>`; `kubectl --context colima-k8s -n <ns> delete pod <pod>`.
- **`npm ci` ECONNRESET saat build frontend**: masalah jaringan, ulangi `make local-build SVC=goapps-frontend` (SVC = nama image).
- **Ingress 404 tepat setelah apply**: tunggu nginx reload beberapa detik.
- **Patch Ingress `rules`**: patch strategic-merge mengganti seluruh list `rules`. Patch host-only menghapus `http.paths` dari base; patch harus memuat `http.paths` lengkap.
- **Env `value` + `valueFrom` konflik**: jangan override env yang di base memakai `valueFrom` dengan `value` (dan sebaliknya); hapus override, atau pakai patch `$patch: replace`/hapus salah satu.
- **MinIO bucket**: bucket yang ada hanya `goapps-staging`, overlay local memakainya.
- **Redis salah sasaran**: pastikan `brew services` redis sudah stop (lihat Prasyarat).

## 12. Cek regresi staging/prod

Overlay local additive; staging/prod tidak boleh berubah. Sebelum dan sesudah perubahan, build semua overlay staging/prod dan bandingkan hasilnya (harus identik):

```bash
mkdir -p /tmp/k3s-before && for d in services/*/overlays/{staging,production}; do
  kustomize build --load-restrictor LoadRestrictionsNone $d > /tmp/k3s-before/$(echo $d | tr / _).yaml; done
# ... ubah ... ulangi ke /tmp/k3s-after, lalu: diff -r /tmp/k3s-before /tmp/k3s-after
```

`services/{finance,iam,ppc}-service/overlays/staging/jobs` butuh `--load-restrictor LoadRestrictionsNone` (pre-existing). Juga jalankan `make local-validate`.

## Temuan (pre-existing, tidak diubah)

Overlay staging dan production untuk finance, iam, dan ppc me-render Ingress dengan `host` saja dan 0 `paths` (patch host-only menimpa list `rules`). Tidak diubah di sini; perlu verifikasi terpisah di cluster live (`kubectl get ingress -o yaml`) apakah ini benar-benar terjadi atau hanya artefak render.
