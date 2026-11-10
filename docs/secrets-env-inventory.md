# Secrets & Env Var Inventory

Which Kubernetes Secret key feeds which env var in which workload. Check here **before**
adding an env var or creating a secret, so you reuse an existing key instead of guessing a name.

> Values are never in Git. This file lists **names only**. Created by hand on each cluster
> (see `CLAUDE.md` §12). Last verified 2026-10-28 against `kustomize build` of every
> `services/*/overlays/*`.

## How to check a live cluster (read-only, names only)

```bash
export NS=goapps-production   # or goapps-staging -- set it first, or `-n $NS` eats the next flag

kubectl get secret -n $NS                                                   # which secrets exist
kubectl get secret <secret> -n $NS -o jsonpath='{.data}' | jq 'keys'        # keys in a secret
kubectl get deploy <deploy> -n $NS \
  -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}{"\n"}{end}'   # env names in manifest
kubectl exec -n $NS deploy/<deploy> -- env | grep '^ORACLE' | sed 's/=.*/=<set>/'   # env present in pod
```

## Secrets in `goapps-staging` / `goapps-production`

| Secret | Keys | Notes |
|--------|------|-------|
| `oracle-credentials` | `ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`, `ORACLE_MGTHRIS_USER`, `ORACLE_MGTHRIS_PASSWORD`, `ORACLE_MGTAPPS_USER`, `ORACLE_MGTAPPS_PASSWORD`, `ORACLE_MGTDAT_USER`, `ORACLE_MGTDAT_PASSWORD` | Key list verified on **production**. One Oracle instance, several schema accounts. Staging points at oracle-rnd -- check its keys before relying on `MGT*`. |
| `pgbouncer-vps-userlist` | `userlist.txt` (scram auth file) | Namespace `database`; used by `pgbouncer-vps`. |
| `finance-db-secret` / `iam-db-secret` / `ppc-db-secret` | `APP_USER`, `APP_PASSWORD`, `OWNER_USER`, `OWNER_PASSWORD` | `APP_*` = runtime `<svc>_app`; `OWNER_*` = `<svc>_owner` for migrate/seed jobs. Per-service roles (ADR 0001), staging and production. `postgres-secret` was removed with the in-cluster Postgres (2026-11-10). |
| `goapps-auth-secret` | `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET` | |
| `goapps-internal-token` | `INTERNAL_SERVICE_TOKEN` | Service-to-service token. |
| `ppc-internal-token` | `PPC_INTERNAL_TOKEN` | Value **must equal** `INTERNAL_SERVICE_TOKEN` in the same namespace. |
| `goapps-chat-secret` | `CHAT_MASTER_KEY` | IAM chat encryption. |
| `minio-secret` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | |
| `rabbitmq-secret` | `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | |
| `smtp-secret` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS` | |
| `ghcr-secret` | `.dockerconfigjson` | Image pull. |

## Env var → secret key mapping

Format: `ENV_VAR` ← `secret/KEY`. "both" = staging and production.

### Oracle

| Env var | Source | Used by |
|---------|--------|---------|
| `ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD` | `oracle-credentials/<same name>` | finance-service, finance-worker, ppc-service (both) |
| `ORACLE_HRIS_HOST` | `oracle-credentials/ORACLE_HOST` | finance-service (both) |
| `ORACLE_HRIS_PORT` | `oracle-credentials/ORACLE_PORT` | finance-service (both) |
| `ORACLE_HRIS_SERVICE` | `oracle-credentials/ORACLE_SERVICE` | finance-service (both) |
| `ORACLE_HRIS_USER` | `oracle-credentials/ORACLE_MGTHRIS_USER` | finance-service (both) |
| `ORACLE_HRIS_PASSWORD` | `oracle-credentials/ORACLE_MGTHRIS_PASSWORD` | finance-service (both) |

**HRIS = MGTHRIS.** The HR dashboard ETL (data source `HRIS_ORACLE`) reads `MGTHRIS.VIEW_BI_ATT_DAILY`
/ `VIEW_BI_OT_DAILY` with the MGTHRIS account on the same Oracle instance. finance-service only
installs the HRIS runner when `ORACLE_HRIS_HOST/SERVICE/USER/PASSWORD` are all set; otherwise it logs
`Oracle HRIS not configured (ORACLE_HRIS_*)` at startup and HRIS jobs fail with
`ETL runner for data source HRIS_ORACLE is not configured or its connection is unavailable`.
The runner is registered only at startup -- restart the pod after fixing credentials.
Patch: `services/finance-service/overlays/{production,staging}/patches/env-oracle-hris.yaml`.

### Database

| Env var | Source (production) | Source (staging) | Used by |
|---------|--------------------|------------------|---------|
| `DATABASE_USER` | `finance-db-secret/APP_USER` or `iam-db-secret/APP_USER` | same | finance-service, finance-worker, finance-cost-worker, finance-cost-orchestrator, iam-service |
| `DATABASE_PASSWORD` | `<svc>-db-secret/APP_PASSWORD` | same | same as above |
| `PPC_DATABASE_USER` | `ppc-db-secret/APP_USER` | same | ppc-service |
| `PPC_DATABASE_PASSWORD` | `ppc-db-secret/APP_PASSWORD` | same | ppc-service |

### Auth / service tokens

| Env var | Source | Used by |
|---------|--------|---------|
| `JWT_ACCESS_SECRET` | `goapps-auth-secret/JWT_ACCESS_SECRET` | finance-service, iam-service, ppc-service |
| `JWT_REFRESH_SECRET` | `goapps-auth-secret/JWT_REFRESH_SECRET` | iam-service |
| `FINANCE_JWT_SERVICE_SECRET` | `goapps-auth-secret/JWT_ACCESS_SECRET` | finance-cost-orchestrator |
| `INTERNAL_SERVICE_TOKEN` | `goapps-internal-token/INTERNAL_SERVICE_TOKEN` | finance-service, finance-worker, iam-service |
| `JWT_SERVICE_SECRET` | `goapps-internal-token/INTERNAL_SERVICE_TOKEN` | finance-service |
| `SERVICE_AUTH_TOKEN` | `goapps-internal-token/INTERNAL_SERVICE_TOKEN` | finance-cost-worker |
| `FINANCE_INTERNAL_TOKEN` | `goapps-internal-token/INTERNAL_SERVICE_TOKEN` | frontend |
| `PPC_INTERNAL_TOKEN`, `PPC_JWT_SERVICE_SECRET` | `ppc-internal-token/PPC_INTERNAL_TOKEN` | ppc-service |
| `CHAT_MASTER_KEY` | `goapps-chat-secret/CHAT_MASTER_KEY` | iam-service |

### Storage, queue, mail

| Env var | Source | Used by |
|---------|--------|---------|
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | `minio-secret/MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | finance-service, finance-worker |
| `STORAGE_ACCESS_KEY` / `STORAGE_SECRET_KEY` | `minio-secret/MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | iam-service |
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | `rabbitmq-secret/<same name>` | finance-service, finance-worker, finance-cost-worker, finance-cost-orchestrator |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS` | `smtp-secret/<same name>` | iam-service |

## Adding a new credential

1. Check the tables above (and `jq 'keys'` on the live secret) -- the key may already exist, as
   `ORACLE_MGTHRIS_*` did before HRIS was wired.
2. Prefer mapping an existing key to the env name the app expects (`env[].valueFrom.secretKeyRef`)
   over creating a new secret or duplicating a value.
3. Put the mapping in an overlay patch (`overlays/<env>/patches/env-*.yaml`), never in base, and run
   `kustomize build` on the overlay.
4. A new key/secret has to be created on **each** cluster by hand **before** the sync, or the pod
   fails with `CreateContainerConfigError` (unless the ref is `optional: true`).
5. Update this file and the inventory in `CLAUDE.md` §12 in the same PR.
