#!/bin/bash
# Test GitLab installation via KOTS on existing cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

TEST_NAME="GitLab KOTS Installation"
NAMESPACE="default"

test_header "$TEST_NAME"

# Validate environment
validate_env_vars "TEST_VERSION" "REPLICATED_API_TOKEN" || exit 1

echo "Test version: $TEST_VERSION"
echo "Namespace: $NAMESPACE"

# Create Kind cluster
echo "Creating Kind cluster..."
kind create cluster --name gitlab-kots-test --wait 5m || {
    echo "❌ Failed to create Kind cluster"
    exit 1
}

# Install KOTS
echo "Installing KOTS..."
curl https://kots.io/install | bash
kubectl kots install gitlab-community-edition \
    --namespace "$NAMESPACE" \
    --shared-password "test123" \
    --license-file "$REPLICATED_LICENSE_FILE" \
    --config-values "$SCRIPT_DIR/../test/config-values.yaml" \
    --wait-duration 20m || {
        echo "❌ KOTS installation failed"
        exit 1
    }

# Verify GitLab installation
verify_gitlab_installation "kubectl" "$NAMESPACE"

# Port-forward and test UI
echo "Setting up port-forward..."
kubectl port-forward -n "$NAMESPACE" service/gitlab-webservice-default 30001:8080 &
PF_PID=$!
sleep 5

test_gitlab_ui "http://localhost:30001" 20 5

# Cleanup
kill $PF_PID || true

test_footer "$TEST_NAME"
