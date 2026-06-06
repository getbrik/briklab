#!/usr/bin/env bash
# E2E Gitea API Library
#
# Reusable functions for interacting with the Gitea API.
# Extracted from gitea-push.sh.
#
# Prerequisites:
#   - GITEA_PAT must be set (via briklab.auth.gitea_pat or .env)
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
    briklab.http.get "${_E2E_GITEA_URL}/api/v1/${endpoint}" \
        -H "Authorization: token ${GITEA_PAT}"
}

# POST request with JSON body.
# Args: $1 = endpoint, $2 = JSON body
# Output: JSON response on stdout
e2e.gitea.api_post() {
    local endpoint="$1"
    local json_body="${2:-}"
    if [[ -n "$json_body" ]]; then
        briklab.http.post_json "${_E2E_GITEA_URL}/api/v1/${endpoint}" "$json_body" \
            -H "Authorization: token ${GITEA_PAT}"
    else
        briklab.http.get "${_E2E_GITEA_URL}/api/v1/${endpoint}" \
            -X POST -H "Authorization: token ${GITEA_PAT}"
    fi
}

# DELETE request to Gitea API.
# Args: $1 = endpoint
e2e.gitea.api_delete() {
    local endpoint="$1"
    briklab.http.delete "${_E2E_GITEA_URL}/api/v1/${endpoint}" \
        -H "Authorization: token ${GITEA_PAT}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Repo management
# ---------------------------------------------------------------------------

# Create a repo under the authenticated user (idempotent).
# Args: $1 = repo name
e2e.gitea.create_repo() {
    local repo_name="$1"
    local http_code
    http_code=$(briklab.http.code "${_E2E_GITEA_URL}/api/v1/user/repos" --max-time 10 \
        -H "Authorization: token ${GITEA_PAT}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"private\":false}")

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

# ---------------------------------------------------------------------------
# Pull requests (Gitea's name for a change request)
# ---------------------------------------------------------------------------

# Open a pull request from an existing head branch into a base branch.
# The head branch must already be pushed (e.g. via e2e.git.push_branch).
# Args: $1 = owner, $2 = repo, $3 = head branch, $4 = base branch,
#       $5 = title (optional)
# Output: PR number (index) on stdout; empty on failure.
#
# Gitea endpoint: POST /repos/{owner}/{repo}/pulls -- the JSON uses `head`
# and `base` (branch names), mirroring GitHub. This is the git-host-specific
# half; the orchestrator-facing contract (a change-request number) is uniform
# across hosts -- see e2e.scm.create_change_request.
e2e.gitea.create_pull_request() {
    local owner="$1" repo="$2" head="$3" base="${4:-main}"
    local title="${5:-E2E PR ${head}}"
    local body resp number
    body="$(jq -n --arg head "$head" --arg base "$base" --arg title "$title" \
        '{head: $head, base: $base, title: $title}')"
    resp="$(e2e.gitea.api_post "repos/${owner}/${repo}/pulls" "$body")"
    number="$(printf '%s' "$resp" | jq -r '.number // empty' 2>/dev/null || true)"

    # Idempotent re-runs: Gitea rejects a second PR for the same head->base
    # with 409 (an open PR already exists), returning no number. Fall back to
    # looking the open PR up by head ref so a repeated scenario run reuses it
    # instead of failing on "Failed to open pull request".
    if [[ -z "$number" ]]; then
        number="$(e2e.gitea.api_get "repos/${owner}/${repo}/pulls?state=open" | \
            jq -r --arg head "$head" \
            'map(select(.head.ref == $head)) | .[0].number // empty' 2>/dev/null || true)"
    fi
    printf '%s' "$number"
}
