#!/usr/bin/env bash
# Guard: every staging/production service overlay (and its jobs/ overlay) must
# point at the right VPS database (ADR 0001: one DB per service).
#
# Approach: `kustomize build` each overlay, then parse the rendered output with
# python3 (stdlib only, run with -I). kustomize emits normalised block-style
# YAML, so a small line parser is enough and avoids needing PyYAML or yq in CI.
# jobs/ overlays reference ../../../base/*.yaml files, so they need
# `--load-restrictor LoadRestrictionsNone`.
#
# Also: any env DSN (`dbname=` / postgres:// URL) must name <db>_db, and the
# pgbouncer-vps [databases] keys per env must be exactly the service DBs.
#
# Usage: scripts/ci/check-db-overlays.sh [repo-root]   (needs kustomize, python3)
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${ROOT}"

svc_db() {
  case "$1" in
    iam-service) echo iam ;;
    finance-service | finance-worker | finance-cost-worker | finance-cost-orchestrator) echo finance ;;
    ppc-service) echo ppc ;;
    payroll-service) echo payroll ;;
    frontend) echo none ;;
    *) echo "" ;;
  esac
}
vps_ip() { if [ "$1" = staging ]; then echo 192.168.0.60; else echo 192.168.0.40; fi; }

read -r -d '' PYCHECK <<'PY' || true
import re, sys
path, env, svc_dir, db, ip = sys.argv[1:6]
other = {"staging": "192.168.0.40", "production": "192.168.0.60"}[env]
PGB = "pgbouncer-vps.database.svc.cluster.local"
VAR = re.compile(r"^(?:[A-Z]+_)?(DATABASE_(HOST|NAME|USER|PASSWORD|URL)|PG(HOST|DATABASE|USER|PASSWORD))$")
text = open(path).read()
viol, objs = [], []
for bad in ("postgres.database.svc", "pgbouncer.database.svc", "postgres-secret", "stgapps"):
    if bad in text:
        viol.append(f"forbidden string '{bad}' in rendered output")
if other in text:
    viol.append(f"{env} render contains {other}")
for doc in re.split(r"(?m)^---\s*$", text):
    m = re.search(r"(?m)^kind: (\S+)", doc)
    if not m or m.group(1) not in ("Deployment", "Job", "CronJob"):
        continue
    kind = m.group(1)
    n = re.search(r"(?m)^metadata:\n(?:  .*\n)*?  name: (\S+)", doc)
    oid = f"{kind}/{n.group(1) if n else '?'}"
    objs.append(oid)
    job = kind != "Deployment"
    # Any env value carrying a DSN (keyword `dbname=` or postgres:// URL) must
    # target this service's DB, whatever the variable is called (e.g. the
    # payroll CLI Jobs build PAYROLL_*_DSN from a template).
    if db != "none":
        for val in re.findall(r"(?m)^\s*value: (.*)$", doc):
            for got in re.findall(r"\bdbname=([^\s'\"]+)", val):
                if got != f"{db}_db":
                    viol.append(f"{oid} DSN dbname='{got}', want '{db}_db'")
            for got in re.findall(r"postgres(?:ql)?://[^/\s]*/([^?\s'\"]*)", val):
                if got != f"{db}_db":
                    viol.append(f"{oid} URL db='{got}', want '{db}_db'")
    lines = doc.split("\n")
    i = 0
    while i < len(lines):
        d = re.match(r"^(\s*)- name: (\S+)\s*$", lines[i])
        if not d:
            i += 1
            continue
        ind, name = len(d.group(1)), d.group(2)
        blk = []
        i += 1
        while i < len(lines) and lines[i].strip() and (len(lines[i]) - len(lines[i].lstrip())) > ind:
            blk.append(lines[i].strip())
            i += 1
        if not VAR.match(name):
            continue
        b = "\n".join(blk)
        val = re.search(r"^value: (.*)$", b, re.M)
        val = val.group(1).strip().strip('"') if val else None
        key = re.search(r"^key: (\S+)", b, re.M)
        sec = re.search(r"^name: (\S+)", b, re.M)
        key = key.group(1) if key else None
        sec = sec.group(1) if sec else None
        base = re.sub(r"^[A-Z]+_(?=DATABASE_)", "", name)
        v = lambda msg: viol.append(f"{oid} {name}: {msg}")
        if db == "none":
            v("DATABASE/PG env not allowed for this service")
            continue
        if base in ("DATABASE_HOST", "PGHOST"):
            want = ip if job else PGB
            if val != want:
                v(f"host is '{val}', want '{want}'")
        elif base in ("DATABASE_NAME", "PGDATABASE"):
            if val != f"{db}_db":
                v(f"db is '{val}', want '{db}_db'")
        elif base in ("DATABASE_USER", "PGUSER", "DATABASE_PASSWORD", "PGPASSWORD"):
            who = "OWNER" if job else "APP"
            wk = who + ("_USER" if base.endswith("USER") else "_PASSWORD")
            if sec != f"{db}-db-secret" or key != wk:
                v(f"secretKeyRef is {sec}/{key}, want {db}-db-secret/{wk}")
        elif base == "DATABASE_URL" and job:
            for need in (f"@{ip}:5432/{db}_db?", f"x-migrations-table=schema_migrations_{db}", "sslmode=require"):
                if need not in (val or ""):
                    v(f"URL missing '{need}'")
print("OBJS " + ",".join(objs))
for x in viol:
    print("VIOLATION " + x)
sys.exit(1 if viol else 0)
PY

fail=0
printf '%-62s %-8s %s\n' OVERLAY OBJECTS RESULT
for dir in services/*/overlays/{staging,production} services/*/overlays/{staging,production}/jobs; do
  [ -f "${dir}/kustomization.yaml" ] || continue
  svc_dir="${dir#services/}"; svc_dir="${svc_dir%%/*}"
  env="${dir#*/overlays/}"; env="${env%%/*}"
  db="$(svc_db "${svc_dir}")"
  if [ -z "${db}" ]; then
    echo "ERROR: ${svc_dir} has no DB mapping in check-db-overlays.sh" >&2; fail=1; continue
  fi
  out="$(mktemp)"
  if ! kustomize build --load-restrictor LoadRestrictionsNone "${dir}" > "${out}" 2> "${out}.err"; then
    printf '%-62s %-8s %s\n' "${dir}" - "BUILD FAILED"; cat "${out}.err" >&2; fail=1
    rm -f "${out}" "${out}.err"; continue
  fi
  if res="$(python3 -I -c "${PYCHECK}" "${out}" "${env}" "${svc_dir}" "${db}" "$(vps_ip "${env}")")"; then
    printf '%-62s %-8s %s\n' "${dir}" "$(grep -c '' <<<"$(grep '^OBJS' <<<"${res}" | tr ',' '\n')")" OK
  else
    printf '%-62s %-8s %s\n' "${dir}" - FAIL
    grep '^VIOLATION' <<<"${res}" | sed "s|^|  ${dir}: |"
    fail=1
  fi
  rm -f "${out}" "${out}.err"
done
# pgbouncer-vps: the [databases] keys must be exactly <db>_db for every
# service DB, each aliasing the same dbname on this env's VPS. A key that does
# not match the DSN dbname makes every pooled connection fail at runtime.
read -r -d '' PGBCHECK <<'PY' || true
import re, sys
path, ip, want = sys.argv[1], sys.argv[2], set(sys.argv[3].split(","))
text = open(path).read()
m = re.search(r"(?m)^  pgbouncer\.ini: \|-?\n((?:    .*\n|\s*\n)*)", text)
if not m:
    print("VIOLATION pgbouncer.ini not found in rendered ConfigMap"); sys.exit(1)
ini = [l[4:] for l in m.group(1).split("\n")]
viol, keys, sect = [], [], None
for l in ini:
    s = l.strip()
    if not s or s.startswith(";"):
        continue
    h = re.match(r"^\[(\w+)\]$", s)
    if h:
        sect = h.group(1); continue
    if sect != "databases":
        continue
    kv = re.match(r"^(\S+)\s*=\s*(.*)$", s)
    if not kv:
        viol.append(f"unparsable [databases] line '{s}'"); continue
    k, v = kv.groups()
    keys.append(k)
    dbn = re.search(r"\bdbname=(\S+)", v)
    host = re.search(r"\bhost=(\S+)", v)
    if not dbn or dbn.group(1) != k:
        viol.append(f"key '{k}' dbname is '{dbn.group(1) if dbn else None}', want '{k}'")
    if not host or host.group(1) != ip:
        viol.append(f"key '{k}' host is '{host.group(1) if host else None}', want '{ip}'")
dup = sorted({k for k in keys if keys.count(k) > 1})
if dup:
    viol.append(f"duplicate keys {dup}")
if set(keys) != want:
    viol.append(f"keys {sorted(set(keys))}, want {sorted(want)}")
for x in viol:
    print("VIOLATION " + x)
sys.exit(1 if viol else 0)
PY

want_dbs="$(for d in services/*/; do x="$(svc_db "$(basename "${d}")")"; [ -n "${x}" ] && [ "${x}" != none ] && echo "${x}_db"; done | sort -u | paste -sd,)"
for env in staging production; do
  dir="overlays/${env}/pgbouncer-vps"
  out="$(mktemp)"
  if ! kustomize build "${dir}" > "${out}" 2> "${out}.err"; then
    printf '%-62s %-8s %s\n' "${dir}" - "BUILD FAILED"; cat "${out}.err" >&2; fail=1
  elif res="$(python3 -I -c "${PGBCHECK}" "${out}" "$(vps_ip "${env}")" "${want_dbs}")"; then
    printf '%-62s %-8s %s\n' "${dir}" "$(tr ',' '\n' <<<"${want_dbs}" | grep -c .)" OK
  else
    printf '%-62s %-8s %s\n' "${dir}" - FAIL
    grep '^VIOLATION' <<<"${res}" | sed "s|^|  ${dir}: |"
    fail=1
  fi
  rm -f "${out}" "${out}.err"
done

if [ "${fail}" -ne 0 ]; then echo "DB overlay check FAILED"; exit 1; fi
echo "DB overlay check passed"
