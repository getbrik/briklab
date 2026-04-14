#!/usr/bin/env bash
# ArgoCD API token management - validate or regenerate a non-expiring token.
#
# Usage:
#   source "path/to/auth/argocd-token.sh"
#   ensure_argocd_token

[[ -n "${_BRIKLAB_ARGOCD_TOKEN_LOADED:-}" ]] && return 0
_BRIKLAB_ARGOCD_TOKEN_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
# shellcheck source=./argocd-portfwd.sh
source "$(dirname "${BASH_SOURCE[0]}")/argocd-portfwd.sh"

# Ensure the 'brik' account exists in ArgoCD configmaps.
# Patches argocd-cm and argocd-rbac-cm, restarts if needed.
_ensure_argocd_brik_account() {
    local port="${ARGOCD_PORT:-9080}"

    kubectl patch configmap argocd-cm -n argocd --type merge \
        -p '{"data":{"accounts.brik":"apiKey"}}' 2>/dev/null || true
    kubectl patch configmap argocd-rbac-cm -n argocd --type merge \
        -p '{"data":{"policy.csv":"g, brik, role:admin\n"}}' 2>/dev/null || true

    # Check if restart is needed (account just created or not yet recognized)
    local acct_check
    acct_check=$(curl -sk -o /dev/null -w "%{http_code}" \
        "https://localhost:${port}/api/v1/account/brik" 2>/dev/null || echo "000")

    if [[ "$acct_check" == "000" || "$acct_check" == "404" ]]; then
        log_info "Restarting ArgoCD server for account changes..."
        kubectl rollout restart deployment argocd-server -n argocd
        kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
        ensure_argocd_port_forward
    fi
}

# Ensure a valid ArgoCD API token exists for the 'brik' account.
# If ARGOCD_AUTH_TOKEN is valid, does nothing.
# If invalid/missing, creates the brik account if needed and generates a non-expiring token.
ensure_argocd_token() {
    local port="${ARGOCD_PORT:-9080}"

    # Fast path: validate existing token
    if [[ -n "${ARGOCD_AUTH_TOKEN:-}" ]]; then
        local code
        code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
            "https://localhost:${port}/api/v1/account/brik" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            log_ok "ArgoCD API token valid"
            return 0
        fi
        log_warn "ArgoCD API token invalid (HTTP ${code}), regenerating..."
    else
        log_warn "No ARGOCD_AUTH_TOKEN set, creating one..."
    fi

    local admin_pass="${ARGOCD_ADMIN_PASSWORD:-}"
    if [[ -z "$admin_pass" ]]; then
        log_error "ARGOCD_ADMIN_PASSWORD not set -- cannot regenerate token"
        return 1
    fi

    # Ensure the brik account exists
    _ensure_argocd_brik_account

    # Get admin session token
    local admin_token
    admin_token=$(curl -sk "https://localhost:${port}/api/v1/session" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${admin_pass}\"}" \
        | jq -r '.token // empty' 2>/dev/null || echo "")

    if [[ -z "$admin_token" ]]; then
        log_error "Could not get ArgoCD admin session"
        return 1
    fi

    # Generate non-expiring API token for brik account
    local new_token
    new_token=$(curl -sk "https://localhost:${port}/api/v1/account/brik/token" \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" \
        -d '{"name":"briklab","expiresIn":0}' \
        | jq -r '.token // empty' 2>/dev/null || echo "")

    if [[ -z "$new_token" ]]; then
        log_error "Failed to generate ArgoCD API token"
        return 1
    fi

    export ARGOCD_AUTH_TOKEN="$new_token"
    save_to_env "ARGOCD_AUTH_TOKEN" "$new_token"
    log_ok "ArgoCD API token refreshed"
}
