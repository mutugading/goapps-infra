#!/usr/bin/env bash
# Validate all Kustomize manifests before pushing to remote.
# Requires: kustomize (or kubectl), kubeconform (installed in ~/.local/bin/)
#
# Usage:
#   ./scripts/validate-manifests.sh          # validate all
#   ./scripts/validate-manifests.sh database # validate specific target

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# CRDs that kubeconform doesn't have schemas for
SKIP_KINDS="VerticalPodAutoscaler,ServiceMonitor,HorizontalPodAutoscaler"

# All kustomize targets to validate
ALL_TARGETS=(
  "base/database"
  "services/finance-service/overlays/staging"
  "services/finance-service/overlays/production"
  "services/iam-service/overlays/staging"
  "services/iam-service/overlays/production"
  "services/frontend/overlays/staging"
  "services/frontend/overlays/production"
  "services/ppc-service/overlays/staging"
  "services/ppc-service/overlays/production"
  "services/payroll-service/overlays/staging"
  "services/payroll-service/overlays/production"
  "services/payroll-service/overlays/staging/jobs"
  "services/payroll-service/overlays/production/jobs"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# kustomize binary, or `kubectl kustomize` when only kubectl is installed.
if command -v kustomize >/dev/null 2>&1; then
  KUSTOMIZE=(kustomize build)
elif command -v kubectl >/dev/null 2>&1; then
  KUSTOMIZE=(kubectl kustomize)
else
  echo "kustomize (or kubectl) not found in PATH" >&2
  exit 2
fi
command -v kubeconform >/dev/null 2>&1 || { echo "kubeconform not found in PATH" >&2; exit 2; }

# Count of a kubeconform summary field ("Valid: 22, Invalid: 0, ..."); empty when the summary line is missing.
summary_count() {
  local field="$1" text="$2"
  echo "$text" | sed -n "s/^Summary:.* ${field}: \([0-9][0-9]*\).*/\1/p" | head -n1
}

validate_target() {
  local target="$1" manifest output
  # Build first: a kustomize error must fail the target, not be swallowed by the pipe into kubeconform.
  if ! manifest=$("${KUSTOMIZE[@]}" "$target" 2>&1); then
    echo -e "  ${RED}❌${NC} $target (kustomize build failed)"
    echo "$manifest" | sed 's/^/     /'
    return 1
  fi
  # kubeconform exits 1 on invalid resources; the output is parsed instead, so do not let `set -e` stop here.
  output=$(echo "$manifest" | kubeconform -summary -strict -skip "$SKIP_KINDS" 2>&1) || true

  local valid invalid errors
  valid=$(summary_count Valid "$output")
  invalid=$(summary_count Invalid "$output")
  errors=$(summary_count Errors "$output")

  # No summary line means the output could not be read: fail loudly rather than report "0 resources".
  if [ -z "$valid" ] || [ -z "$invalid" ] || [ -z "$errors" ]; then
    echo -e "  ${RED}❌${NC} $target (kubeconform summary not found)"
    echo "$output" | sed 's/^/     /'
    return 1
  fi

  if [ "$invalid" = "0" ] && [ "$errors" = "0" ]; then
    echo -e "  ${GREEN}✅${NC} $target (${valid} resources)"
    return 0
  else
    echo -e "  ${RED}❌${NC} $target"
    echo "$output" | sed 's/^/     /'
    return 1
  fi
}

echo "Validating Kustomize manifests..."
echo ""

failed=0
targets=("${@:-${ALL_TARGETS[@]}}")

# If a single keyword is passed, filter matching targets
if [ "${#@}" -eq 1 ] && [[ ! "$1" == *"/"* ]]; then
  keyword="$1"
  filtered=()
  for t in "${ALL_TARGETS[@]}"; do
    [[ "$t" == *"$keyword"* ]] && filtered+=("$t")
  done
  if [ "${#filtered[@]}" -eq 0 ]; then
    echo "No targets matching '$keyword'. Available:"
    printf '  %s\n' "${ALL_TARGETS[@]}"
    exit 1
  fi
  targets=("${filtered[@]}")
fi

for target in "${targets[@]}"; do
  validate_target "$target" || failed=$((failed + 1))
done

echo ""
if [ "$failed" -gt 0 ]; then
  echo -e "${RED}$failed target(s) failed validation.${NC}"
  exit 1
else
  echo -e "${GREEN}All targets passed validation.${NC}"
fi
