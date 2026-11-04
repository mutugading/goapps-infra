#!/usr/bin/env bash
# Create base/local/credentials/*.local.env (gitignored) from the *.example files,
# filling local dev creds from goapps-backend (deploy/local-v2, docker-compose.yaml)
# and random values for tokens. Existing files are never overwritten.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$ROOT/base/local/credentials"
BE="${GOAPPS_BACKEND:-$ROOT/../goapps-backend}"
rnd() { openssl rand -hex "${1:-24}"; }
envv() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }
ownerpw() { grep -E "^\| \`$1_db\`" "$BE/deploy/local-v2/README.md" | sed -E 's/.*`'"$1"'_owner` \/ `([^`]*)`.*/\1/'; }
compose() { grep -E "^\s+$1:" "$BE/docker-compose.yaml" | head -1 | sed -E 's/.*: *//'; }

mk() { # name, then KEY=VAL lines on stdin
  local f="$D/$1.local.env"
  if [ -e "$f" ]; then echo "keep   $1"; cat >/dev/null; return; fi
  cat > "$f"; chmod 600 "$f"; echo "create $1"
}
# Resolve every sourced value up front: `$(...)` inside a here-string is not covered by
# `set -e`, so a changed README/env format would otherwise write an empty value silently.
need() { # name value
  [ -n "$2" ] || { echo "ERROR: could not read $1 from $BE (format changed?)" >&2; exit 1; }
  printf '%s' "$2"
}
fin_app=$(need finance-app-password "$(envv "$BE/deploy/local-v2/env/finance.env" DATABASE_PASSWORD)")
iam_app=$(need iam-app-password "$(envv "$BE/deploy/local-v2/env/iam.env" DATABASE_PASSWORD)")
ppc_app=$(need ppc-app-password "$(envv "$BE/deploy/local-v2/env/ppc.env" PPC_DATABASE_PASSWORD)")
fin_own=$(need finance-owner-password "$(ownerpw finance)")
iam_own=$(need iam-owner-password "$(ownerpw iam)")
ppc_own=$(need ppc-owner-password "$(ownerpw ppc)")
rmq_user=$(need RABBITMQ_DEFAULT_USER "$(compose RABBITMQ_DEFAULT_USER)")
rmq_pass=$(need RABBITMQ_DEFAULT_PASS "$(compose RABBITMQ_DEFAULT_PASS)")
minio_user=$(need MINIO_ROOT_USER "$(compose MINIO_ROOT_USER)")
minio_pass=$(need MINIO_ROOT_PASSWORD "$(compose MINIO_ROOT_PASSWORD)")
# PPC_INTERNAL_TOKEN must equal INTERNAL_SERVICE_TOKEN: finance/IAM validate PPC's
# service token against their own (see CLAUDE.md §12). Reuse an existing value if present.
internal_tok=$(envv "$D/goapps-internal-token.local.env" INTERNAL_SERVICE_TOKEN 2>/dev/null || true)
internal_tok=${internal_tok:-$(rnd)}

mk finance-db-secret <<<"APP_USER=finance_app
APP_PASSWORD=$fin_app
OWNER_USER=finance_owner
OWNER_PASSWORD=$fin_own"
mk iam-db-secret <<<"APP_USER=iam_app
APP_PASSWORD=$iam_app
OWNER_USER=iam_owner
OWNER_PASSWORD=$iam_own"
mk ppc-db-secret <<<"APP_USER=ppc_app
APP_PASSWORD=$ppc_app
OWNER_USER=ppc_owner
OWNER_PASSWORD=$ppc_own"
mk rabbitmq-secret <<<"RABBITMQ_USER=$rmq_user
RABBITMQ_PASSWORD=$rmq_pass"
mk minio-secret <<<"MINIO_ROOT_USER=$minio_user
MINIO_ROOT_PASSWORD=$minio_pass"
mk goapps-auth-secret <<<"JWT_ACCESS_SECRET=$(rnd 32)
JWT_REFRESH_SECRET=$(rnd 32)"
mk goapps-internal-token <<<"INTERNAL_SERVICE_TOKEN=$internal_tok"
mk ppc-internal-token <<<"PPC_INTERNAL_TOKEN=$internal_tok"
mk oracle-credentials <<<"ORACLE_HOST=oracle.invalid
ORACLE_PORT=1521
ORACLE_SERVICE=DUMMY
ORACLE_USER=dummy
ORACLE_PASSWORD=dummy"
mk smtp-secret <<<"SMTP_HOST=192.168.5.2
SMTP_PORT=1025
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM_ADDRESS=noreply@goapps.local"
mk iam-seed-secret <<<"SEED_ADMIN_USERNAME=admin
SEED_ADMIN_EMAIL=admin@goapps.local
SEED_ADMIN_PASSWORD=LocalAdmin#2026"
mk goapps-chat-secret <<<"CHAT_MASTER_KEY=$(rnd 32)"
