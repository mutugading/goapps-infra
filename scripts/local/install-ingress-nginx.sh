#!/usr/bin/env bash
# Install ingress-nginx on the LOCAL Colima k3s cluster only (context-guarded).
# Chart 4.15.1 (controller v1.15.1). NOTE: staging does not pin a version
# (scripts/install-nginx-ingress.sh) - recommend pinning staging later.
set -euo pipefail
CTX="${KUBE_CONTEXT:-colima-k8s}"
CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-4.15.1}"
[ "$CTX" = "colima-k8s" ] || { echo "refusing: context must be colima-k8s (got $CTX)"; exit 1; }
kubectl config get-contexts -o name | grep -qx "$CTX" || { echo "context $CTX not found"; exit 1; }

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx
helm --kube-context "$CTX" upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "$CHART_VERSION" \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.ingressClassResource.default=true \
  --set controller.watchIngressWithoutClass=true \
  --wait --timeout 5m
kubectl --context "$CTX" -n ingress-nginx wait --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s
