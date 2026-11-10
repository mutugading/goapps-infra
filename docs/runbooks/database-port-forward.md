# Runbook — Connecting to the databases

For inspecting `iam_db`, `finance_db` and `ppc_db` from `psql`, GoLand/DataGrip, or any local client.

---

## 1. Topology you are connecting to

PostgreSQL 18 no longer runs in Kubernetes. It runs on dedicated VPS hosts, so there is **no tunnel or `kubectl port-forward` to `postgres-0` anymore**.

| Env | Host | Port |
|---|---|---|
| Production | `192.168.0.40` | 5432 |
| Staging | `192.168.0.60` | 5432 |

- **One database per service** (ADR 0001): `iam_db`, `finance_db`, `ppc_db`. Each has roles `<svc>_owner` (migrations/seeds), `<svc>_app` (runtime), `<svc>_ro` (read-only).
- TLS is mandatory (`hostssl`, scram-sha-256); `pg_hba` only admits the LAN `192.168.0.0/24`.
- Passwords are in the team password manager under `goapps/<env>/postgres/<role>`. Never paste a secret into chat, a ticket, or a commit.

---

## 2. Connect from the LAN

```bash
# read-only inspection (default choice)
psql "host=192.168.0.60 port=5432 dbname=finance_db user=finance_ro sslmode=require"
psql "host=192.168.0.60 port=5432 dbname=ppc_db user=ppc_ro sslmode=require"
psql "host=192.168.0.60 port=5432 dbname=iam_db user=iam_ro sslmode=require"
```

Production: same commands with host `192.168.0.40`.

GoLand / DataGrip: Host `192.168.0.60|40`, Port `5432`, Database `<svc>_db`, User `<svc>_ro`, **SSL mode `require`**. The certificate is `*.mutugading.com`, which does not match an IP, so do not use `verify-full`.

Use `<svc>_owner` only for DDL/migration repair, and never a superuser from apps.

---

## 3. Connect from outside the LAN

Tunnel through the VPS host over SSH (user `hom`):

```bash
ssh -L 15432:localhost:5432 hom@192.168.0.60      # staging
ssh -L 15433:localhost:5432 hom@192.168.0.40      # production
```

Then connect to `host=localhost port=15432` (or `15433`) with `sslmode=require`. Distinct local ports let both tunnels live at once; `Ctrl-C` closes the tunnel.

On the VPS itself you can also use `sudo -u postgres psql -d <svc>_db`.

### Why not via `pgbouncer-vps`

Apps go through `pgbouncer-vps` (transaction pooling), which breaks session-level features in GUI clients (`\d`, temp tables, `SET`). The app-to-`pgbouncer-vps` hop is in-cluster with `sslmode=disable` (PgBouncer then uses TLS to the VPS); only direct connections to the VPS IP (admin psql/DataGrip, migrate/seed jobs as `<svc>_owner`) use `sslmode=require`. For manual inspection always connect straight to the VPS.

---

## 4. Verifying migration state

Each database has its own version table:

```bash
psql "host=192.168.0.60 dbname=ppc_db user=ppc_ro sslmode=require" \
  -c "SELECT version, dirty FROM schema_migrations_ppc;"
psql "host=192.168.0.60 dbname=iam_db user=iam_ro sslmode=require" \
  -c "SELECT version, dirty FROM schema_migrations_iam;"
psql "host=192.168.0.60 dbname=finance_db user=finance_ro sslmode=require" \
  -c "SELECT version, dirty FROM schema_migrations_finance;"
```

A missing sidebar menu for a new service is almost always the IAM migration lagging — see CLAUDE.md §15 Step 9.

---

## 5. Cautions

- Prefer the `_ro` role; `_owner` has write access to production data.
- A GUI client holds connections open. Close idle sessions rather than leaving a project connected overnight.
