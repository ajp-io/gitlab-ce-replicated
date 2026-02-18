#!/bin/bash
# Test GitLab installation on Embedded Cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

TEST_NAME="GitLab Embedded Cluster Installation"
NAMESPACE="default"

test_header "$TEST_NAME"

# Validate environment
validate_env_vars "TEST_VERSION" || exit 1

echo "Test version: $TEST_VERSION"
echo "Namespace: $NAMESPACE"

# Get Embedded Cluster version from embedded-cluster.yaml
EC_VERSION=$(grep "version:" "$SCRIPT_DIR/../manifests/embedded-cluster.yaml" | awk '{print $2}' | tr -d '"')
echo "Embedded Cluster version: $EC_VERSION"

# Download EC installer
echo "Downloading Embedded Cluster installer..."
curl -fsSL "https://github.com/replicatedhq/embedded-cluster/releases/download/$EC_VERSION/embedded-cluster-linux-amd64.tar.gz" \
    -o /tmp/ec-installer.tar.gz
tar -xzf /tmp/ec-installer.tar.gz -C /tmp/
sudo mv /tmp/embedded-cluster /usr/local/bin/

# Install GitLab with test config
echo "Installing GitLab..."
sudo embedded-cluster install \
    --license "$REPLICATED_LICENSE" \
    --config-values "$SCRIPT_DIR/../test/config-values.yaml" \
    --airgap-bundle "$AIRGAP_BUNDLE" \
    || {
        echo "❌ Installation failed"
        exit 1
    }

# Wait for installation to complete
echo "Waiting for GitLab to be ready..."
sleep 60

# Verify installations
verify_nginx_ingress_installation "kubectl" "ingress-nginx"
verify_cert_manager_installation "kubectl" "cert-manager"
verify_gitlab_installation "kubectl" "$NAMESPACE"

# Test GitLab UI
GITLAB_HOSTNAME=$(grep "gitlab_hostname" "$SCRIPT_DIR/../test/config-values.yaml" | awk '{print $2}')
test_gitlab_ui "https://$GITLAB_HOSTNAME"

test_footer "$TEST_NAME"
