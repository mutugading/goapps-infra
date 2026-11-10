# scripts/postgres

## new-service-db.sh

Provisions the PostgreSQL side of a new service (ADR 0001: 1 service = 1 DB):
roles `<svc>_owner|_app|_ro`, `<svc>_db`, grants (reuses `20-db-grants.sql`),
pg_hba, monitoring (exporter + monitor conn limit), backup list, verification,
and prints the follow-up block (K8s secret, PgBouncer userlist, repo edits).

```bash
./new-service-db.sh <svc> --target local|staging|production [--apply] [--app-conn-limit N] [--sql-dir DIR]
```

- Default is a **dry-run**; nothing changes without `--apply`.
- `local`: run from the laptop against container `goapps-v2-postgres`
  (`export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock`); dev passwords
  `dev_<svc>_owner|app`; skips pg_hba/exporter/backup. Add the printed lines to
  `goapps-backend/deploy/local-v2/pgbouncer/{userlist.txt,pgbouncer.ini}` yourself.
- `staging|production`: run **on the VPS** (`sudo bash new-service-db.sh <svc> --target staging --apply`).
  Refuses unless `hostname -I` has .60 (staging) / .40 (prod). `--force-host` is for dry-run review only.
  Passwords are prompted (twice, hidden) and sent to psql via stdin.
  Before first use copy the SQL:
  `sudo install -D docs/migration-postgres/v2/sql/20-db-grants.sql /usr/local/share/goapps/sql/20-db-grants.sql`
  (or pass `--sql-dir`).
- Every step is idempotent and logs `[step N] ... OK|SKIP`; step 7 verifies and exits 1 on FAIL.
  Config edits keep `.bak-<svc>-<ts>` backups; an invalid pg_hba is restored automatically.
- `iam|finance|ppc` are refused unless `--allow-existing`.
- `--drop --apply` reverses everything (only for `p8btest*` svc unless `--i-know`). Use for throwaway tests.

See `docs/migration-postgres/v2/monitoring-new-service-db.md` for the monitoring verify block.
