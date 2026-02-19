#!/bin/bash
set -euo pipefail

# Load test helper library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"

test_header "GitLab Embedded Cluster Installation Test"

# Validate required environment variables
validate_env_vars "LICENSE_ID" "HOSTNAME" || exit 1

echo "✅ GitLab will be accessible at: https://${HOSTNAME}"

echo "Updating config values with ingress hostname..."
# Replace gitlab.local with actual hostname using a more reliable approach
ESCAPED_HOSTNAME=$(printf '%s\n' "$HOSTNAME" | sed 's/[[\.*^$()+?{|]/\\&/g')
sed -i "s/gitlab\\.local/$ESCAPED_HOSTNAME/g" /tmp/config-values.yaml

echo "Downloading Embedded Cluster installation assets for version: ${TEST_VERSION}"

# Support custom channel (default: unstable)
CHANNEL="${CHANNEL:-unstable}"
echo "Using channel: ${CHANNEL}"

curl -f "https://updates.alexparker.info/embedded/gitlab-community-edition/${CHANNEL}/${TEST_VERSION}" \
  -H "Authorization: ${LICENSE_ID}" \
  -o gitlab-community-edition-${CHANNEL}.tgz

echo "Extracting installation assets..."
tar -xzf gitlab-community-edition-${CHANNEL}.tgz

echo "Verifying extracted files..."
ls -la

echo "Installing GitLab Community Edition with Embedded Cluster..."
echo "This may take several minutes..."

# This command blocks until installation completes
sudo ./gitlab-community-edition install \
  --license license.yaml \
  --config-values /tmp/config-values.yaml \
  --admin-console-password "TestAdminPassword123!" \
  -y

echo "Installation complete! Verifying cluster and pods..."

# Set kubectl path and kubeconfig
KUBECTL="sudo KUBECONFIG=/var/lib/embedded-cluster/k0s/pki/admin.conf /var/lib/embedded-cluster/bin/kubectl"

# Wait for components to deploy asynchronously after EC installation in dependency order
echo "Waiting for components to deploy asynchronously in dependency order..."

# NGINX Ingress Controller: wait for creation → verify ready
echo "Stage 1: NGINX Ingress Controller"
wait_for_resource_creation "NGINX resources" 180 "$KUBECTL get deployment ingress-nginx-controller -n kotsadm >/dev/null 2>&1"
verify_nginx_ingress_installation "$KUBECTL" "kotsadm"

# cert-manager: wait for creation → verify ready (can overlap with GitLab creation)
echo "Stage 2: cert-manager"
wait_for_resource_creation "cert-manager resources" 180 "$KUBECTL get deployment cert-manager -n kotsadm >/dev/null 2>&1 && $KUBECTL get deployment cert-manager-webhook -n kotsadm >/dev/null 2>&1 && $KUBECTL get deployment cert-manager-cainjector -n kotsadm >/dev/null 2>&1"
verify_cert_manager_installation "$KUBECTL" "kotsadm"

# GitLab: wait for creation → verify ready
echo "Stage 3: GitLab"
wait_for_resource_creation "GitLab resources" 180 "$KUBECTL get deployment webservice-default -n kotsadm >/dev/null 2>&1 && $KUBECTL get statefulset postgresql -n kotsadm >/dev/null 2>&1 && $KUBECTL get statefulset redis-master -n kotsadm >/dev/null 2>&1"
verify_gitlab_installation "$KUBECTL" "kotsadm"

# Check cert-manager resources
echo "Checking ClusterIssuer for Let's Encrypt..."
$KUBECTL get clusterissuer letsencrypt-staging || {
    echo "❌ Let's Encrypt staging ClusterIssuer not found"
    exit 1
}

echo "Checking Certificate resource for GitLab..."
$KUBECTL get certificate -n kotsadm | grep gitlab || {
    echo "❌ GitLab Certificate resource not found"
    exit 1
}

# Check ingress resources
echo "Checking GitLab Ingress resources..."
$KUBECTL get ingress -n kotsadm | grep gitlab || {
    echo "❌ GitLab Ingress resource not found"
    exit 1
}

# Validate Let's Encrypt certificate status
echo "Checking Let's Encrypt certificate status..."
CERT_NAME=$($KUBECTL get certificate -n kotsadm -o name | grep gitlab | head -1 | cut -d'/' -f2)
if [[ -n "$CERT_NAME" ]]; then
    echo "Found certificate: $CERT_NAME"
    $KUBECTL describe certificate "$CERT_NAME" -n kotsadm | grep -E "(Status|Ready|Message)" || true

    # Check if certificate is ready
    if $KUBECTL get certificate "$CERT_NAME" -n kotsadm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
        echo "✅ Let's Encrypt certificate is ready"
    else
        echo "⚠️  Let's Encrypt certificate is not ready yet"
        echo "Certificate status:"
        $KUBECTL get certificate "$CERT_NAME" -n kotsadm -o yaml | grep -A10 "status:"
    fi
else
    echo "❌ No GitLab certificate found"
fi

# Test GitLab UI accessibility via HTTPS ingress
echo "Testing GitLab UI accessibility via HTTPS ingress at: https://${HOSTNAME}"
if ! test_gitlab_ui "https://${HOSTNAME}" 10 30 "-f -s -I -k"; then
    echo "❌ GitLab UI not accessible via HTTPS after 10 attempts"
    echo "Debugging ingress configuration..."
    $KUBECTL get ingress -n kotsadm -o yaml
    $KUBECTL get service -n kotsadm
    exit 1
fi

# Test with valid certificate (no -k flag)
echo "Testing certificate validity..."
if curl -f -s -I "https://${HOSTNAME}" | grep -q "HTTP/[0-9.]\+ 200"; then
    echo "✅ GitLab UI accessible with valid Let's Encrypt certificate!"
else
    echo "⚠️  GitLab UI accessible but certificate may not be valid"
fi

# Test HTTP to HTTPS redirect
echo "Testing HTTP to HTTPS redirect..."
if curl -s -I "http://${HOSTNAME}" | grep -q "Location: https://"; then
    echo "✅ HTTP to HTTPS redirect is working!"
else
    echo "⚠️  HTTP to HTTPS redirect may not be configured properly"
fi

echo "Cluster verification complete!"

test_footer "GitLab Embedded Cluster Installation Test"
echo "✅ GitLab is accessible at: https://${HOSTNAME}"
