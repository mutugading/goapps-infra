# Runbook — PostgreSQL VPS monitoring

Since the DB v2 cutover (staging 2026-10-27, production 2026-11-05) the application databases run on
dedicated VPS outside the cluster. This runbook covers how they are monitored from the in-cluster
kube-prometheus-stack.

| Env | Postgres VPS | Scraped from (K3s node) | `instance` label |
|---|---|---|---|
| staging | `192.168.0.60` | `192.168.0.113` | `psql-goapps-stg` |
| production | `192.168.0.40` | `192.168.0.112` | `psql-goapps-prod` |

## What runs where
- **VPS (outside git):** Ubuntu packages `prometheus-node-exporter` (1.7.0, `:9100`) and
  `prometheus-postgres-exporter` (0.15.0, `:9187`), bound to the LAN IP. ufw allows 9100/9187 only from the
  K3s node of the same env. The exporter logs in as role `monitor` (`pg_monitor`) over 127.0.0.1.
  Custom queries `pg_vps_*` live in `/etc/prometheus/postgres-exporter-queries.yaml`; the built-in collectors
  `stat_bgwriter` and `stat_statements` are disabled because exporter 0.15 queries columns that PostgreSQL 17+ renamed.
  `pg-backup` / `pg-restore-test` write `goapps_pg_backup_*` / `goapps_pg_restore_test_*` to the node_exporter
  textfile collector (`/var/lib/node_exporter/textfile_collector`).
- **Cluster (this repo):**
  - `base/monitoring/vps-postgres/` + `overlays/{staging,production}/vps-postgres/` — selector-less
    Service + Endpoints + ServiceMonitor, jobs `vps-node` and `vps-postgres`.
  - `base/monitoring/dashboards/grafana-dashboard-postgres-vps-configmap.yaml` — dashboard "PostgreSQL VPS"
    (uid `postgres-vps-dashboard`).
  - `base/monitoring/alert-rules/postgres-vps-alerts.yaml` — Grafana alert group "PostgreSQL VPS Alerts"
    (folder Database, 16 rules).

The old "PostgreSQL Dashboard", `postgres-alerts.yaml` and `base/database/exporter/` still watch the frozen
in-cluster Postgres (rollback target). They are removed in the decommission phase (P7).

## Apply (monitoring is not managed by ArgoCD)
On the K3s node of the env, from a checkout of this repo at `main`:
```bash
ENV=staging                      # or production
kubectl apply --dry-run=server -k overlays/$ENV/vps-postgres
kubectl apply -k overlays/$ENV/vps-postgres
kubectl apply -f base/monitoring/dashboards/grafana-dashboard-postgres-vps-configmap.yaml
kubectl apply -f base/monitoring/alert-rules/postgres-vps-alerts.yaml
```
Apply the alert ConfigMap as a single file; do not `kubectl apply -k base/monitoring/alert-rules`.

## Verify
```bash
SVC=prometheus-kube-prometheus-prometheus
kubectl get --raw "/api/v1/namespaces/monitoring/services/${SVC}:9090/proxy/prometheus/api/v1/targets?state=active" \
 | python3 -c 'import sys,json;[print(t["labels"]["job"],t["labels"].get("instance"),t["health"],t.get("lastError","")) for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"]["job"].startswith("vps-")]'
```
Expected: `vps-node <instance> up` and `vps-postgres <instance> up`.

## Troubleshooting
| Symptom | Check |
|---|---|
| Target `down`, `context deadline exceeded` | from the K3s node: `curl -m5 http://<vps>:9100/metrics`; ufw on the VPS must allow 9100/9187 from the node IP |
| `pg_up 0` | on the VPS: `journalctl -u prometheus-postgres-exporter -n 30` (password / pg_hba for `monitor`) |
| Backup panels empty | `node_textfile_scrape_error` must be 0; the `.prom` files must be mode 0644 |
| Alert **VPS PostgreSQL non-public schema** | a schema other than `public` exists in a `<svc>_db` (ADR 0001). On the VPS: `sudo -u postgres psql -d <db> -c '\dn+'`, find the creator (migration? manual?), move objects to `public` or drop the schema. Allow-list (in the alert expr): prod `finance_db.cmp`. Metric `pg_vps_nonpublic_schema_objects` comes from the custom query of the same name (per DB, `master: false`) |
| Per-table panels empty | needs `--auto-discover-databases --include-databases=…`, pg_hba `host <dbs> monitor 127.0.0.1/32` and `monitor` CONNECTION LIMIT ≥ 2 + number of DBs |

## Adding a new service database
For a new `<svc>_db`, in addition to the DB itself:
- `GRANT CONNECT` to `monitor`.
- Add the DB to the pg_hba monitor line and to `--include-databases`.
- Raise the `monitor` connection limit.
- Extend the dashboard `datname` regex.
- Add the DB to `pg-backup`.

`scripts/postgres/new-service-db.sh <svc> --target staging|production` does the VPS part (roles, DB, grants, pg_hba, monitor, exporter, pg-backup) and prints the K8s/repo follow-ups. The full checklist is kept with the migration docs (`monitoring-new-service-db.md`).
