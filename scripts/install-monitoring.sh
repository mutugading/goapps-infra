#!/bin/bash
# Install monitoring stack (Prometheus, Grafana, Loki)
# Uses Helm for installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

echo "=================================================="
echo "  Monitoring Stack Installation"
echo "=================================================="

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Default passwords (should be overridden via --set)
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

# =============================================================================
# Step 1: Install kube-prometheus-stack
# =============================================================================
echo -e "${GREEN}[1/3] Installing kube-prometheus-stack...${NC}"

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring \
    --create-namespace \
    -f "${INFRA_DIR}/base/monitoring/helm-values/prometheus-stack.yaml" \
    --set grafana.adminPassword="${GRAFANA_PASSWORD}" \
    --set grafana.assertNoLeakedSecrets=false \
    --wait --timeout 10m

echo -e "${GREEN}Prometheus stack installed!${NC}"

# =============================================================================
# Step 2: Install Loki Stack
# =============================================================================
echo -e "${GREEN}[2/3] Installing Loki stack...${NC}"

helm upgrade --install loki grafana/loki-stack \
    -n monitoring \
    -f "${INFRA_DIR}/base/monitoring/helm-values/loki-stack.yaml" \
    --wait --timeout 5m

echo -e "${GREEN}Loki stack installed!${NC}"

# =============================================================================
# Step 3: Apply custom dashboards and alerts
# =============================================================================
echo -e "${GREEN}[3/3] Applying custom dashboards and alerts...${NC}"

# Apply dashboards as ConfigMaps
for dashboard in "${INFRA_DIR}"/base/monitoring/dashboards/*.json; do
    if [ -f "$dashboard" ]; then
        name=$(basename "$dashboard" .json | tr '_' '-')
        kubectl create configmap "grafana-dashboard-${name}" \
            --from-file="${dashboard}" \
            -n monitoring \
            --dry-run=client -o yaml | \
            kubectl label --local -f - grafana_dashboard="1" -o yaml | \
            kubectl apply -f -
        echo "  Applied dashboard: ${name}"
    fi
done

# Apply alert rules
if [ -f "${INFRA_DIR}/base/monitoring/alert-rules/grafana-alerts.yaml" ]; then
    kubectl apply -f "${INFRA_DIR}/base/monitoring/alert-rules/grafana-alerts.yaml" -n monitoring
    echo "  Applied alert rules"
fi

# Apply datasources
if [ -f "${INFRA_DIR}/base/monitoring/datasources/unified-datasources.yaml" ]; then
    kubectl apply -f "${INFRA_DIR}/base/monitoring/datasources/unified-datasources.yaml" -n monitoring
    echo "  Applied datasources"
fi

echo ""
echo "=================================================="
echo -e "${GREEN}  Monitoring Stack Installed!${NC}"
echo "=================================================="
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo "  Open: http://localhost:3000"
echo "  Username: admin"
echo "  Password: ${GRAFANA_PASSWORD}"
echo ""
echo "Access Prometheus:"
echo "  kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090"
echo "  Open: http://localhost:9090"
