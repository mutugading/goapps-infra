#!/usr/bin/env bash
# Shared helpers for *-setup.sh.
#
# The in-cluster PostgreSQL (pod postgres-0) and its postgres-backup-* CronJobs
# were removed; Postgres runs on the VPS behind pgbouncer-vps and backups run
# there via systemd (pg-backup.timer). The old pre-flight check (active
# postgres-backup-* Job / pg_dump sessions via kubectl exec) can no longer see
# the database, so guard_no_backup_running is now a no-op kept for the callers.
# The migrate Job still sets lock_timeout=10s, so a lock wait behind a VPS
# pg_dump fails fast instead of hanging.
#
# Env (accepted, ignored): FORCE_MIGRATE, WAIT_FOR_BACKUP.

guard_no_backup_running() {
  echo "==> Backup guard: Postgres backups run on the VPS (pg-backup.timer); not checked from the cluster."
  echo "    migrate Job uses lock_timeout=10s and fails fast if blocked by a running pg_dump."
  return 0
}

# $1 job name, $2 service short name (finance|iam|ppc), $3 namespace
migrate_failure_diagnostics() {
  local job="$1" svc="$2" ns="$3"
  echo "==> DIAGNOSTICS for $job"
  kubectl get job "$job" -n "$ns" -o wide || true
  kubectl get pods -n "$ns" -l job-name="$job" -o wide || true
  echo "--- last logs"
  kubectl logs "job/$job" -n "$ns" --tail=30 || true
  cat <<EOT
==> NOTE: the Job may STILL BE RUNNING (backoff retries) after this script gives up.
    Delete it safely (only after confirming no lock holder you need):
      kubectl delete job $job -n $ns
    golang-migrate is transactional per file; check state afterwards on the VPS
    (psql on the direct Postgres port, as the <svc>_owner role):
      SELECT * FROM schema_migrations_$svc;
    Also check VPS pg_stat_activity for pg_dump / lock waits.
    If dirty=true, fix per CLAUDE.md (set dirty=false / force the version) before re-running.
EOT
}
