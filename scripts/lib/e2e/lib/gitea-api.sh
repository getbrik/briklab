#!/usr/bin/env bash
# E2E Gitea API Library
#
# Reusable functions for interacting with the Gitea API.
# Extracted from push-test-project-gitea.sh.
#
# Prerequisites:
#   - GITEA_PAT must be set (via ensure_gitea_pat or .env)
#   - GITEA_HOSTNAME / GITEA_HTTP_PORT for non-default URLs
#
# Note: In briklab, 'brik' is a user, not an organization.
# Use /api/v1/user/repos (not /api/v1/orgs/brik/repos).

[[ -n "${_E2E_GITEA_API_LOADED:-}" ]] && return 0
_E2E_GITEA_API_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_E2E_GITEA_URL="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"

# ---------------------------------------------------------------------------
# Low-level API
# ---------------------------------------------------------------------------

# GET request to Gitea API.
# Args: $1 = endpoint (e.g. "repos/brik/node-minimal")
# Output: JSON response on stdout
e2e.gitea.api_get() {
    local endpoint="$1"
    curl -sf --max-time 30 \
        -H "Authorization: token ${GITEA_PAT}" \
        "${_E2E_GITEA_URL}/api/v1/${endpoint}"
}

# POST request with JSON body.
# Args: $1 = endpoint, $2 = JSON body
# Output: JSON response on stdout
e2e.gitea.api_post() {
    local endpoint="$1"
    local json_body="${2:-}"
    if [[ -n "$json_body" ]]; then
        curl -sf --max-time 30 \
            -H "Authorization: token ${GITEA_PAT}" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "$json_body" \
            "${_E2E_GITEA_URL}/api/v1/${endpoint}"
    else
        curl -sf --max-time 30 \
            -H "Authorization: token ${GITEA_PAT}" \
            -X POST \
            "${_E2E_GITEA_URL}/api/v1/${endpoint}"
    fi
}

# DELETE request to Gitea API.
# Args: $1 = endpoint
e2e.gitea.api_delete() {
    local endpoint="$1"
    curl -sf --max-time 30 \
        -H "Authorization: token ${GITEA_PAT}" \
        -X DELETE \
        "${_E2E_GITEA_URL}/api/v1/${endpoint}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Repo management
# ---------------------------------------------------------------------------

# Create a repo under the authenticated user (idempotent).
# Args: $1 = repo name
e2e.gitea.create_repo() {
    local repo_name="$1"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: token ${GITEA_PAT}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"private\":false}" \
        "${_E2E_GITEA_URL}/api/v1/user/repos")

    case "$http_code" in
        201) log_ok "Gitea repo '${repo_name}' created" ;;
        409) log_info "Gitea repo '${repo_name}' already exists" ;;
        *)   log_warn "Gitea repo creation returned HTTP ${http_code}" ;;
    esac
}

# Delete a repo.
# Args: $1 = owner, $2 = repo name
e2e.gitea.delete_repo() {
    local owner="$1" repo_name="$2"
    e2e.gitea.api_delete "repos/${owner}/${repo_name}"
}

# Get commits for a repo.
# Args: $1 = owner, $2 = repo name, $3 = branch (optional)
# Output: commits JSON on stdout
e2e.gitea.get_repo_commits() {
    local owner="$1" repo_name="$2" branch="${3:-}"
    local endpoint="repos/${owner}/${repo_name}/commits"
    if [[ -n "$branch" ]]; then
        endpoint="${endpoint}?sha=${branch}"
    fi
    e2e.gitea.api_get "$endpoint"
}
