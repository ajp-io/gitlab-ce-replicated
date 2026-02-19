#!/bin/bash
set -euo pipefail

# Load test helper library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"

test_header "GitLab Helm Installation Test (EKS + LoadBalancer + cert-manager)"

# Configuration
CUSTOMER_NAME="GitHub CI"
NAMESPACE="gitlab"

# Validate required environment variables
validate_env_vars "TEST_VERSION" "REPLICATED_API_TOKEN" || exit 1

CHANNEL="${CHANNEL:-unstable}"
echo "Using channel: ${CHANNEL}"
echo "Installing Helm chart for version: ${TEST_VERSION}"

# Download license to get customer email and license ID
echo "Downloading license for customer: ${CUSTOMER_NAME}..."
replicated customer download-license --customer "${CUSTOMER_NAME}" > /tmp/license.yaml

CUSTOMER_EMAIL=$(yq eval '.spec.customerEmail' /tmp/license.yaml)
LICENSE_ID=$(yq eval '.spec.licenseID' /tmp/license.yaml)

if [[ -z "$CUSTOMER_EMAIL" || "$CUSTOMER_EMAIL" == "null" ]]; then
    echo "❌ Failed to get customer email from license file"
    exit 1
fi

if [[ -z "$LICENSE_ID" || "$LICENSE_ID" == "null" ]]; then
    echo "❌ Failed to get license ID from license file"
    exit 1
fi

echo "✅ Customer email: ${CUSTOMER_EMAIL}"
echo "✅ License ID retrieved"

# Login to Replicated registry
echo "Logging in to Replicated registry..."
echo "${LICENSE_ID}" | helm registry login charts.alexparker.info \
    --username "${CUSTOMER_EMAIL}" \
    --password-stdin

echo "✅ Logged in to Replicated registry"

# Get GitLab version from local Chart.yaml
GITLAB_VERSION=$(yq eval '.version' charts/gitlab/Chart.yaml)

echo "GitLab chart version: ${GITLAB_VERSION}"

# Create GitLab namespace
echo "Creating ${NAMESPACE} namespace..."
kubectl create namespace ${NAMESPACE}

# Install GitLab from Replicated registry (includes bundled cert-manager and nginx-ingress)
echo "Installing GitLab from Replicated registry..."
echo "This includes bundled cert-manager and nginx-ingress charts"
echo "This may take 15-20 minutes due to migrations and initialization..."

# Prepare GitLab values (hostname will be updated after LoadBalancer is ready)
cp test/gitlab-values.yaml /tmp/gitlab-values.yaml

helm install gitlab \
  oci://charts.alexparker.info/gitlab-community-edition/${CHANNEL}/gitlab \
  --version ${GITLAB_VERSION} \
  --namespace ${NAMESPACE} \
  --values /tmp/gitlab-values.yaml \
  --username "${CUSTOMER_EMAIL}" \
  --password "${LICENSE_ID}" \
  --wait \
  --timeout 20m

echo "✅ GitLab installation complete"

# Wait for LoadBalancer to be provisioned (nginx-ingress is now bundled in gitlab namespace)
echo "Waiting for LoadBalancer to be provisioned..."
echo "This may take a few minutes for AWS NLB to provision..."
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0]}' \
  service/gitlab-nginx-ingress-controller \
  -n ${NAMESPACE} \
  --timeout=600s

# Get LoadBalancer hostname
echo "Getting LoadBalancer hostname..."
LOADBALANCER_HOSTNAME=$(kubectl get service gitlab-nginx-ingress-controller \
  -n ${NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [[ -z "$LOADBALANCER_HOSTNAME" || "$LOADBALANCER_HOSTNAME" == "null" ]]; then
    echo "❌ Failed to get LoadBalancer hostname"
    kubectl describe service gitlab-nginx-ingress-controller -n ${NAMESPACE}
    exit 1
fi

echo "✅ LoadBalancer hostname: ${LOADBALANCER_HOSTNAME}"

# Update GitLab hostname in values
EXTERNAL_URL="https://${LOADBALANCER_HOSTNAME}"
echo "GitLab will be accessible at: ${EXTERNAL_URL}"

# Update GitLab values with the LoadBalancer hostname
yq eval ".global.hosts.domain = \"${LOADBALANCER_HOSTNAME}\"" -i /tmp/gitlab-values.yaml
yq eval ".global.hosts.externalIP = \"${LOADBALANCER_HOSTNAME}\"" -i /tmp/gitlab-values.yaml

# Upgrade GitLab with the updated hostname
echo "Upgrading GitLab with LoadBalancer hostname..."
helm upgrade gitlab \
  oci://charts.alexparker.info/gitlab-community-edition/${CHANNEL}/gitlab \
  --version ${GITLAB_VERSION} \
  --namespace ${NAMESPACE} \
  --values /tmp/gitlab-values.yaml \
  --username "${CUSTOMER_EMAIL}" \
  --password "${LICENSE_ID}" \
  --reuse-values \
  --wait \
  --timeout 10m

echo "✅ GitLab upgraded with LoadBalancer hostname"

# Create self-signed ClusterIssuer for testing (since configureCertmanager=false)
echo "Creating self-signed ClusterIssuer for testing..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

# Create Certificate for GitLab with LoadBalancer hostname
echo "Creating Certificate for GitLab..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gitlab-tls
  namespace: ${NAMESPACE}
spec:
  secretName: gitlab-tls
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  dnsNames:
    - ${LOADBALANCER_HOSTNAME}
EOF

# Wait for certificate to be ready
echo "Waiting for certificate to be ready..."
kubectl wait --for=condition=Ready \
  certificate/gitlab-tls \
  -n ${NAMESPACE} \
  --timeout=300s

echo "✅ Certificate ready"

# Verify pod status
echo "Verifying pod status..."
kubectl get pods -n ${NAMESPACE}

# Verify all GitLab resources (adds endpoint checks that Helm test was missing)
verify_gitlab_installation "kubectl" "${NAMESPACE}"

# Verify Ingress created
echo "Verifying GitLab ingress..."
kubectl get ingress -n ${NAMESPACE}

# Test GitLab UI accessibility
echo "Testing GitLab UI accessibility via LoadBalancer..."

# Wait for LoadBalancer health checks and DNS propagation
echo "Waiting for LoadBalancer health checks to pass and DNS to propagate..."
sleep 60

# Test with retry logic (using -k for self-signed certificates)
if ! test_gitlab_ui "${EXTERNAL_URL}" 10 15 "-k -f -s"; then
    echo ""
    echo "=== Debugging Information ==="
    echo "Ingress details:"
    kubectl describe ingress -n ${NAMESPACE}
    echo ""
    echo "LoadBalancer service:"
    kubectl describe service gitlab-nginx-ingress-controller -n ${NAMESPACE}
    echo ""
    echo "Nginx controller logs:"
    kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=ingress-nginx --tail=50
    echo ""
    echo "Certificate status:"
    kubectl describe certificate gitlab-tls -n ${NAMESPACE}
    exit 1
fi

echo ""
echo "Final deployment status:"
kubectl get deployment,statefulset,service,ingress -n ${NAMESPACE}
echo ""
echo "LoadBalancer service status:"
kubectl get service gitlab-nginx-ingress-controller -n ${NAMESPACE}

echo ""
test_footer "GitLab Helm Installation Test"
