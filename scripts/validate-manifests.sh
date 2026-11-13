#!/usr/bin/env bash
# Validate all Kustomize manifests before pushing to remote.
# Requires: kustomize, kubeconform (installed in ~/.local/bin/)
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

validate_target() {
  local target="$1"
  local output
  output=$(kustomize build "$target" 2>&1 | kubeconform -summary -strict -skip "$SKIP_KINDS" 2>&1)
  local invalid
  invalid=$(echo "$output" | grep -oP 'Invalid: \K\d+' || echo "0")

  if [ "$invalid" = "0" ]; then
    local valid
    valid=$(echo "$output" | grep -oP 'Valid: \K\d+' || echo "0")
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
  validate_target "$target" || ((failed++))
done

echo ""
if [ "$failed" -gt 0 ]; then
  echo -e "${RED}$failed target(s) failed validation.${NC}"
  exit 1
else
  echo -e "${GREEN}All targets passed validation.${NC}"
fi
