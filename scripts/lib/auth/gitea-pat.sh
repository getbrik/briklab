#!/usr/bin/env bash
# Gitea PAT management - validate or regenerate via REST API.
#
# Usage:
#   source "path/to/auth/gitea-pat.sh"
#   ensure_gitea_pat              # default token name: brik-briklab
#   ensure_gitea_pat "my-token"   # custom token name

[[ -n "${_BRIKLAB_GITEA_PAT_LOADED:-}" ]] && return 0
_BRIKLAB_GITEA_PAT_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# Ensure a valid Gitea PAT exists.
# If GITEA_PAT is valid, does nothing.
# If invalid/missing, deletes stale token and creates a fresh one.
ensure_gitea_pat() {
    local token_name="${1:-brik-briklab}"
    local gitea_url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
    local admin_user="${GITEA_ADMIN_USER:-brik}"
    local admin_pass="${GITEA_ADMIN_PASSWORD:-Brik-Gitea-2026}"

    # Fast path: validate existing PAT
    if [[ -n "${GITEA_PAT:-}" ]]; then
        local code
        code=$(curl -sf -o /dev/null -w "%{http_code}" \
            -H "Authorization: token ${GITEA_PAT}" \
            "${gitea_url}/api/v1/user" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            log_ok "Gitea PAT valid"
            return 0
        fi
        log_warn "Gitea PAT invalid (HTTP ${code}), regenerating..."
    else
        log_warn "No GITEA_PAT set, creating one..."
    fi

    # Delete existing token with the same name (idempotent)
    curl -sf -X DELETE \
        -u "${admin_user}:${admin_pass}" \
        "${gitea_url}/api/v1/users/${admin_user}/tokens/${token_name}" 2>/dev/null || true

    # Create new token
    local response
    response=$(curl -sf -X POST \
        -u "${admin_user}:${admin_pass}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${token_name}\",\"scopes\":[\"all\"]}" \
        "${gitea_url}/api/v1/users/${admin_user}/tokens" 2>/dev/null || echo "")

    local new_pat
    new_pat=$(printf '%s' "$response" | jq -r '.sha1 // empty' 2>/dev/null || echo "")

    if [[ -z "$new_pat" ]]; then
        log_error "Failed to create Gitea PAT"
        return 1
    fi

    export GITEA_PAT="$new_pat"
    save_to_env "GITEA_PAT" "$new_pat"
    log_ok "Gitea PAT refreshed: ${new_pat:0:15}..."
}
