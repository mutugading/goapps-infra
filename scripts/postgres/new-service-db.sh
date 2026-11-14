#!/usr/bin/env bash
# new-service-db.sh — provision (or --drop) the PostgreSQL side of a new service:
# roles, database, grants, pg_hba, monitoring, backups, verification.
# Default is DRY-RUN; pass --apply to execute. See README.md.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <svc> --target local|staging|production [options]
  --apply               execute (default: dry-run, prints steps only)
  --app-conn-limit N    CONNECTION LIMIT for <svc>_app (default 60)
  --sql-dir DIR         dir holding 20-db-grants.sql (VPS default /usr/local/share/goapps/sql;
                        local always uses /v2/sql inside the container)
  --force-host          skip the VPS host-IP guard (dry-run review only)
  --allow-existing      allow svc iam|finance|ppc (idempotency testing)
  --drop                reverse everything (needs --apply; svc must start with p8btest or --i-know)
  --i-know              permit --drop for any svc
USAGE
}

SVC="" TARGET="" APPLY=0 APP_LIMIT=60 SQL_DIR="/usr/local/share/goapps/sql"
FORCE_HOST=0 ALLOW_EXISTING=0 DROP=0 IKNOW=0

if [[ $# -lt 1 ]]; then usage; exit 2; fi
SVC="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --app-conn-limit) APP_LIMIT="${2:-}"; shift 2 ;;
    --sql-dir) SQL_DIR="${2:-}"; shift 2 ;;
    --force-host) FORCE_HOST=1; shift ;;
    --allow-existing) ALLOW_EXISTING=1; shift ;;
    --drop) DROP=1; shift ;;
    --i-know) IKNOW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$SVC" =~ ^[a-z][a-z0-9]{1,20}$ ]] || die "svc must match ^[a-z][a-z0-9]{1,20}\$"
if [[ "$SVC" =~ ^(iam|finance|ppc)$ && $ALLOW_EXISTING -eq 0 ]]; then
  die "svc '$SVC' already exists in production; use --allow-existing only for idempotency tests"
fi
[[ "$APP_LIMIT" =~ ^[0-9]+$ ]] || die "--app-conn-limit must be an integer"
case "$TARGET" in local|staging|production) ;; *) die "--target local|staging|production required" ;; esac
if [[ $DROP -eq 1 && "$SVC" != p8btest* && $IKNOW -eq 0 ]]; then
  die "--drop only for svc starting with p8btest unless --i-know"
fi

DB="${SVC}_db" OWNER="${SVC}_owner" APP="${SVC}_app" RO="${SVC}_ro"
DRY=$((1 - APPLY))
PW_OWNER="" PW_APP=""
FAILS=0

case "$TARGET" in
  local) VPS=0 ; EXPECT_IP="" ;;
  staging) VPS=1; EXPECT_IP="192.168.0.60" ;;
  production) VPS=1; EXPECT_IP="192.168.0.40" ;;
esac

HBA="/etc/postgresql/18/main/pg_hba.conf"
# per-DB monitor line (B6.6c): "host iam_db,finance_db,ppc_db monitor 127.0.0.1/32 ..." -- NOT the "host postgres monitor ..." line
MON_RE='^host[[:space:]]+[^[:space:]]*_db[^[:space:]]*[[:space:]]+monitor[[:space:]]+127\.0\.0\.1/32'
EXPORTER_ENV="/etc/default/prometheus-postgres-exporter"
BACKUP_ENV="/etc/goapps/pg-backup.env"
TS="$(date +%Y%m%d-%H%M%S)"

if [[ $VPS -eq 1 ]]; then
  if [[ $FORCE_HOST -eq 0 ]]; then
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$EXPECT_IP" \
      || die "this host does not have IP $EXPECT_IP ($TARGET); run on the VPS (or --force-host for dry-run review)"
  elif [[ $APPLY -eq 1 ]]; then
    die "--force-host is for dry-run review only; refusing with --apply"
  fi
fi

say() { echo "$*"; }
dry() { echo "  [dry-run] $*"; }
step() { echo "[step $1] $2"; }

# psql as superuser. stdin is passed through.
pg() {
  if [[ $VPS -eq 1 ]]; then
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i goapps-v2-postgres psql -X -v ON_ERROR_STOP=1 -U postgres "$@"
  fi
}
pgq() { pg -At "$@"; } # quiet scalar queries

# run_sql <db> <sql>: dry-run prints it; apply feeds it on stdin with passwords as hidden \set lines.
run_sql() {
  local db="$1" sql="$2"
  if [[ $DRY -eq 1 ]]; then
    dry "psql -d $db -v svc=$SVC  <<'SQL'   (pw_owner/pw_app \set from stdin, hidden)"
    printf '%s\n' "$sql" | sed 's/^/      /'
    return 0
  fi
  {
    printf '\\set pw_owner '"'"'%s'"'"'\n\\set pw_app '"'"'%s'"'"'\n' "$PW_OWNER" "$PW_APP"
    printf '%s\n' "$sql"
  } | pg -d "$db" -v "svc=$SVC" -v "applimit=$APP_LIMIT" -q
}


role_exists() { [[ "$(pgq -c "SELECT 1 FROM pg_roles WHERE rolname='$1'")" == "1" ]]; }
db_exists() { [[ "$(pgq -c "SELECT 1 FROM pg_database WHERE datname='$1'")" == "1" ]]; }

read_pw() { # read_pw <label> -> sets REPLY_PW
  local a b
  while true; do
    read -rsp "Password for $1: " a; echo >&2
    read -rsp "Confirm password for $1: " b; echo >&2
    [[ -n "$a" && "$a" == "$b" ]] || { echo "empty or mismatch, retry" >&2; continue; }
    [[ "$a" != *\'* && "$a" != *\\* ]] || { echo "password must not contain ' or \\" >&2; continue; }
    REPLY_PW="$a"; return 0
  done
}

HEADER() { say "== new-service-db: svc=$SVC target=$TARGET mode=$([[ $DRY -eq 1 ]] && echo DRY-RUN || echo APPLY)$([[ $DROP -eq 1 ]] && echo ' DROP')"; }

monitor_limit() { # 2 + number of app DBs + 1
  local n
  n="$(pgq -c "SELECT count(*) FROM pg_database WHERE datname LIKE '%\\_db' AND NOT datistemplate AND datname <> 'postgres'")"
  echo $((2 + n + 1))
}

# ------------------------------------------------------------------ DROP ----
do_drop() {
  [[ $APPLY -eq 1 ]] || say "(dry-run: nothing will be dropped; add --apply)"
  step 1 "terminate connections + DROP DATABASE $DB"
  if [[ $DRY -eq 1 ]]; then
    dry "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB'"
    dry "DROP DATABASE IF EXISTS $DB"
  else
    pgq -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB'" >/dev/null
    pg -q -c "DROP DATABASE IF EXISTS \"$DB\""; say "  OK"
  fi
  step 2 "DROP ROLE $APP, $OWNER, $RO"
  if [[ $DRY -eq 1 ]]; then dry "DROP ROLE IF EXISTS $APP; DROP ROLE IF EXISTS $OWNER; DROP ROLE IF EXISTS $RO"
  else
    for r in "$APP" "$OWNER" "$RO"; do pg -q -c "DROP ROLE IF EXISTS \"$r\""; done; say "  OK"
  fi
  if [[ $VPS -eq 1 ]]; then
    step 3 "remove pg_hba / monitor / exporter / backup entries"
    if [[ $DRY -eq 1 ]]; then
      dry "backup $HBA -> $HBA.bak-$SVC-drop-$TS; delete 'hostssl $DB ...' line; strip ,$DB from monitor line; reload"
      dry "strip $DB from $EXPORTER_ENV (restart exporter) and from DATABASES in $BACKUP_ENV; recompute monitor CONNECTION LIMIT"
    else
      sudo cp -p "$HBA" "$HBA.bak-$SVC-drop-$TS"
      sudo sed -i -E "/^hostssl[[:space:]]+${DB}[[:space:]]/d; /${MON_RE//\//\\/}/ s/,${DB}\b//" "$HBA"
      sudo -u postgres psql -X -qAt -c "SELECT pg_reload_conf()" >/dev/null
      if [[ -f "$EXPORTER_ENV" ]]; then
        sudo sed -i -E "s/,${DB}\b//" "$EXPORTER_ENV"; sudo systemctl restart prometheus-postgres-exporter
      fi
      [[ -f "$BACKUP_ENV" ]] && sudo sed -i -E "/^DATABASES=/ s/[[:space:]]+${DB}\b//" "$BACKUP_ENV"
      pg -q -c "ALTER ROLE monitor CONNECTION LIMIT $(monitor_limit)"
      say "  OK"
    fi
  fi
  say "drop done."
}

# ----------------------------------------------------------------- steps ----
step1_roles() {
  step 1 "roles ($OWNER, $APP, $RO) + settings + dba grants"
  local have=0
  if [[ $DRY -eq 0 ]]; then
    role_exists "$OWNER" && have=$((have+1)); role_exists "$APP" && have=$((have+1)); role_exists "$RO" && have=$((have+1))
    if [[ $have -lt 3 ]]; then
      if [[ $TARGET == local ]]; then PW_OWNER="dev_${SVC}_owner"; PW_APP="dev_${SVC}_app"
      else read_pw "$OWNER"; PW_OWNER="$REPLY_PW"; read_pw "$APP"; PW_APP="$REPLY_PW"; fi
    fi
  fi
  run_sql postgres "$(cat <<'SQL'
\set owner :svc '_owner'
\set app   :svc '_app'
\set ro    :svc '_ro'
SELECT to_regrole(:'owner') IS NOT NULL AS o_ex, to_regrole(:'app') IS NOT NULL AS a_ex,
       to_regrole(:'ro') IS NOT NULL AS r_ex, to_regrole('dba_read') IS NOT NULL AS dr,
       to_regrole('dba_write') IS NOT NULL AS dw \gset
\if :o_ex
\else
  CREATE ROLE :"owner" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 5 PASSWORD :'pw_owner';
\endif
\if :a_ex
\else
  CREATE ROLE :"app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT CONNECTION LIMIT :applimit PASSWORD :'pw_app';
\endif
\if :r_ex
\else
  CREATE ROLE :"ro" NOLOGIN;
\endif
-- re-assert attributes (idempotent; passwords untouched for pre-existing roles)
ALTER ROLE :"owner" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 5;
ALTER ROLE :"owner" SET lock_timeout = '10s';
ALTER ROLE :"app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT CONNECTION LIMIT :applimit;
ALTER ROLE :"app" SET idle_in_transaction_session_timeout = '5min';
ALTER ROLE :"ro" NOLOGIN;
\if :dr
  GRANT :"ro" TO dba_read;
\else
  \echo   dba_read absent: skipped
\endif
\if :dw
  GRANT :"owner" TO dba_write WITH INHERIT FALSE, SET TRUE;
\else
  \echo   dba_write absent: skipped
\endif
SQL
)"
  if [[ $DRY -eq 0 ]]; then
    if [[ $have -eq 3 ]]; then say "  SKIP (roles existed; attributes re-asserted)"; else say "  OK"; fi
  fi
}

step2_db() {
  step 2 "database $DB + extensions"
  if [[ $DRY -eq 0 ]] && db_exists "$DB"; then
    say "  database exists (SKIP create)"
  fi
  run_sql postgres "$(cat <<'SQL'
\set db    :svc '_db'
\set owner :svc '_owner'
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') AS d_ex \gset
SELECT datcollate AS lc, datctype AS ct FROM pg_database
 WHERE datname IN ('iam_db','template1') ORDER BY (datname = 'iam_db') DESC LIMIT 1 \gset
\if :d_ex
\else
  CREATE DATABASE :"db" OWNER :"owner" TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE :'lc' LC_CTYPE :'ct';
\endif
SQL
)"
  run_sql "$DB" 'CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'
  [[ $DRY -eq 1 ]] || say "  OK"
}

step3_grants() {
  step 3 "20-db-grants.sql -v svc=$SVC on $DB"
  if [[ $TARGET == local ]]; then
    if [[ $DRY -eq 1 ]]; then dry "docker exec -i goapps-v2-postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d $DB -v svc=$SVC -f /v2/sql/20-db-grants.sql"; return; fi
    pg -q -d "$DB" -v "svc=$SVC" -f /v2/sql/20-db-grants.sql
  else
    local f="$SQL_DIR/20-db-grants.sql"
    if [[ $DRY -eq 1 ]]; then dry "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d $DB -v svc=$SVC -f $f   (must exist; copy from docs/migration-postgres/v2/sql/)"; return; fi
    [[ -r "$f" ]] || die "$f not found/readable; copy docs/migration-postgres/v2/sql/20-db-grants.sql there or pass --sql-dir"
    # postgres user must read it: feed via stdin
    sudo cat "$f" | pg -q -d "$DB" -v "svc=$SVC"
  fi
  say "  OK"
}

step4_hba() {
  step 4 "pg_hba entry + monitor line + reload"
  if [[ $TARGET == local ]]; then say "  SKIP (local: no pg_hba edits)"; return; fi
  if [[ $DRY -eq 1 ]]; then
    dry "cp -p $HBA $HBA.bak-$SVC-$TS"
    dry "insert before '^hostssl all ilham,...': hostssl  $DB  $APP,$OWNER  192.168.0.0/24  scram-sha-256"
    dry "append ,$DB to DATABASE column of the 'host ... monitor 127.0.0.1/32' line"
    dry "SELECT pg_reload_conf(); check pg_hba_file_rules errors, restore backup + exit 1 on error"
    return
  fi
  local bak="$HBA.bak-$SVC-$TS" changed=0
  sudo cp -p "$HBA" "$bak"
  if sudo grep -qE "^hostssl[[:space:]]+${DB}[[:space:]]" "$HBA"; then
    say "  hba line present (SKIP)"
  else
    sudo grep -qE '^hostssl[[:space:]]+all[[:space:]]+ilham' "$HBA" || die "anchor line 'hostssl all ilham,...' not found in $HBA"
    sudo sed -i -E "/^hostssl[[:space:]]+all[[:space:]]+ilham/ i hostssl  ${DB}  ${APP},${OWNER}  192.168.0.0/24  scram-sha-256" "$HBA"
    changed=1
  fi
  if sudo grep -E "$MON_RE" "$HBA" | grep -qE "(^|[[:space:],])${DB}([[:space:],]|$)"; then
    say "  monitor line already lists $DB (SKIP)"
  else
    [[ "$(sudo grep -cE "$MON_RE" "$HBA")" == 1 ]] || die "expected exactly one 'host <..._db,...> monitor 127.0.0.1/32' line in $HBA"
    sudo sed -i -E "/${MON_RE//\//\\/}/ s/^(host[[:space:]]+[^[:space:]]+)/\1,${DB}/" "$HBA"
    changed=1
  fi
  if [[ $changed -eq 0 ]]; then sudo rm -f "$bak"; say "  SKIP (no change)"; return; fi
  pgq -c "SELECT pg_reload_conf()" >/dev/null
  sleep 1
  local errs
  errs="$(pgq -c "SELECT line_number||': '||error FROM pg_hba_file_rules WHERE error IS NOT NULL")"
  if [[ -n "$errs" ]]; then
    echo "pg_hba errors: $errs" >&2
    sudo cp -p "$bak" "$HBA"; pgq -c "SELECT pg_reload_conf()" >/dev/null
    die "pg_hba invalid; restored $bak and reloaded"
  fi
  say "  OK (backup $bak)"
}

step5_monitor() {
  step 5 "monitor connection limit + exporter include-databases"
  if [[ $TARGET == local ]]; then say "  SKIP (local: no exporter)"; return; fi
  if [[ $DRY -eq 1 ]]; then
    dry "ALTER ROLE monitor CONNECTION LIMIT <2 + count(*_db) + 1>"
    dry "append ,$DB to --include-databases= in $EXPORTER_ENV (backup first); systemctl restart prometheus-postgres-exporter"
    return
  fi
  local lim; lim="$(monitor_limit)"
  pg -q -c "ALTER ROLE monitor CONNECTION LIMIT $lim"
  say "  monitor limit = $lim"
  [[ -f "$EXPORTER_ENV" ]] || { say "  WARN $EXPORTER_ENV missing (SKIP exporter)"; return; }
  if sudo grep -qE "include-databases=[^ \"']*\b${DB}\b" "$EXPORTER_ENV"; then
    say "  exporter already lists $DB (SKIP)"
  else
    sudo grep -q 'include-databases=' "$EXPORTER_ENV" || die "no --include-databases= in $EXPORTER_ENV; edit manually"
    sudo cp -p "$EXPORTER_ENV" "$EXPORTER_ENV.bak-$SVC-$TS"
    sudo sed -i -E "s/(include-databases=[^ \"']*)/\1,${DB}/" "$EXPORTER_ENV"
    sudo systemctl restart prometheus-postgres-exporter
    say "  OK (exporter restarted)"
  fi
}

step6_backup() {
  step 6 "pg-backup.env DATABASES"
  if [[ $TARGET == local ]]; then say "  SKIP (local: no pg-backup)"; return; fi
  if [[ $DRY -eq 1 ]]; then dry "cp -p $BACKUP_ENV $BACKUP_ENV.bak-$SVC-$TS; append ' $DB' to DATABASES=\"...\" if missing"; return; fi
  [[ -f "$BACKUP_ENV" ]] || die "$BACKUP_ENV not found"
  if sudo grep -E '^DATABASES=' "$BACKUP_ENV" | grep -qE "(^|[[:space:]\"=])${DB}([[:space:]\"]|$)"; then
    say "  SKIP ($DB already listed)"
  else
    sudo grep -qE '^DATABASES="' "$BACKUP_ENV" || die "DATABASES=\"...\" line not found in $BACKUP_ENV"
    sudo cp -p "$BACKUP_ENV" "$BACKUP_ENV.bak-$SVC-$TS"
    sudo sed -i -E "/^DATABASES=\"/ s/\"[[:space:]]*\$/ ${DB}\"/" "$BACKUP_ENV"
    say "  OK"
  fi
}

check() { # check <name> <db> <expected> <sql>
  local got
  got="$(pgq -d "$2" -c "$4" 2>&1 || true)"
  if [[ "$got" == "$3" ]]; then say "  PASS $1"; else say "  FAIL $1 (got '$got', want '$3')"; FAILS=$((FAILS+1)); fi
}

step7_verify() {
  step 7 "verify"
  if [[ $DRY -eq 1 ]]; then
    dry "check role attrs (owner true|false|false|5, app true|false|true|$APP_LIMIT, ro f), db owner, CONNECT for app/ro/monitor,"
    dry "ro default privileges are SELECT-only, pg_hba_file_rules has $DB line and no errors (VPS)"
    return
  fi
  check "owner attrs" postgres "true|false|false|5" "SELECT rolcanlogin||'|'||rolsuper||'|'||rolinherit||'|'||rolconnlimit FROM pg_roles WHERE rolname='$OWNER'"
  check "app attrs" postgres "true|false|true|$APP_LIMIT" "SELECT rolcanlogin||'|'||rolsuper||'|'||rolinherit||'|'||rolconnlimit FROM pg_roles WHERE rolname='$APP'"
  check "ro attrs (nologin)" postgres "f" "SELECT rolcanlogin FROM pg_roles WHERE rolname='$RO'"
  check "db owner" postgres "$OWNER" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'"
  check "app CONNECT" postgres "t" "SELECT has_database_privilege('$APP','$DB','CONNECT')"
  check "ro CONNECT" postgres "t" "SELECT has_database_privilege('$RO','$DB','CONNECT')"
  check "monitor CONNECT" postgres "t" "SELECT has_database_privilege('monitor','$DB','CONNECT')"
  check "PUBLIC no CONNECT" postgres "0" "SELECT count(*) FROM pg_database d, aclexplode(d.datacl) a WHERE d.datname='$DB' AND a.grantee=0"
  check "ro default privs SELECT-only" "$DB" "0" "SELECT count(*) FROM pg_default_acl d, aclexplode(d.defaclacl) a WHERE a.grantee='$RO'::regrole AND a.privilege_type<>'SELECT' AND d.defaclobjtype='r'"
  check "ro has default SELECT" "$DB" "t" "SELECT count(*)>0 FROM pg_default_acl d, aclexplode(d.defaclacl) a WHERE a.grantee='$RO'::regrole AND a.privilege_type='SELECT'"
  if [[ $VPS -eq 1 ]]; then
    check "pg_hba has $DB line" postgres "1" "SELECT count(*) FROM pg_hba_file_rules WHERE '$DB'=ANY(database) AND '$APP'=ANY(user_name) AND error IS NULL"
    check "pg_hba no errors" postgres "0" "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL"
  fi
  if [[ $FAILS -gt 0 ]]; then say "VERIFY: FAIL ($FAILS)"; exit 1; fi
  say "VERIFY: PASS"
}

step8_followup() {
  local ns ip
  ns="goapps-staging"; ip="192.168.0.60"
  if [[ $TARGET == production ]]; then ns="goapps-production"; ip="192.168.0.40"; fi
  step 8 "follow-up (printed, NOT executed)"
  if [[ $TARGET == local ]]; then
    cat <<EOT

# --- local PgBouncer (goapps-backend/deploy/local-v2/pgbouncer) ---
# userlist.txt:
"${APP}" "dev_${SVC}_app"
# pgbouncer.ini [databases]:
${DB} = host=postgres-v2 port=5432 dbname=${DB}
# then: docker restart goapps-v2-pgbouncer
EOT
    return
  fi
  cat <<EOT

# ---- 1. Kubernetes secret (run from a kubectl-enabled machine) ----
read -rsp 'OWNER password: ' OWNER_PW; echo
read -rsp 'APP password: ' APP_PW; echo
kubectl -n ${ns} create secret generic ${SVC}-db-secret \\
  --from-literal=APP_USER=${APP} --from-literal=APP_PASSWORD="\$APP_PW" \\
  --from-literal=OWNER_USER=${OWNER} --from-literal=OWNER_PASSWORD="\$OWNER_PW" \\
  --dry-run=client -o yaml | kubectl apply -f -

# ---- 2. pgbouncer-vps-userlist (ns database, key userlist.txt) ----
# Add the line:  "${APP}" "<app password>"
# Recreate the secret from the full userlist (existing lines + new) and restart
# pgbouncer-vps: see docs/migration-postgres/v2/p6-guide.md A1.

# ---- 3. Repo edits (goapps-infra, via PR) ----
# overlays/${TARGET}/pgbouncer-vps/pgbouncer.ini  [databases]:
${DB} = host=${ip} port=5432 dbname=${DB} pool_size=4 reserve_pool=2 max_db_connections=6
# base/monitoring/dashboards/grafana-dashboard-postgres-vps-configmap.yaml : add ${DB} to the datname regex
# base/monitoring/alert-rules/postgres-vps-alerts.yaml : add ${DB} to the iam_db|finance_db|ppc_db regex

# ---- 4. Verify monitoring ----
# docs/migration-postgres/v2/monitoring-new-service-db.md (verify block)
EOT
}

# ------------------------------------------------------------------ main ----
HEADER
[[ $VPS -eq 0 && $DRY -eq 0 ]] && ! docker ps --format '{{.Names}}' | grep -qx goapps-v2-postgres && die "container goapps-v2-postgres not running (export DOCKER_HOST for colima?)"

if [[ $DROP -eq 1 ]]; then do_drop; exit 0; fi

step1_roles
step2_db
step3_grants
step4_hba
step5_monitor
step6_backup
step7_verify
step8_followup
[[ $DRY -eq 1 ]] && say "(dry-run complete: nothing changed; add --apply)"
exit 0
