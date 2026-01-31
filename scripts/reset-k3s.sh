#!/bin/bash
# Reset K3s script - Completely removes K3s and all data
# WARNING: This is DESTRUCTIVE and cannot be undone!

set -e

echo "=================================================="
echo "  K3s Reset Script"
echo "=================================================="
echo ""

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}WARNING: This will completely remove K3s and ALL cluster data!${NC}"
echo -e "${YELLOW}This includes:${NC}"
echo "  - All pods and deployments"
echo "  - All persistent volumes"
echo "  - All secrets and configmaps"
echo "  - All monitoring data"
echo "  - PostgreSQL database"
echo "  - MinIO storage"
echo ""

read -p "Are you absolutely sure? Type 'DELETE' to confirm: " confirm

if [ "$confirm" != "DELETE" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo -e "${YELLOW}[1/4] Stopping K3s service...${NC}"
sudo systemctl stop k3s 2>/dev/null || true

echo -e "${YELLOW}[2/4] Uninstalling K3s...${NC}"
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh
else
    echo "K3s uninstall script not found, manual cleanup..."
fi

echo -e "${YELLOW}[3/4] Cleaning up remaining files...${NC}"
sudo rm -rf /var/lib/rancher
sudo rm -rf /etc/rancher
sudo rm -rf /var/lib/kubelet
rm -rf ~/.kube

echo -e "${YELLOW}[4/4] Verifying cleanup...${NC}"
if command -v k3s &> /dev/null; then
    echo -e "${RED}Warning: k3s command still exists${NC}"
else
    echo -e "${GREEN}K3s removed successfully${NC}"
fi

echo ""
echo "=================================================="
echo -e "${GREEN}  Reset Complete!${NC}"
echo "=================================================="
echo ""
echo "To reinstall, run:"
echo "  ./scripts/bootstrap.sh"
