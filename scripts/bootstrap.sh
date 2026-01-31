#!/bin/bash
# Bootstrap script for K3s cluster
# Run this on a fresh VPS to set up the complete infrastructure

set -e

echo "=================================================="
echo "  goapps-infra Bootstrap Script"
echo "=================================================="

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Detect environment
ENVIRONMENT="${ENVIRONMENT:-staging}"
echo -e "${YELLOW}Environment: ${ENVIRONMENT}${NC}"

# =============================================================================
# Step 1: Install K3s
# =============================================================================
echo -e "${GREEN}[1/7] Installing K3s...${NC}"
if command -v k3s &> /dev/null; then
    echo "K3s already installed, skipping..."
else
    curl -sfL https://get.k3s.io | sh -
    sleep 10
fi

# Setup kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
export KUBECONFIG=~/.kube/config

echo -e "${GREEN}K3s installed successfully!${NC}"
kubectl get nodes

# =============================================================================
# Step 2: Install Helm
# =============================================================================
echo -e "${GREEN}[2/7] Installing Helm...${NC}"
if command -v helm &> /dev/null; then
    echo "Helm already installed, skipping..."
else
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version

# =============================================================================
# Step 3: Add Helm Repositories
# =============================================================================
echo -e "${GREEN}[3/7] Adding Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# =============================================================================
# Step 4: Create Namespaces
# =============================================================================
echo -e "${GREEN}[4/7] Creating namespaces...${NC}"
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

if [ "$ENVIRONMENT" = "staging" ]; then
    kubectl create namespace goapps-staging --dry-run=client -o yaml | kubectl apply -f -
else
    kubectl create namespace goapps-production --dry-run=client -o yaml | kubectl apply -f -
fi

# =============================================================================
# Step 5: Mount Backup Partition (if exists)
# =============================================================================
echo -e "${GREEN}[5/7] Configuring backup storage...${NC}"
BACKUP_MOUNT="/mnt/goapps-backup"
if [ "$ENVIRONMENT" = "staging" ]; then
    BACKUP_MOUNT="/mnt/stgapps-backup"
fi

if [ -b /dev/sdb ]; then
    echo "Found /dev/sdb, mounting to ${BACKUP_MOUNT}..."
    sudo mkdir -p ${BACKUP_MOUNT}
    
    # Check if already mounted
    if ! mountpoint -q ${BACKUP_MOUNT}; then
        sudo mount /dev/sdb ${BACKUP_MOUNT}
        
        # Add to fstab for persistence
        if ! grep -q "/dev/sdb" /etc/fstab; then
            echo "/dev/sdb ${BACKUP_MOUNT} ext4 defaults 0 2" | sudo tee -a /etc/fstab
        fi
    fi
    echo "Backup partition mounted at ${BACKUP_MOUNT}"
else
    echo -e "${YELLOW}No /dev/sdb found, skipping backup mount${NC}"
fi

# =============================================================================
# Step 6: Install VPA (Vertical Pod Autoscaler)
# =============================================================================
echo -e "${GREEN}[6/7] Installing VPA...${NC}"
if kubectl get deployment vpa-recommender -n kube-system &> /dev/null; then
    echo "VPA already installed, skipping..."
else
    git clone https://github.com/kubernetes/autoscaler.git /tmp/autoscaler 2>/dev/null || true
    cd /tmp/autoscaler/vertical-pod-autoscaler
    ./hack/vpa-up.sh
    cd -
fi

# =============================================================================
# Step 7: Summary
# =============================================================================
echo ""
echo "=================================================="
echo -e "${GREEN}  Bootstrap Complete!${NC}"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Create secrets (see README.md)"
echo "  2. Run: ./scripts/install-monitoring.sh"
echo "  3. Run: ./scripts/install-argocd.sh"
echo "  4. Apply base configs: make apply-base"
echo ""
echo "Cluster status:"
kubectl get nodes
kubectl get namespaces
