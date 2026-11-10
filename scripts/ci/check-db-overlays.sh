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
# Usage: scripts/ci/check-db-overlays.sh [repo-root]   (needs kustomize, python3)
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${ROOT}"

svc_db() {
  case "$1" in
    iam-service) echo iam ;;
    finance-service | finance-worker | finance-cost-worker | finance-cost-orchestrator) echo finance ;;
    ppc-service) echo ppc ;;
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
if [ "${fail}" -ne 0 ]; then echo "DB overlay check FAILED"; exit 1; fi
echo "DB overlay check passed"
