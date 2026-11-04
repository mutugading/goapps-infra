#!/bin/bash
# ============================================================================
# Install NGINX Ingress Controller for K3s
# ============================================================================
# 
# K3s comes with Traefik by default, but our ingress configs use NGINX.
# This script installs NGINX Ingress Controller via Helm.
# ============================================================================

set -e

# Pinned so a VPS reset / re-bootstrap installs a known controller version instead of
# whatever is latest that day. Bump deliberately (read the chart changelog first) and keep
# scripts/local/install-ingress-nginx.sh on the same version. Override for a one-off:
#   INGRESS_NGINX_CHART_VERSION=4.x.y ./scripts/install-nginx-ingress.sh
# Check what a cluster runs: helm list -n ingress-nginx
CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-4.15.1}"   # controller v1.15.1

echo "=================================================="
echo "  Installing NGINX Ingress Controller (chart ${CHART_VERSION})"
echo "=================================================="

# Add ingress-nginx repository if not exists
echo "[1/3] Adding Helm repository..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

# Create namespace
echo "[2/3] Creating namespace..."
kubectl create namespace ingress-nginx 2>/dev/null || echo "Namespace already exists"

# Install NGINX Ingress Controller
echo "[3/3] Installing NGINX Ingress Controller..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "$CHART_VERSION" \
  --namespace ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --set controller.ingressClassResource.default=true \
  --set controller.watchIngressWithoutClass=true \
  --wait

echo ""
echo "=================================================="
echo "  NGINX Ingress Controller Installed!"
echo "=================================================="
echo ""
echo "Waiting for controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo ""
echo "NGINX Ingress Controller Status:"
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx

echo ""
echo "✅ NGINX Ingress Controller is ready!"
echo ""
echo "Next steps:"
echo "  1. Copy TLS secret to ingress-nginx namespace (if not done)"
echo "  2. Apply your ingress configurations"
