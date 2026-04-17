#!/usr/bin/env bash
# E2E ArgoCD Validation Library
#
# Functions for querying and validating ArgoCD application state.
# Uses the ArgoCD REST API via port-forward (localhost).
#
# Prerequisites:
#   - ArgoCD port-forward must be active (ensure_argocd_port_forward)
#   - ARGOCD_AUTH_TOKEN must be set (via ensure_argocd_token or .env)
#   - ARGOCD_PORT must be set (default: 9080)

[[ -n "${_E2E_ARGOCD_LOADED:-}" ]] && return 0
_E2E_ARGOCD_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_E2E_ARGOCD_URL="https://localhost:${ARGOCD_PORT:-9080}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# GET request to ArgoCD API.
# Args: $1 = API path (e.g. "/api/v1/applications/my-app")
# Output: JSON response on stdout
e2e.argocd.api_get() {
    local path="$1"
    curl -sf --max-time 30 -k \
        -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
        "${_E2E_ARGOCD_URL}${path}"
}

# ---------------------------------------------------------------------------
# Query functions
# ---------------------------------------------------------------------------

# Check if an ArgoCD application exists.
# Args: $1 = app name
# Returns: 0 if exists, 1 otherwise
e2e.argocd.app_exists() {
    local app_name="$1"
    e2e.argocd.api_get "/api/v1/applications/${app_name}" &>/dev/null
}

# Check if an ArgoCD application is synced.
# Args: $1 = app name
# Returns: 0 if synced, 1 otherwise
e2e.argocd.app_synced() {
    local app_name="$1"
    local status
    status=$(e2e.argocd.api_get "/api/v1/applications/${app_name}" | \
        jq -r '.status.sync.status // empty' 2>/dev/null)
    [[ "$status" == "Synced" ]]
}

# Check if an ArgoCD application is healthy.
# Args: $1 = app name
# Returns: 0 if healthy, 1 otherwise
e2e.argocd.app_healthy() {
    local app_name="$1"
    local health
    health=$(e2e.argocd.api_get "/api/v1/applications/${app_name}" | \
        jq -r '.status.health.status // empty' 2>/dev/null)
    [[ "$health" == "Healthy" ]]
}

# Get the deployed image from an ArgoCD application.
# Extracts the image from the live deployment's first container.
# Args: $1 = app name
# Output: image string on stdout
e2e.argocd.get_app_image() {
    local app_name="$1"
    local app_json
    app_json=$(e2e.argocd.api_get "/api/v1/applications/${app_name}" 2>/dev/null)

    # Try to extract from summary images first (most reliable)
    local image
    image=$(echo "$app_json" | jq -r '.status.summary.images[0] // empty' 2>/dev/null)

    if [[ -n "$image" ]]; then
        echo "$image"
        return 0
    fi

    # Fallback: extract from resource tree (Deployment spec)
    image=$(echo "$app_json" | jq -r '
        [.status.resources[]? | select(.kind == "Deployment")] | .[0] // empty
    ' 2>/dev/null)

    # If no image found in summary, return empty
    echo ""
}

# Get full application status JSON.
# Args: $1 = app name
# Output: JSON on stdout
e2e.argocd.get_app_status() {
    local app_name="$1"
    e2e.argocd.api_get "/api/v1/applications/${app_name}" 2>/dev/null
}

# Wait for an ArgoCD application to be synced and healthy.
# Args: $1 = app name, $2 = timeout (seconds, default 120)
# Returns: 0 if synced+healthy, 1 if timeout
e2e.argocd.wait_sync() {
    local app_name="$1" timeout="${2:-120}"
    local poll_interval=5
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if e2e.argocd.app_synced "$app_name" && e2e.argocd.app_healthy "$app_name"; then
            return 0
        fi
        printf "." >&2
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    echo "" >&2
    log_error "ArgoCD app '${app_name}' not synced/healthy after ${timeout}s"
    return 1
}
