# Runbook — Grafana 503 caused by stale `data_source` rows (provisioning crash)

**Incident date:** 2026-09-05 · **Environment:** production · **Resolved:** yes

---

## 1. Symptom

- `https://goapps.mutugading.com/grafana` → `503 Service Temporarily Unavailable` from nginx.
- Staging (`https://staging-goapps.mutugading.com/grafana`) works fine with byte-identical Ingress config and byte-identical `grafana_datasource: "1"` ConfigMap.
- `kubectl get endpoints prometheus-grafana -n monitoring` → **empty**. This is *always* the direct cause of a 503 from the ingress — nginx has no pod to send traffic to. It is a symptom, not the root cause; the real question is always "why is the Service pod not Ready."
- `kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana` → `3/4 Running`, main `grafana` container in `CrashLoopBackOff`, huge restart count (thousands, accumulated over days/weeks — check `AGE` vs restart count, a high ratio means it's been silently crashlooping a long time, not a fresh break).
- `kubectl logs <pod> -n monitoring -c grafana --previous`:
  ```
  logger=provisioning ... level=error msg="Failed to provision data sources" error="Datasource provisioning error: data source not found"
  Error: ✗ invalid service state: Failed, expected: Terminated, failure: ... [starting module provisioning: ... Datasource provisioning error: data source not found]
  ```

## 2. Root cause

Grafana's file-based datasource provisioning (the `grafana_datasource: "1"` ConfigMap watched by the `grafana-sc-datasources` sidecar) reconciles against rows already persisted in `grafana.db` (SQLite, on the `prometheus-grafana` PVC). If the DB has datasource rows that **don't match or don't exist** in the current provisioning file — a different `uid` for a same-named datasource, or an old row for a datasource no longer in the file at all — the provisioner's reconcile/prune step fails fatally with `data source not found`, and Grafana never finishes starting. It crashloops forever until the DB is fixed; **restarting the pod does not help**, because the corrupt state lives on disk (the PVC), not in the crashed process — a fresh process reads the same bad rows and fails the same way. Thousands of automatic restarts with no recovery is itself evidence the fix must be a data change, not a process restart.

This drift happens because `base/monitoring/` is **outside GitOps/ArgoCD** (see main `goapps-infra/CLAUDE.md` §6) — nothing reconciles the live cluster back to the file. Datasources added manually via the Grafana UI in the past, or left over from an older Helm values revision, persist in the DB forever even after the provisioning file is cleaned up.

In this incident, comparing production's `data_source` table against staging's (clean) one found 3 stale/mismatched rows out of 4 in production:

| id | name | uid in DB | Problem |
|----|------|-----------|---------|
| 1 | Prometheus | `prometheus` | OK — matches file |
| 2 | Alertmanager | `alertmanager` | Not in provisioning file, not present in staging either → orphan |
| 3 | Loki | `P8E80F9AEF21F6940` | File defines `uid: loki` — **mismatch**, most likely the direct trigger |
| 4 | grafana-postgresql-datasource | `cfo03cwh52l1cf` | Not in provisioning file, not present in staging → orphan |

Staging's `data_source` table had only the 2 rows that match the file exactly (`Prometheus`/`prometheus`, `Loki`/`loki`) — this comparison is what confirmed the diagnosis and is the fastest way to confirm this root cause again in future: **a healthy environment's `data_source` table is the ground truth to diff against.**

## 3. Diagnosis commands (in order)

```bash
# 1. Confirm it's a 503-from-no-endpoint issue, not an ingress/config problem
kubectl get endpoints prometheus-grafana -n monitoring
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl describe pod <pod> -n monitoring
kubectl logs <pod> -n monitoring -c grafana --previous

# 2. Rule out config drift between environments (usually NOT the cause, but cheap to check)
kubectl get cm -n monitoring -l grafana_datasource=1 -o yaml   # compare staging vs production — should be identical

# 3. If logs show "Datasource provisioning error: data source not found" → inspect grafana.db directly.
# The Grafana image has no sqlite3 binary, so you need a side pod or a copy.
```

### Reading `grafana.db` on a HEALTHY pod (no scale-down needed)

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl cp monitoring/<healthy-pod>:/var/lib/grafana/grafana.db ./grafana-check.db -c grafana -n monitoring
which sqlite3 || sudo apt install -y sqlite3   # sqlite3 is commonly available on the SSH host directly — try this before reaching for Docker
sqlite3 ./grafana-check.db "SELECT id, org_id, name, uid, is_default, type, version FROM data_source;"
```

### Reading `grafana.db` on a CRASHLOOPING pod (must scale down first — the PVC is RWO/`local-path`, a live crashlooping pod still holds the mount)

```bash
# 1. Stop the crashlooping deployment so the PVC is free to mount elsewhere
kubectl scale deployment prometheus-grafana -n monitoring --replicas=0

# 2. Debug pod mounting the SAME PVC. Must run as uid/gid 472 (the grafana container's user) —
#    grafana.db is mode 0660 owned by 472:472, so any other uid gets "unable to open database file".
kubectl run grafana-debug -n monitoring -it --rm --image=keinos/sqlite3 --restart=Never \
  --overrides='{
    "spec": {
      "securityContext": {"runAsUser": 472, "runAsGroup": 472},
      "containers": [{
        "name": "grafana-debug",
        "image": "keinos/sqlite3",
        "command": ["sh"],
        "stdin": true,
        "tty": true,
        "volumeMounts": [{"name": "data", "mountPath": "/var/lib/grafana"}]
      }],
      "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "prometheus-grafana"}}]
    }
  }' -- sh

# Inside the pod:
sqlite3 /var/lib/grafana/grafana.db "SELECT id, org_id, name, uid, is_default, type, version FROM data_source;"
```

Common mistake: typing the raw `SELECT ...;` straight into the shell prompt instead of passing it as an argument to `sqlite3` — this fails with `sh: SELECT: not found`. Either pass the whole query as one `sqlite3 <db> "SELECT ...;"` argument, or run `sqlite3 <db>` first to get an interactive prompt, then type the query, then `.quit`.

## 4. Fix

Delete the rows that don't match the provisioning file (compare against a healthy environment's table first to know exactly which ids are safe to remove — do not guess).

```bash
# Inside the same grafana-debug pod, PVC still mounted, deployment still at 0 replicas:

# Backup first — cheap, and lives on the same PVC so no extra tooling needed
cp /var/lib/grafana/grafana.db /var/lib/grafana/grafana.db.bak-$(date +%Y%m%d)

# Sanity check exactly what you're about to delete
sqlite3 /var/lib/grafana/grafana.db "SELECT id, name, uid FROM data_source WHERE id IN (<bad ids>);"

# Delete
sqlite3 /var/lib/grafana/grafana.db "DELETE FROM data_source WHERE id IN (<bad ids>);"

# Confirm only the correct/expected rows remain
sqlite3 /var/lib/grafana/grafana.db "SELECT id, org_id, name, uid, is_default, type, version FROM data_source;"

exit   # deletes the debug pod (--rm)
```

Scale Grafana back up and verify:

```bash
kubectl scale deployment prometheus-grafana -n monitoring --replicas=1
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w   # expect 4/4 Running, restart count 0
kubectl get endpoints prometheus-grafana -n monitoring                # expect a populated endpoint
```

On next startup the file-based provisioner re-inserts any datasource still defined in the ConfigMap (e.g. Loki) fresh, with the correct `uid` from the file — no manual re-insert needed.

**⚠️ Do not forget the scale-back-up step.** Scaling to 0 for diagnosis leaves Grafana fully down (worse than the 503) until you scale back to 1 — this is easy to forget once the DB fix looks done.

## 5. Backup file cleanup

The `.bak-YYYYMMDD` file created in step 4 lives on the PVC (`/var/lib/grafana/`) — it does **not** disappear on its own and is not part of Grafana's own storage accounting, so it just sits there indefinitely if left. Once Grafana has been confirmed healthy (pod `4/4 Running`, 0 restarts, web UI loads, dashboards/datasources look correct) for at least a few hours to a day, delete it to avoid confusing a future on-call reader or slowly eating PVC space:

```bash
kubectl scale deployment prometheus-grafana -n monitoring --replicas=0   # only if you need the debug-pod route again; skip if you can exec into the running pod instead
kubectl exec -it deploy/prometheus-grafana -n monitoring -c grafana -- rm /var/lib/grafana/grafana.db.bak-YYYYMMDD
kubectl scale deployment prometheus-grafana -n monitoring --replicas=1   # only if you scaled down above
```

(Since the pod is healthy again at this point, prefer `kubectl exec` into the *running* container to delete the backup — no need to scale down or spin up a debug pod just to `rm` a file.)

Keep the backup around longer only if you have specific doubt about the fix; otherwise there is no reason to retain it past confirmation.

## 6. Prevention / follow-up

- Root cause of the *drift itself* (how the orphan/mismatched rows got into production's DB in the first place — manual UI edits? an old Helm values revision that once defined Alertmanager/Postgres datasources?) was not investigated further; low priority since the fix is idempotent and cheap to repeat.
- Because `base/monitoring/` is outside ArgoCD (`goapps-infra/CLAUDE.md` §6), this class of drift can recur silently. If it happens again, this runbook's §3 "healthy environment as ground truth" diff is the fastest path back to a fix — no need to re-derive the diagnosis from scratch.
- Consider (not yet done): a periodic check comparing `data_source` table contents (or count) between staging and production, or alerting on `CrashLoopBackOff` in the `monitoring` namespace specifically, since this crash produced thousands of silent restarts over roughly 22 days before being noticed via the 503 symptom rather than an alert.
