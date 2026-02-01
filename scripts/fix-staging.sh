#!/bin/bash
# ============================================================================
# Fix Script untuk Staging VPS
# Jalankan script ini setelah git pull
# ============================================================================

set -e

echo "=================================================="
echo "  Fix Script - Staging VPS"
echo "=================================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# =============================================================================
# Step 1: Delete problematic resources
# =============================================================================
echo -e "${GREEN}[1/7] Cleaning up problematic resources...${NC}"

# Delete webhook yang bermasalah
kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null || true

# Delete ArgoCD ingress yang lama (kita pakai NodePort sekarang)
kubectl delete ingress argocd-ingress -n argocd --ignore-not-found

# Delete MinIO ingress yang lama
kubectl delete ingress minio-ingress -n minio --ignore-not-found

# Delete old ArgoCD nodeport service
kubectl delete svc argocd-server-nodeport -n argocd --ignore-not-found

echo -e "${GREEN}Cleanup done!${NC}"

# =============================================================================
# Step 2: Delete existing MinIO deployment (immutable selector issue)
# =============================================================================
echo -e "${GREEN}[2/7] Handling MinIO deployment...${NC}"

# Get current MinIO PVC name to preserve data
echo "Preserving MinIO data..."

# Delete the deployment only (not PVC)
kubectl delete deployment minio -n minio --ignore-not-found
sleep 5

# Apply MinIO fresh with overlays
echo "Applying MinIO with sub-path configuration..."
kubectl apply -k overlays/staging/minio/

echo -e "${GREEN}MinIO deployed!${NC}"

# =============================================================================
# Step 3: Apply ArgoCD NodePort Service
# =============================================================================
echo -e "${GREEN}[3/7] Applying ArgoCD NodePort Service...${NC}"
kubectl apply -k base/argocd/
echo -e "${GREEN}ArgoCD NodePort applied!${NC}"

# =============================================================================
# Step 4: Copy TLS secret to minio namespace
# =============================================================================
echo -e "${GREEN}[4/7] Copying TLS secret to minio namespace...${NC}"

# Delete existing and recreate
kubectl delete secret goapps-tls -n minio --ignore-not-found
kubectl get secret goapps-tls -n monitoring -o yaml | \
  sed 's/namespace: monitoring/namespace: minio/' | \
  kubectl apply -f -

echo -e "${GREEN}TLS secret copied!${NC}"

# =============================================================================
# Step 5: Apply Ingress
# =============================================================================
echo -e "${GREEN}[5/7] Applying Ingress...${NC}"
kubectl apply -f overlays/staging/ingress.yaml
echo -e "${GREEN}Ingress applied!${NC}"

# =============================================================================
# Step 6: Restart deployments to apply new configs
# =============================================================================
echo -e "${GREEN}[6/7] Restarting deployments...${NC}"
kubectl rollout restart deployment prometheus-grafana -n monitoring
kubectl rollout restart deployment minio -n minio 2>/dev/null || true
echo -e "${GREEN}Deployments restarted!${NC}"

# =============================================================================
# Step 7: Verify
# =============================================================================
echo -e "${GREEN}[7/7] Verifying...${NC}"
echo ""

echo "=== ArgoCD NodePort Service ==="
kubectl get svc argocd-server-nodeport -n argocd

echo ""
echo "=== Ingress ==="
kubectl get ingress -A

echo ""
echo "=== Pods Status ==="
kubectl get pods -n monitoring | grep grafana
kubectl get pods -n minio

echo ""
echo "=================================================="
echo -e "${GREEN}  Fix Complete!${NC}"
echo "=================================================="
echo ""
echo "URLs (tunggu 1-2 menit untuk pods ready):"
echo "  Grafana:    https://staging-goapps.mutugading.com/grafana"
echo "  Prometheus: https://staging-goapps.mutugading.com/prometheus"
echo "  MinIO:      https://staging-goapps.mutugading.com/minio"
echo "  ArgoCD:     http://staging-goapps.mutugading.com:30080"
echo ""
echo "Jika masih ada masalah, cek:"
echo "  kubectl logs -n minio deploy/minio"
echo "  kubectl logs -n monitoring deploy/prometheus-grafana -c grafana"
