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
fin_app=$(envv "$BE/deploy/local-v2/env/finance.env" DATABASE_PASSWORD)
iam_app=$(envv "$BE/deploy/local-v2/env/iam.env" DATABASE_PASSWORD)
ppc_app=$(envv "$BE/deploy/local-v2/env/ppc.env" PPC_DATABASE_PASSWORD)
mk finance-db-secret <<<"APP_USER=finance_app
APP_PASSWORD=$fin_app
OWNER_USER=finance_owner
OWNER_PASSWORD=$(ownerpw finance)"
mk iam-db-secret <<<"APP_USER=iam_app
APP_PASSWORD=$iam_app
OWNER_USER=iam_owner
OWNER_PASSWORD=$(ownerpw iam)"
mk ppc-db-secret <<<"APP_USER=ppc_app
APP_PASSWORD=$ppc_app
OWNER_USER=ppc_owner
OWNER_PASSWORD=$(ownerpw ppc)"
mk rabbitmq-secret <<<"RABBITMQ_USER=$(compose RABBITMQ_DEFAULT_USER)
RABBITMQ_PASSWORD=$(compose RABBITMQ_DEFAULT_PASS)"
mk minio-secret <<<"MINIO_ROOT_USER=$(compose MINIO_ROOT_USER)
MINIO_ROOT_PASSWORD=$(compose MINIO_ROOT_PASSWORD)"
mk goapps-auth-secret <<<"JWT_ACCESS_SECRET=$(rnd 32)
JWT_REFRESH_SECRET=$(rnd 32)"
mk goapps-internal-token <<<"INTERNAL_SERVICE_TOKEN=$(rnd)"
mk ppc-internal-token <<<"PPC_INTERNAL_TOKEN=$(rnd)"
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
