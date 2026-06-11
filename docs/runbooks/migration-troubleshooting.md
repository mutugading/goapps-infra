# Migration Troubleshooting Runbook

## Overview

GoApps uses `golang-migrate` for database migrations. Migrations are run via Kubernetes Jobs, NOT automatically on service startup. Each service has its own migrations table:

| Service | Migrations Table | Migration Files |
|---------|-----------------|-----------------|
| Finance | `schema_migrations_finance` | `services/finance/migrations/postgres/` |
| IAM | `schema_migrations_iam` | `services/iam/migrations/postgres/` |

---

## How golang-migrate Works

Understanding this prevents most issues:

1. `schema_migrations_<service>` table has **exactly 1 row**: `(version, dirty)`
2. Before applying migration N, golang-migrate sets `version=N, dirty=true`
3. After successful apply, it sets `dirty=false`
4. On next run, it reads the current version and applies all migrations with version > current
5. **If dirty=true, it refuses to run** — you must fix manually

**Critical implication**: If you manually set `version=13`, golang-migrate assumes migrations 1-13 are ALL applied and skips them entirely. If any of those migrations were NOT actually applied, those tables/data will be missing silently.

---

## Standard Operating Procedure: Running Migrations

### Adding New Migrations (Normal Flow)

When a new migration is added to the codebase (e.g., new table, new seed data):

```bash
# 1. Merge PR to main
# 2. Wait for CI/CD to build and deploy new image
# 3. Verify new image is deployed
kubectl get deployment <service> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].image}'

# 4. Run migration
cd ~/goapps-infra
./scripts/<service>-setup.sh <namespace> migrate

# 5. Run seed (if new seed data was added)
./scripts/<service>-setup.sh <namespace> seed

# 6. Verify
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "SELECT version, dirty FROM schema_migrations_<service>;"
```

### First-Time Setup (New Environment)

```bash
# 1. Deploy service first (via ArgoCD or manual)
# 2. Run BOTH migrate AND seed
./scripts/<service>-setup.sh <namespace>    # runs migrate + seed

# 3. Verify all tables exist
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c "\dt mst_*"
```

---

## Problem: "Dirty database version N. Fix and force version."

### Symptoms

```
error: Dirty database version 2. Fix and force version.
```

Migration Job exits with code 1. All subsequent migration attempts fail with the same error.

### Root Cause

golang-migrate marks a version as `dirty=true` before applying a migration. If the migration crashes, times out, or the Job is killed mid-execution, the dirty flag is never cleared. This blocks all future migrations.

Common triggers:
- K8s Job timeout (default 120s in setup script)
- Pod OOM killed during migration
- Database connection lost mid-migration
- Tables already exist (created manually or by another process)

### Diagnosis

```bash
# 1. Check the dirty state
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "SELECT version, dirty FROM schema_migrations_<service>;"

# 2. Check migration pod logs for the actual error
kubectl logs -n <namespace> -l job-name=<service>-migrate

# 3. Check if the tables from that version already exist
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "\dt auth.*" -- or "\dt mst_*" depending on the migration
```

### Fix

**Case 1: Migration partially applied (some tables exist, some don't)**

```bash
# Manually complete the missing parts of the migration SQL
# Then set version to the completed version:
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "UPDATE schema_migrations_<service> SET version = <N>, dirty = false;"
```

**Case 2: All tables already exist but version is wrong (most common)**

This happens when migrations were applied outside of golang-migrate (manual SQL, first-time seed, etc.).

**IMPORTANT**: Do NOT blindly set version to the latest migration number. You must verify that ALL migrations up to that version have actually been applied. See the [verification checklist](#verifying-which-migrations-are-actually-applied) below.

```bash
# 1. Verify which migrations are actually applied (see checklist below)
# 2. Set version to the last VERIFIED applied migration:
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "UPDATE schema_migrations_<service> SET version = <last_verified>, dirty = false;"

# 3. Re-run to apply remaining migrations
kubectl delete job <service>-migrate -n <namespace> --ignore-not-found
./scripts/<service>-setup.sh <namespace> migrate
```

**Case 3: Multiple rows in schema_migrations table**

golang-migrate expects exactly 1 row. If there are multiple rows (e.g., from manual INSERT without DELETE), it reads the dirty one first and fails.

```bash
# Check row count
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "SELECT * FROM schema_migrations_<service>;"

# Fix: DELETE all rows, INSERT the correct single row
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "DELETE FROM schema_migrations_<service>;
   INSERT INTO schema_migrations_<service> (version, dirty) VALUES (<last_applied>, false);"
```

**Case 4: Migration genuinely failed (table creation error)**

```bash
# 1. Fix the underlying issue (e.g., drop partially created objects)
# 2. Reset dirty flag WITHOUT changing version
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "UPDATE schema_migrations_<service> SET dirty = false;"
# 3. Re-run migration
```

---

## Problem: "relation already exists"

### Symptoms

```
pq: relation "uq_user_username" already exists
```

### Root Cause

The migration tries to CREATE an index/table that already exists. This means the database state is ahead of what `schema_migrations` thinks.

### Fix

Set the version to match the actual database state (see Case 2 above).

---

## Problem: Migration Job times out

### Symptoms

```
error: timed out waiting for the condition on jobs/<service>-migrate
```

### Diagnosis

```bash
# Check pod status
kubectl get pods -n <namespace> -l job-name=<service>-migrate

# Check pod events
kubectl describe pod -n <namespace> -l job-name=<service>-migrate

# Check logs (even if timed out, pod may have logged something)
kubectl logs -n <namespace> -l job-name=<service>-migrate

# Common causes:
# - ImagePullBackOff: ghcr-secret missing or expired
# - Pending: insufficient resources
# - Error: migration SQL error (check logs)
# - OOMKilled: increase memory limits in migrate-job.yaml
# - Dirty version: see "Dirty database version" section above
```

---

## Problem: Seed Job fails with "relation does not exist"

### Symptoms

```
ERROR: relation "mst_cms_page" does not exist (SQLSTATE 42P01)
```

### Root Cause

The seed job tries to INSERT into a table that was never created. This happens when:
- Migration version was manually set too high, skipping CREATE TABLE migrations
- Migration job was never run, but seed job was attempted

### Fix

1. Identify which migration creates the missing table
2. Run that migration's SQL manually via psql
3. Re-run the seed job

```bash
# Example: CMS tables missing (migration 012)
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps
# Paste SQL from 000012_create_cms_tables.up.sql

# Then re-run seed
kubectl delete job iam-seed -n <namespace> --ignore-not-found
./scripts/iam-setup.sh <namespace> seed
```

---

## Verifying Which Migrations Are Actually Applied

**Before manually setting the migration version**, verify each migration's artifacts exist. This prevents silently skipping migrations that were never applied.

### IAM Service Migration Checklist

```bash
# Connect to psql
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps
```

| Migration | What to check | SQL to verify |
|-----------|--------------|---------------|
| 000001 | Organization tables | `\dt mst_company` — should exist |
| 000002 | User tables | `\dt mst_user` — should exist |
| 000003 | Auth tables | `\dt mst_auth_token` or `\dt auth.*` — should exist |
| 000004 | RBAC tables | `\dt mst_role` and `\dt mst_permission` — should exist |
| 000005 | Menu tables | `\dt mst_menu` and `\dt menu_permissions` — should exist |
| 000006 | Audit tables | `\dt mst_audit_log` — should exist |
| 000007 | Recovery codes | `\dt mst_recovery_code` — should exist |
| 000008 | User unique constraints fix | `\di uq_user_username` — should exist |
| 000009 | Seed menu data | `SELECT count(*) FROM mst_menu;` — should be > 0 |
| 000010 | Session idle timeout | `SELECT column_name FROM information_schema.columns WHERE table_name = 'mst_session' AND column_name = 'idle_timeout';` — should return 1 row |
| 000011 | RM Category menu seed | `SELECT menu_code FROM mst_menu WHERE menu_code = 'FINANCE_RM_CATEGORY';` — should return 1 row |
| 000012 | CMS tables | `\dt mst_cms_page` and `\dt mst_cms_section` and `\dt mst_cms_setting` — should exist |
| 000013 | CMS menu + permissions seed | `SELECT menu_code FROM mst_menu WHERE menu_code = 'ADMIN_CMS';` — should return 1 row |
| 000014 | Parameter menu + permissions seed | `SELECT permission_code FROM mst_permission WHERE permission_code = 'finance.master.parameter.view';` — should return 1 row |

### Finance Service Migration Checklist

| Migration | What to check | SQL to verify |
|-----------|--------------|---------------|
| 000001 | UOM tables | `\dt mst_uom` — should exist |
| 000002 | Audit logs | `\dt mst_audit_log` (in finance context) — should exist |
| 000003 | RM Category tables | `\dt mst_rm_category` — should exist |
| 000004 | Parameter tables | `\dt mst_parameter` — should exist |

### Quick Full Check (IAM)

```bash
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c "
  SELECT '001-org' as migration, EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_company') as applied
  UNION ALL SELECT '002-user', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_user')
  UNION ALL SELECT '003-auth', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_auth_token')
  UNION ALL SELECT '004-rbac', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_role')
  UNION ALL SELECT '005-menu', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_menu')
  UNION ALL SELECT '006-audit', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_audit_log')
  UNION ALL SELECT '007-recovery', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_recovery_code')
  UNION ALL SELECT '009-menu-seed', EXISTS(SELECT 1 FROM mst_menu WHERE menu_code = 'DASHBOARD')
  UNION ALL SELECT '012-cms-tables', EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'mst_cms_page')
  UNION ALL SELECT '013-cms-menu', EXISTS(SELECT 1 FROM mst_menu WHERE menu_code = 'ADMIN_CMS')
  UNION ALL SELECT '014-param-menu', EXISTS(SELECT 1 FROM mst_permission WHERE permission_code = 'finance.master.parameter.view')
  ORDER BY migration;
"
```

---

## Checking Current Migration Versions

```bash
# Both services at once
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "SELECT 'finance' as service, version, dirty FROM schema_migrations_finance
   UNION ALL
   SELECT 'iam', version, dirty FROM schema_migrations_iam;"
```

---

## Prevention

### For Developers Adding New Migrations

1. **Always use `IF NOT EXISTS` / `IF EXISTS`** in CREATE/DROP statements — makes migrations re-runnable
2. **Always use `ON CONFLICT DO NOTHING`** in seed INSERT statements — makes seeds idempotent
3. **Never skip migration numbers** — sequential numbering (000001, 000002, ...) is mandatory
4. **Every up migration must have a corresponding down migration**
5. **Never modify a merged migration** — create a new one to fix issues
6. **Test migration locally** before pushing: `make migrate-up` then `make migrate-down` then `make migrate-up` again

### For DevOps Running Migrations on VPS

1. **Always run migrate BEFORE seed** — seed depends on tables created by migration
2. **After merge + deploy, always run migration if new migration files were added**
3. **Check version before and after** running migrations:
   ```bash
   kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
     "SELECT version, dirty FROM schema_migrations_<service>;"
   ```
4. **If you need to manually fix version**, NEVER guess — use the [verification checklist](#verifying-which-migrations-are-actually-applied) to confirm which migrations are actually applied
5. **After fixing version manually**, set it to the last migration you VERIFIED exists, not the latest migration number. Let golang-migrate apply the rest.
6. **Always check BOTH staging AND production** — if one has a problem, the other likely does too
7. **Don't run migrations during ArgoCD sync** — wait for pods to stabilize first
8. **If seed fails**, check logs — it usually means a table is missing (migration was skipped)

### Workflow Checklist for New Features

When a PR adds new migration(s):

```
1. [ ] PR merged to main
2. [ ] CI/CD builds new Docker image
3. [ ] ArgoCD deploys new image (staging auto, production manual sync)
4. [ ] Verify new pods are Running: kubectl get pods -n <namespace>
5. [ ] Run migration: ./scripts/<service>-setup.sh <namespace> migrate
6. [ ] Verify migration version incremented: SELECT version FROM schema_migrations_<service>
7. [ ] Run seed (if needed): ./scripts/<service>-setup.sh <namespace> seed
8. [ ] Verify data in browser
9. [ ] Repeat steps 3-8 for production
```

---

## Incident History

| Date | Environment | Issue | Root Cause | Fix |
|------|-------------|-------|-----------|-----|
| 2026-04-07 | Staging | IAM migrate stuck at dirty version 1 | Tables created by seed job, not golang-migrate. `schema_migrations_iam` never properly initialized. | Set version=13, dirty=false. Then ran migration to apply 014. |
| 2026-04-07 | Staging | CMS tables missing (012) | Version manually set to 13, but migration 012 (CREATE TABLE) was never actually applied. | Ran 012 SQL manually via psql. |
| 2026-04-07 | Staging | Seed job fails: "mst_cms_page does not exist" | CMS tables not created (see above). Seed job depends on tables from migration 012. | Created tables first, then re-ran seed. |
| 2026-04-07 | Production | IAM migrate dirty version 1 + multiple rows | Same as staging + manual INSERT created 2 rows in schema_migrations_iam. | DELETE all rows, INSERT single row (version=13), then ran migration. |
| 2026-04-07 | Production | schema_migrations_iam "does not exist" | IAM migrations were never run via golang-migrate on production. | Created table manually, set version=13. |
