#!/bin/bash
set -euo pipefail

# Load test helper library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"

test_header "GitLab KOTS Installation Test"

# Configuration
CUSTOMER_NAME="GitHub CI"
NAMESPACE="gitlab"
APP_NAME="gitlab-community-edition"
SHARED_PASSWORD="TestAdminPassword123!"

# Validate required environment variables
validate_env_vars "TEST_VERSION" "REPLICATED_API_TOKEN" || exit 1

echo "Installing KOTS for version: ${TEST_VERSION}"

# Install KOTS CLI
echo "Installing KOTS CLI..."
curl https://kots.io/install | bash

# Verify KOTS installation
echo "Verifying KOTS installation..."
kubectl kots version

# Download license using Replicated CLI (more reliable than curl API)
echo "Downloading license for customer: ${CUSTOMER_NAME}..."
replicated customer download-license --customer "${CUSTOMER_NAME}" > /tmp/license.yaml

echo "License downloaded successfully"

# Verify config values file exists
if [[ ! -f "/tmp/config-values.yaml" ]]; then
    echo "❌ Config values file not found at /tmp/config-values.yaml"
    exit 1
fi

echo "Config values file verified"

# Note: KOTS will create the namespace automatically, so we don't need to create it manually

# Support custom channel (default: unstable)
CHANNEL="${CHANNEL:-unstable}"
echo "Using channel: ${CHANNEL}"

# Install application using KOTS
echo "Installing ${APP_NAME} with KOTS from ${CHANNEL} channel..."
echo "This may take several minutes..."

kubectl kots install ${APP_NAME}/${CHANNEL} \
  --shared-password "${SHARED_PASSWORD}" \
  --license-file /tmp/license.yaml \
  --config-values /tmp/config-values.yaml \
  --namespace ${NAMESPACE} \
  --no-port-forward \
  --wait-duration 20m

echo "KOTS installation complete! Verifying deployments..."

# Verify complete GitLab installation (resources + endpoints + status)
verify_gitlab_installation "kubectl" "${NAMESPACE}"

echo "Testing GitLab UI accessibility through KOTS admin console..."
# Start admin console in background
kubectl kots admin-console --namespace ${NAMESPACE} &
KOTS_PID=$!

# Wait for port forward to establish
echo "Waiting for admin console port forward to establish..."
sleep 5

# Test UI accessibility using helper (retry with short intervals for robustness)
if test_gitlab_ui "http://localhost:30001" 5 3 "-f -s"; then
    echo "✅ GitLab UI is accessible through KOTS admin console"
else
    echo "❌ GitLab UI not accessible through KOTS admin console"
    kill $KOTS_PID || true
    exit 1
fi

# Cleanup admin console
echo "Cleaning up admin console port forward..."
kill $KOTS_PID || true
sleep 2

echo "Cluster verification complete!"

test_footer "GitLab KOTS Installation Test"
