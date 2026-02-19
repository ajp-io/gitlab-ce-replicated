#!/bin/bash
# GitLab Test Helper Library
# Shared functions for KOTS, Embedded Cluster, and Helm installation tests

set -euo pipefail

#######################################
# Environment Validation
#######################################

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

test_header() {
    local test_name="$1"
    echo "=== $test_name ==="
    echo "Starting at: $(date)"
}

test_footer() {
    local test_name="$1"
    echo "=== $test_name PASSED ==="
    echo "Completed at: $(date)"
}

#######################################
# Installation Verification
#######################################

verify_gitlab_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-default}"

    echo "Verifying GitLab installation..."

    # Wait for migrations job to complete
    echo "Waiting for GitLab migrations to complete..."
    $kubectl_cmd wait --for=condition=complete job/gitlab-migrations-1 \
        --namespace="$namespace" \
        --timeout=15m || {
            echo "❌ GitLab migrations failed or timed out"
            $kubectl_cmd logs -l job-name=gitlab-migrations-1 --namespace="$namespace" --tail=50
            return 1
        }
    echo "✅ Migrations completed"

    # Wait for core GitLab components
    echo "Waiting for GitLab core components..."
    local components=(
        "deployment/gitlab-webservice-default"
        "deployment/gitlab-sidekiq-all-in-1-v2"
        "statefulset/gitlab-gitaly"
        "deployment/gitlab-gitlab-shell"
        "deployment/gitlab-toolbox"
    )

    for component in "${components[@]}"; do
        echo "  Waiting for $component..."
        $kubectl_cmd rollout status "$component" --namespace="$namespace" --timeout=10m || {
            echo "❌ $component failed to become ready"
            return 1
        }
    done
    echo "✅ Core components ready"

    # Display final status
    echo "GitLab Pods:"
    $kubectl_cmd get pods --namespace="$namespace" | grep gitlab

    echo "✅ GitLab installation verified!"
}

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

verify_cert_manager_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-cert-manager}"

    echo "Verifying cert-manager installation..."

    local deployments=(
        "cert-manager"
        "cert-manager-cainjector"
        "cert-manager-webhook"
    )

    for deployment in "${deployments[@]}"; do
        echo "  Waiting for deployment/$deployment..."
        $kubectl_cmd rollout status "deployment/$deployment" \
            --namespace="$namespace" --timeout=5m || {
            echo "❌ $deployment failed"
            return 1
        }
    done

    echo "✅ cert-manager installation verified!"
}

verify_nginx_ingress_installation() {
    local kubectl_cmd="${1:-kubectl}"
    local namespace="${2:-ingress-nginx}"

    echo "Verifying NGINX Ingress installation..."

    echo "  Waiting for NGINX Ingress Controller to be available..."
    $kubectl_cmd wait deployment/ingress-nginx-controller \
        --for=condition=available \
        -n "$namespace" \
        --timeout=300s || {
        echo "❌ NGINX Ingress controller failed"
        return 1
    }

    echo "✅ NGINX Ingress installation verified!"
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
