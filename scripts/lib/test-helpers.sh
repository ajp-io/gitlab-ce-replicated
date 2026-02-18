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
    local max_attempts="${2:-30}"
    local sleep_interval="${3:-10}"

    echo "Testing GitLab UI accessibility at $url..."

    for attempt in $(seq 1 $max_attempts); do
        echo "  Attempt $attempt/$max_attempts..."
        if curl -k -f -s --max-time 10 "$url" > /dev/null 2>&1; then
            echo "✅ GitLab UI is accessible!"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo "  Not ready yet, waiting ${sleep_interval}s..."
            sleep "$sleep_interval"
        fi
    done

    echo "❌ GitLab UI not accessible after $max_attempts attempts"
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

    $kubectl_cmd rollout status deployment/ingress-nginx-controller \
        --namespace="$namespace" --timeout=5m || {
        echo "❌ NGINX Ingress controller failed"
        return 1
    }

    echo "✅ NGINX Ingress installation verified!"
}
