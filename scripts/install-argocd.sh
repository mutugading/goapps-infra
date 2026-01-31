#!/bin/bash
# Install ArgoCD for GitOps
# Enables automatic sync from Git to cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

echo "=================================================="
echo "  ArgoCD Installation"
echo "=================================================="

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Configuration
ARGOCD_VERSION="7.7.5"
ENVIRONMENT="${ENVIRONMENT:-staging}"

# =============================================================================
# Step 1: Install ArgoCD via Helm
# =============================================================================
echo -e "${GREEN}[1/4] Installing ArgoCD...${NC}"

helm upgrade --install argocd argo/argo-cd \
    -n argocd \
    --create-namespace \
    --version ${ARGOCD_VERSION} \
    --set configs.params."server\.insecure"=true \
    --set server.extraArgs[0]="--rootpath=/argocd" \
    --wait --timeout 5m

echo -e "${GREEN}ArgoCD installed!${NC}"

# =============================================================================
# Step 2: Wait for ArgoCD to be ready
# =============================================================================
echo -e "${GREEN}[2/4] Waiting for ArgoCD to be ready...${NC}"
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# =============================================================================
# Step 3: Get initial admin password
# =============================================================================
echo -e "${GREEN}[3/4] Getting admin credentials...${NC}"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo -e "${YELLOW}ArgoCD Admin Password: ${ARGOCD_PASSWORD}${NC}"

# =============================================================================
# Step 4: Create ArgoCD Project and Applications
# =============================================================================
echo -e "${GREEN}[4/4] Creating ArgoCD Project...${NC}"

# Create goapps project
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: goapps
  namespace: argocd
spec:
  description: Go Apps Microservices Platform
  sourceRepos:
    - 'https://github.com/mutugading/goapps-infra.git'
    - 'https://github.com/ilramdhan/goapps-infra.git'
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

echo -e "${GREEN}ArgoCD Project 'goapps' created!${NC}"

# Apply ArgoCD applications if they exist
if [ -d "${INFRA_DIR}/argocd/apps" ] && [ "$(ls -A ${INFRA_DIR}/argocd/apps 2>/dev/null)" ]; then
    kubectl apply -f "${INFRA_DIR}/argocd/apps/"
    echo -e "${GREEN}ArgoCD Applications applied!${NC}"
else
    echo -e "${YELLOW}No ArgoCD applications found in argocd/apps/, skipping...${NC}"
fi

echo ""
echo "=================================================="
echo -e "${GREEN}  ArgoCD Installed!${NC}"
echo "=================================================="
echo ""
echo "Access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Open: https://localhost:8080"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo "Install ArgoCD CLI (optional):"
echo "  curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
echo "  chmod +x /usr/local/bin/argocd"
echo ""
echo "Login via CLI:"
echo "  argocd login localhost:8080 --username admin --password ${ARGOCD_PASSWORD} --insecure"
