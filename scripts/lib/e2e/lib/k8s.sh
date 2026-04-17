#!/usr/bin/env bash
# E2E Kubernetes Validation Library
#
# Functions for querying and validating Kubernetes deployments.
# Used to verify that deploy stages have the expected effect.
#
# Prerequisites:
#   - kubectl must be available and configured (KUBECONFIG or k3d context)

[[ -n "${_E2E_K8S_LOADED:-}" ]] && return 0
_E2E_K8S_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Query functions
# ---------------------------------------------------------------------------

# Check if a deployment exists in a namespace.
# Args: $1 = namespace, $2 = deployment name
# Returns: 0 if exists, 1 otherwise
e2e.k8s.deployment_exists() {
    local namespace="$1" name="$2"
    kubectl get deployment "$name" -n "$namespace" &>/dev/null
}

# Check if a deployment is ready (all replicas available).
# Args: $1 = namespace, $2 = deployment name
# Returns: 0 if ready, 1 otherwise
e2e.k8s.deployment_ready() {
    local namespace="$1" name="$2"
    local json
    json=$(kubectl get deployment "$name" -n "$namespace" -o json 2>/dev/null) || return 1

    local desired ready
    desired=$(echo "$json" | jq -r '.spec.replicas // 0' 2>/dev/null)
    ready=$(echo "$json" | jq -r '.status.readyReplicas // 0' 2>/dev/null)

    [[ "$desired" -gt 0 && "$desired" == "$ready" ]]
}

# Get the container image of a deployment (first container).
# Args: $1 = namespace, $2 = deployment name
# Output: image string on stdout
e2e.k8s.get_deployment_image() {
    local namespace="$1" name="$2"
    kubectl get deployment "$name" -n "$namespace" -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].image // empty' 2>/dev/null
}

# Check if a pod matching a label selector is running.
# Args: $1 = namespace, $2 = label selector (e.g. "app=my-app")
# Returns: 0 if at least one running pod, 1 otherwise
e2e.k8s.pod_running() {
    local namespace="$1" label="$2"
    local running_count
    running_count=$(kubectl get pods -n "$namespace" -l "$label" -o json 2>/dev/null | \
        jq -r '[.items[] | select(.status.phase == "Running")] | length' 2>/dev/null || echo "0")
    [[ "$running_count" -gt 0 ]]
}

# Check if a service exists in a namespace.
# Args: $1 = namespace, $2 = service name
# Returns: 0 if exists, 1 otherwise
e2e.k8s.service_exists() {
    local namespace="$1" name="$2"
    kubectl get service "$name" -n "$namespace" &>/dev/null
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

# Create a namespace if it does not exist.
# Args: $1 = namespace
e2e.k8s.ensure_namespace() {
    local namespace="$1"
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        kubectl create namespace "$namespace" >/dev/null 2>&1
        log_ok "Namespace '${namespace}' created"
    fi
}

# Delete a namespace.
# Args: $1 = namespace
e2e.k8s.delete_namespace() {
    local namespace="$1"
    kubectl delete namespace "$namespace" --ignore-not-found >/dev/null 2>&1 || true
}

# Clean all resources in a namespace (without deleting the namespace itself).
# Args: $1 = namespace
e2e.k8s.clean_namespace() {
    local namespace="$1"
    kubectl delete all --all -n "$namespace" >/dev/null 2>&1 || true
}
