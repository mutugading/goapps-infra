# DB v2 Cutover: in-cluster PostgreSQL to VPS PostgreSQL

Staging VPS `192.168.0.60:5432`, production VPS `192.168.0.40:5432`.
Databases: `iam_db`, `finance_db`, `ppc_db`. Roles per service:
`<svc>_app` (DML only, running services) and `<svc>_owner` (owns schema; migrate/seed/backfill/createdb).
Server enforces TLS (`hostssl`, scram-sha-256).

Path: pod -> `pgbouncer-vps.database.svc.cluster.local:5432` (sslmode=disable, in-cluster)
-> VPS (pgbouncer `server_tls_sslmode=require`). Jobs go DIRECT to the VPS with `sslmode=require`.

TODO: cert hostname is unknown, so `require` is used. Move to `verify-full` (pgbouncer
`server_tls_sslmode=verify-full` + `server_tls_ca_file`; jobs `sslmode=verify-full`) once known.

## 1. Secrets (create manually, never in Git)

Per namespace (`goapps-staging`, later `goapps-production`), for each of iam/finance/ppc:

```bash
NS=goapps-staging   # or goapps-production
for SVC in iam finance ppc; do
  kubectl create secret generic ${SVC}-db-secret -n $NS \
    --from-literal=APP_USER=${SVC}_app \
    --from-literal=APP_PASSWORD='<from password manager>' \
    --from-literal=OWNER_USER=${SVC}_owner \
    --from-literal=OWNER_PASSWORD='<from password manager>'
done
```
(use the real per-role passwords for each service, not one shared value.)

PgBouncer userlist, namespace `database`, only the `*_app` users (iam, finance, ppc, payroll) plus `monitor`
(passwords as plaintext or SCRAM verifier; plaintext works with scram-sha-256):

```
"iam_app" "<password>"
"finance_app" "<password>"
"ppc_app" "<password>"
"payroll_app" "<password>"
"monitor" "<password>"
```
```bash
kubectl create secret generic pgbouncer-vps-userlist -n database --from-file=userlist.txt=./userlist.txt
```
Delete the local file afterwards. Create it BEFORE ArgoCD syncs `infra-pgbouncer-vps` (pods
otherwise sit in ContainerCreating). `monitor` must also exist as a role on the VPS if you use the admin console.

## 2. Env var changes (old -> new), running services

Applies to `services/<svc>/overlays/<env>/patches/env-database.yaml`
(ppc-service uses the `PPC_` prefix for every DATABASE_* name).

| Workload | HOST | NAME | USER / PASSWORD secret |
|---|---|---|---|
| finance-service | postgres.database.svc.cluster.local -> pgbouncer-vps.database.svc.cluster.local | goapps -> finance_db | postgres-secret POSTGRES_USER/PASSWORD -> finance-db-secret APP_USER/APP_PASSWORD |
| finance-worker | pgbouncer.database... -> pgbouncer-vps.database... | goapps -> finance_db | same as above |
| finance-cost-worker | pgbouncer -> pgbouncer-vps | goapps -> finance_db | same |
| finance-cost-orchestrator | pgbouncer -> pgbouncer-vps | goapps -> finance_db | same |
| iam-service | postgres -> pgbouncer-vps | goapps -> iam_db | iam-db-secret APP_* |
| ppc-service | postgres -> pgbouncer-vps | ppc_db (unchanged) | ppc-db-secret APP_* |

PORT stays 5432 and SSLMODE stays `disable` (pod -> pgbouncer hop). `DATABASE_BINARY_PARAMETERS=true`
(cost-worker/orchestrator) is kept as is.

## 3. One-off jobs (applied manually, not ArgoCD-synced)

Use the setup scripts as before (`./scripts/{finance,iam,ppc}-setup.sh <namespace> [action]`).
When `services/<svc>-service/overlays/<env>/jobs/kustomization.yaml` exists (env derived
from the namespace), the scripts render that overlay (`kustomize build --load-restrictor
LoadRestrictionsNone`, needs kustomize in PATH) and apply ONLY the one Job being run; otherwise
they fall back to the base job file. Helper: `scripts/lib/render-job.sh`.

| Job | Old | New |
|---|---|---|
| finance-migrate | DSN `postgres.database.svc...:5432/goapps?sslmode=disable...`, postgres-secret | DSN `<VPS>:5432/finance_db?sslmode=require...` (same `x-migrations-table` and `options`), finance-db-secret OWNER_* |
| iam-migrate | same, `/goapps` | `<VPS>:5432/iam_db?sslmode=require...`, iam-db-secret OWNER_* |
| ppc-migrate | `postgres...:5432/ppc_db?sslmode=disable` | `<VPS>:5432/ppc_db?sslmode=require`, ppc-db-secret OWNER_* |
| finance-seed, finance-backfill-mb-validate | DATABASE_HOST postgres..., NAME goapps, SSLMODE disable | HOST `<VPS>`, NAME finance_db, SSLMODE require, finance-db-secret OWNER_* |
| iam-seed | same | HOST `<VPS>`, NAME iam_db, SSLMODE require, iam-db-secret OWNER_* |
| ppc-seed | PPC_DATABASE_* postgres... | PPC_DATABASE_HOST `<VPS>`, SSLMODE require, ppc-db-secret OWNER_* |
| ppc-createdb | creates ppc_db with `createdb` | verify-only: exits 0 if ppc_db exists, exit 1 otherwise (ppc_owner has no CREATEDB) |

`<VPS>` = 192.168.0.60 (staging) / 192.168.0.40 (production). The finance-worker
CronJob (`oracle-sync-monthly`) only curls the worker; it has no DB settings.

Note: the seed jobs run as `*_owner` (schema owner), the running services as `*_app`.
`*_app` must have DML grants / default privileges on objects the owner creates.

## 4. Rollback

`git revert` the cutover commit (staging or production) and let ArgoCD sync; services
return to the old in-cluster postgres / pgbouncer (base/database is untouched). Data written
to the VPS after cutover is NOT copied back; plan that separately. `pgbouncer-vps` is
additive and can stay running.
