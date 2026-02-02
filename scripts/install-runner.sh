#!/bin/bash
# GitHub Actions Self-Hosted Runner Installation Script
# Run this on staging and production VPS
set -e

RUNNER_VERSION="${RUNNER_VERSION:-2.321.0}"
RUNNER_DIR="$HOME/actions-runner"
ORG_URL="https://github.com/mutugading"

# Determine environment from first argument or hostname
if [ -n "$1" ]; then
    ENV="$1"
elif [[ $(hostname) == *"staging"* ]]; then
    ENV="staging"
elif [[ $(hostname) == *"prod"* ]]; then
    ENV="production"
else
    read -p "Environment (staging/production): " ENV
fi

RUNNER_NAME="${ENV}-runner"
LABELS="self-hosted,linux,${ENV},goapps-runner,kubectl"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  GitHub Actions Self-Hosted Runner Installer               ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Environment: ${ENV}                                       ║"
echo "║  Runner Name: ${RUNNER_NAME}                               ║"
echo "║  Labels: ${LABELS}                                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Create runner directory
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"

# Download runner
echo "📥 Downloading runner v${RUNNER_VERSION}..."
curl -sL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" | tar xz

# Prompt for token
echo ""
echo "📋 Get registration token from:"
echo "   ${ORG_URL} → Settings → Actions → Runners → New self-hosted runner"
echo ""
read -p "Registration token: " TOKEN

# Configure runner
echo "⚙️ Configuring runner..."
./config.sh --url "$ORG_URL" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work "_work" \
    --replace

# Install and start service
echo "🔧 Installing as service..."
sudo ./svc.sh install
sudo ./svc.sh start

# Verify
echo ""
echo "✅ Runner installed successfully!"
echo ""
echo "📊 Service status:"
sudo ./svc.sh status

echo ""
echo "📝 Next steps:"
echo "   1. Verify runner appears at: ${ORG_URL} → Settings → Actions → Runners"
echo "   2. Runner should show as 'Idle'"
echo ""
