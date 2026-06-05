#!/usr/bin/env bash
# ArgoCD API token management - validate or regenerate a non-expiring token.
#
# Usage:
#   source "path/to/auth/argocd-token.sh"
#   briklab.auth.argocd_token

[[ -n "${_BRIKLAB_ARGOCD_TOKEN_LOADED:-}" ]] && return 0
_BRIKLAB_ARGOCD_TOKEN_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
# shellcheck source=./argocd-portfwd.sh
source "$(dirname "${BASH_SOURCE[0]}")/argocd-portfwd.sh"
# shellcheck source=../checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/../checks.sh"

# Ensure the 'brik' account exists in ArgoCD configmaps.
# Patches argocd-cm and argocd-rbac-cm, restarts if needed.
briklab.auth._argocd_brik_account() {
    local port="${ARGOCD_PORT:-9080}"

    kubectl patch configmap argocd-cm -n argocd --type merge \
        -p '{"data":{"accounts.brik":"apiKey"}}' 2>/dev/null || true

    # ArgoCD v3.x stricter RBAC for apiKey accounts: the JWT subject
    # encoded by ArgoCD for an account-generated API token is
    # "<account>:apiKey" (decoded from the JWT `sub` claim), NOT just
    # "<account>". Casbin grouping rules must therefore reference the
    # `apiKey` qualified subject, otherwise effective permissions
    # fall back to policy.default (readonly or empty) and apps look
    # like "application does not exist" even for an admin grant.
    #
    # We bind brik:apiKey to both role:admin (back-compat / future
    # actions) and an explicit role:brik covering the actions the
    # briklab E2E scenarios actually need (sync/get/override on
    # applications, get/list on repos). The literal 'brik' bindings
    # are kept so future SSO logins of a 'brik' user pick up the same
    # role.
    local _rbac
    read -r -d '' _rbac <<'POLICY' || true
p, role:brik, applications, get, */*, allow
p, role:brik, applications, sync, */*, allow
p, role:brik, applications, action/*, */*, allow
p, role:brik, applications, override, */*, allow
p, role:brik, repositories, get, *, allow
p, role:brik, repositories, list, *, allow
p, role:brik, clusters, get, *, allow
g, brik, role:admin
g, brik, role:brik
g, brik:apiKey, role:admin
g, brik:apiKey, role:brik
POLICY
    kubectl patch configmap argocd-rbac-cm -n argocd --type merge \
        -p "$(jq -nc --arg p "$_rbac" '{data:{"policy.csv":$p}}')" 2>/dev/null || true

    # Check if restart is needed (account just created or not yet recognized)
    local acct_check
    acct_check=$(curl -sk -o /dev/null -w "%{http_code}" \
        "https://localhost:${port}/api/v1/account/brik" 2>/dev/null || echo "000")

    if [[ "$acct_check" == "000" || "$acct_check" == "404" ]]; then
        log_info "Restarting ArgoCD server for account changes..."
        kubectl rollout restart deployment argocd-server -n argocd
        kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
        briklab.auth.argocd_portfwd
    fi
}

# Ensure a valid ArgoCD API token exists for the 'brik' account.
# If ARGOCD_AUTH_TOKEN is valid, does nothing.
# If invalid/missing, creates the brik account if needed and generates a non-expiring token.
briklab.auth.argocd_token() {
    local port="${ARGOCD_PORT:-9080}"

    # Fast path: validate existing token (shared probe with verify/preflight)
    if briklab.check.argocd_token; then
        log_ok "ArgoCD API token valid"
        return 0
    fi
    if [[ -n "${ARGOCD_AUTH_TOKEN:-}" ]]; then
        log_warn "ArgoCD API token invalid, regenerating..."
    else
        log_warn "No ARGOCD_AUTH_TOKEN set, creating one..."
    fi

    local admin_pass="${ARGOCD_ADMIN_PASSWORD:-}"
    if [[ -z "$admin_pass" ]]; then
        log_error "ARGOCD_ADMIN_PASSWORD not set -- cannot regenerate token"
        return 1
    fi

    # Ensure the brik account exists
    briklab.auth._argocd_brik_account

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
