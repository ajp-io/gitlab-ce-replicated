#!/bin/bash
# GitLab Test Helper Library
# Shared functions for KOTS, Embedded Cluster, and Helm installation tests

set -euo pipefail

#######################################
# Environment Validation
#######################################

# Validates that required environment variables are set
# Arguments:
#   $@: Variable names to validate
# Returns:
#   0 if all variables are set, 1 otherwise
# Example:
#   validate_env_vars "TEST_VERSION" "REPLICATED_API_TOKEN" || exit 1
validate_env_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Missing required environment variables: ${missing[*]}"
        return 1
    fi
    return 0
}

#######################################
# Test Output Formatting
#######################################

# Prints test header with timestamp
# Arguments:
#   $1: Test name
# Example:
#   test_header "GitLab KOTS Installation Test"
test_header() {
    local test_name="$1"
    echo "=== $test_name ==="
    echo "Starting at: $(date)"
}

# Prints test footer with timestamp
# Arguments:
#   $1: Test name
# Example:
#   test_footer "GitLab KOTS Installation Test"
test_footer() {
    local test_name="$1"
    echo "=== $test_name PASSED ==="
    echo "Completed at: $(date)"
}

#######################################
# Installation Verification (High-Level)
#######################################

# Verifies complete GitLab installation (resources + endpoints + status)
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "default")
# Returns:
#   0 on success
# Example:
#   verify_gitlab_installation "kubectl" "default"
#   verify_gitlab_installation "$KUBECTL" "kotsadm"
verify_gitlab_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-default}"

    echo "Verifying GitLab installation..."

    # Wait for resources in dependency order
    wait_for_gitlab_resources "$kubectl_cmd" "$namespace"

    # Check service endpoints
    wait_for_gitlab_endpoints "$kubectl_cmd" "$namespace"

    # Display final status
    display_gitlab_status "$kubectl_cmd" "$namespace"

    echo "✅ GitLab installation verified!"
}

# Verifies cert-manager installation (deployments + endpoints)
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Returns:
#   0 on success
# Example:
#   verify_cert_manager_installation "kubectl" "cert-manager"
#   verify_cert_manager_installation "$KUBECTL" "kotsadm"
verify_cert_manager_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Verifying cert-manager installation..."

    # Wait for resources
    wait_for_cert_manager_resources "$kubectl_cmd" "$namespace"

    # Check service endpoints
    wait_for_cert_manager_endpoints "$kubectl_cmd" "$namespace"

    # Display final status
    display_cert_manager_status "$kubectl_cmd" "$namespace"

    echo "✅ cert-manager installation verified!"
}

# Verifies NGINX Ingress Controller installation (deployment + endpoints)
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Returns:
#   0 on success
# Example:
#   verify_nginx_ingress_installation "kubectl" "ingress-nginx"
#   verify_nginx_ingress_installation "$KUBECTL" "kotsadm"
verify_nginx_ingress_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Verifying NGINX Ingress Controller installation..."

    # Wait for resources
    wait_for_nginx_ingress_resources "$kubectl_cmd" "$namespace"

    # Check service endpoints
    wait_for_nginx_ingress_endpoints "$kubectl_cmd" "$namespace"

    # Display final status
    display_nginx_ingress_status "$kubectl_cmd" "$namespace"

    echo "✅ NGINX Ingress Controller installation verified!"
}

#######################################
# GitLab Resource Waiting (Low-Level)
#######################################

# Waits for all GitLab resources to be ready in dependency order
# Note: Consider using verify_gitlab_installation() for complete verification
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "default")
# Returns:
#   0 on success
# Example:
#   wait_for_gitlab_resources "kubectl" "default"
#   wait_for_gitlab_resources "$KUBECTL" "kotsadm"
wait_for_gitlab_resources() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-default}"

    echo "Waiting for GitLab resources in dependency order..."

    # Stage 1: Migrations (must complete first)
    echo "Stage 1: Waiting for GitLab migrations..."
    echo "  Waiting for migrations job to complete..."
    $kubectl_cmd wait --for=condition=complete job/gitlab-migrations-1 \
        --namespace="$namespace" \
        --timeout=900s

    # Stage 2: StatefulSets (dependencies)
    echo "Stage 2: Waiting for StatefulSets..."
    echo "  Waiting for PostgreSQL StatefulSet to have ready replicas..."
    $kubectl_cmd wait statefulset/gitlab-postgresql \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Redis StatefulSet to have ready replicas..."
    $kubectl_cmd wait statefulset/gitlab-redis-master \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for Gitaly StatefulSet to have ready replicas..."
    $kubectl_cmd wait statefulset/gitlab-gitaly \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        -n "$namespace" \
        --timeout=300s

    # Stage 3: Core Deployments (depend on StatefulSets)
    echo "Stage 3: Waiting for GitLab Core Deployments..."
    echo "  Waiting for GitLab Webservice deployment to be available..."
    $kubectl_cmd wait deployment/gitlab-webservice-default \
        --for=condition=available \
        -n "$namespace" \
        --timeout=600s

    echo "  Waiting for GitLab Sidekiq deployment to be available..."
    $kubectl_cmd wait deployment/gitlab-sidekiq-all-in-1-v2 \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for GitLab Shell deployment to be available..."
    $kubectl_cmd wait deployment/gitlab-gitlab-shell \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for GitLab Toolbox deployment to be available..."
    $kubectl_cmd wait deployment/gitlab-toolbox \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    # Stage 4: Replicated SDK
    echo "Stage 4: Waiting for Replicated SDK..."
    echo "  Waiting for Replicated SDK deployment to be available..."
    $kubectl_cmd wait deployment/replicated \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "✅ All GitLab resources ready!"
}

# Waits for GitLab service endpoints using EndpointSlice
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "default")
#   $3: include Replicated SDK endpoints (default: "true")
# Returns:
#   0 on success
# Example:
#   wait_for_gitlab_endpoints "kubectl" "default"
wait_for_gitlab_endpoints() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-default}"
    local include_sdk="${3:-true}"

    echo "Waiting for GitLab service endpoints..."

    local services=(
        "gitlab-postgresql"
        "gitlab-redis-master"
        "gitlab-gitaly"
        "gitlab-webservice-default"
        "gitlab-sidekiq-all-in-1-v2"
        "gitlab-gitlab-shell"
        "gitlab-toolbox"
    )

    for service in "${services[@]}"; do
        echo "  Waiting for ${service} service to have endpoints..."
        $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
            endpointslice \
            -l kubernetes.io/service-name="$service" \
            -n "$namespace" \
            --timeout=300s
    done

    if [[ "$include_sdk" == "true" ]]; then
        echo "  Waiting for Replicated SDK service to have endpoints..."
        $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
            endpointslice \
            -l kubernetes.io/service-name=replicated \
            -n "$namespace" \
            --timeout=300s
    fi

    echo "✅ All GitLab service endpoints ready!"
}

#######################################
# Infrastructure Component Waiting (Low-Level)
#######################################

# Waits for cert-manager resources to be ready
# Note: Consider using verify_cert_manager_installation() for complete verification
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Returns:
#   0 on success
# Example:
#   wait_for_cert_manager_resources "kubectl" "cert-manager"
#   wait_for_cert_manager_resources "$KUBECTL" "kotsadm"
wait_for_cert_manager_resources() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Waiting for cert-manager components..."

    echo "  Waiting for cert-manager to be available..."
    $kubectl_cmd wait deployment/cert-manager \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for cert-manager-webhook to be available..."
    $kubectl_cmd wait deployment/cert-manager-webhook \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for cert-manager-cainjector to be available..."
    $kubectl_cmd wait deployment/cert-manager-cainjector \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "✅ cert-manager ready!"
}

# Waits for cert-manager service endpoints using EndpointSlice
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Returns:
#   0 on success
# Example:
#   wait_for_cert_manager_endpoints "kubectl" "cert-manager"
wait_for_cert_manager_endpoints() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Waiting for cert-manager service endpoints..."

    echo "  Waiting for cert-manager service to have endpoints..."
    $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
        endpointslice \
        -l kubernetes.io/service-name=cert-manager \
        -n "$namespace" \
        --timeout=300s

    echo "  Waiting for cert-manager-webhook service to have endpoints..."
    $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
        endpointslice \
        -l kubernetes.io/service-name=cert-manager-webhook \
        -n "$namespace" \
        --timeout=300s

    echo "✅ cert-manager service endpoints ready!"
}

# Waits for NGINX Ingress Controller resources to be ready
# Note: Consider using verify_nginx_ingress_installation() for complete verification
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Returns:
#   0 on success
# Example:
#   wait_for_nginx_ingress_resources "kubectl" "ingress-nginx"
#   wait_for_nginx_ingress_resources "$KUBECTL" "kotsadm"
wait_for_nginx_ingress_resources() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Waiting for NGINX Ingress Controller..."

    echo "  Waiting for NGINX Ingress Controller to be available..."
    $kubectl_cmd wait deployment/ingress-nginx-controller \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s

    echo "✅ NGINX Ingress Controller ready!"
}

# Waits for NGINX Ingress Controller service endpoints using EndpointSlice
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Returns:
#   0 on success
# Example:
#   wait_for_nginx_ingress_endpoints "kubectl" "ingress-nginx"
wait_for_nginx_ingress_endpoints() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Waiting for NGINX Ingress Controller service endpoints..."

    echo "  Waiting for NGINX Ingress Controller service to have endpoints..."
    $kubectl_cmd wait --for=jsonpath='{.endpoints[0]}' \
        endpointslice \
        -l kubernetes.io/service-name=ingress-nginx-controller-admission \
        -n "$namespace" \
        --timeout=300s

    echo "✅ NGINX Ingress Controller service endpoints ready!"
}

#######################################
# GitLab UI Testing
#######################################

# Tests GitLab UI accessibility with retry logic
# Arguments:
#   $1: URL to test
#   $2: maximum number of retries (default: 10)
#   $3: retry interval in seconds (default: 15)
#   $4: curl flags (default: "-k -f -s")
# Returns:
#   0 if UI is accessible, 1 otherwise
# Example:
#   test_gitlab_ui "https://gitlab.example.com" 10 30 "-k -f -s"
#   test_gitlab_ui "http://localhost:30001" 5 3 "-f -s"
test_gitlab_ui() {
    local url="$1"
    local max_retries="${2:-10}"
    local retry_interval="${3:-15}"
    local curl_flags="${4:--k -f -s}"

    echo "Testing GitLab UI accessibility at: $url"

    for ((i=1; i<=max_retries; i++)); do
        echo "Attempt $i/$max_retries: Testing GitLab UI..."

        # shellcheck disable=SC2086
        if curl $curl_flags "$url" > /dev/null 2>&1; then
            echo "✅ GitLab UI is accessible!"
            return 0
        elif [[ $i -eq $max_retries ]]; then
            echo "❌ GitLab UI not accessible after $max_retries attempts"
            return 1
        else
            echo "GitLab UI not ready yet, waiting ${retry_interval}s..."
            sleep "$retry_interval"
        fi
    done

    return 1
}

#######################################
# Status Display
#######################################

# Displays final status of GitLab resources
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "default")
# Example:
#   display_gitlab_status "kubectl" "default"
display_gitlab_status() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-default}"

    echo ""
    echo "Final deployment status:"
    $kubectl_cmd get deployment,statefulset,service,ingress -n "$namespace" | grep -E "gitlab|replicated" || true
    echo ""
}

# Displays final status of cert-manager resources
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "cert-manager")
# Example:
#   display_cert_manager_status "kubectl" "cert-manager"
display_cert_manager_status() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo ""
    echo "cert-manager status:"
    $kubectl_cmd get deployment,service -n "$namespace" -l app.kubernetes.io/name=cert-manager || true
    echo ""
}

# Displays final status of NGINX Ingress Controller resources
# Arguments:
#   $1: kubectl command (default: "kubectl")
#   $2: namespace (default: "ingress-nginx")
# Example:
#   display_nginx_ingress_status "kubectl" "ingress-nginx"
display_nginx_ingress_status() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo ""
    echo "NGINX Ingress Controller status:"
    $kubectl_cmd get deployment,service -n "$namespace" -l app.kubernetes.io/name=ingress-nginx || true
    echo ""
}

#######################################
# Resource Creation Polling
#######################################

# Waits for resources to be created before kubectl wait can be used
# Polls until a check command succeeds (used for Embedded Cluster async deployments)
# Arguments:
#   $1: Stage name (for logging)
#   $2: Timeout in seconds
#   $3: Check command to evaluate
# Returns:
#   0 if resources detected, 1 if timeout
# Example:
#   wait_for_resource_creation "NGINX resources" 180 "$KUBECTL get deployment ingress-nginx-controller -n kotsadm >/dev/null 2>&1"
wait_for_resource_creation() {
    local stage_name="$1"
    local timeout="$2"
    local check_command="$3"
    local poll_interval=5
    local elapsed=0

    echo "Stage: ${stage_name}"

    while [[ $elapsed -lt $timeout ]]; do
        echo "Checking for ${stage_name} (elapsed: ${elapsed}s/${timeout}s)..."

        if eval "$check_command"; then
            echo "✅ ${stage_name} detected after ${elapsed}s!"
            return 0
        fi

        if [[ $elapsed -ge $timeout ]]; then
            echo "⚠️  ${stage_name} timeout reached (${timeout}s) - proceeding anyway..."
            return 1
        fi

        echo "${stage_name} not ready yet, checking again in ${poll_interval}s..."
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    return 1
}
