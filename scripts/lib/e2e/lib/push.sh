#!/usr/bin/env bash
# E2E push library - push repos and test projects to GitLab or Gitea.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/push.sh"
#   e2e.push.brik_repos "gitlab"
#   e2e.push.test_projects "gitlab" "node-minimal,node-full"
#
# Depends on: common.sh, lib/gitlab-api.sh, lib/gitea-api.sh, lib/git.sh

[[ -n "${_E2E_PUSH_LOADED:-}" ]] && return 0
_E2E_PUSH_LOADED=1

_E2E_PUSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=gitlab-api.sh
source "${_E2E_PUSH_DIR}/gitlab-api.sh"
# shellcheck source=gitea-api.sh
source "${_E2E_PUSH_DIR}/gitea-api.sh"
# shellcheck source=git.sh
source "${_E2E_PUSH_DIR}/git.sh"

# Resolved once, reused by all functions
_PUSH_PROJECT_ROOT="$(cd "${_E2E_PUSH_DIR}/../../../.." && pwd)"
_PUSH_BRIK_ROOT="$(cd "${_PUSH_PROJECT_ROOT}/../brik" && pwd)"

_PUSH_GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
_PUSH_GITEA_URL="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
_PUSH_TAG_NAME="v0.1.0"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Push a local directory as a Git repo to a VCS.
# Args: platform source_dir remote_path tag
e2e.push.to_vcs() {
    local platform="$1"
    local source_dir="$2"
    local remote_path="$3"
    local tag="$4"

    log_info "Pushing ${source_dir} -> ${remote_path}..."

    local tmp_dir
    tmp_dir=$(e2e.git.init_from_template "$source_dir" "$tag")

    local url user token
    if [[ "$platform" == "gitlab" ]]; then
        url="${_PUSH_GITLAB_URL}"
        user="root"
        token="${GITLAB_PAT:-}"

        # Unprotect main branch to allow force push (GitLab protects it by default)
        local encoded_path
        encoded_path=$(printf '%s' "$remote_path" | jq -sRr @uri 2>/dev/null || \
            python3 -c "import urllib.parse; print(urllib.parse.quote('${remote_path}', safe=''))" 2>/dev/null)
        e2e.gitlab.api_delete "projects/${encoded_path}/protected_branches/main"
    else
        url="${_PUSH_GITEA_URL}"
        user="${GITEA_ADMIN_USER:-brik}"
        token="${GITEA_PAT:-}"
    fi

    if e2e.git.push "$tmp_dir" "${url}/${remote_path}.git" "$user" "$token" "--force"; then
        log_ok "Pushed ${remote_path} with tag ${tag}"
    else
        log_error "Failed to push ${remote_path}"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Push Brik infrastructure repos.
# Args: platform ("gitlab" | "gitea")
e2e.push.brik_repos() {
    local platform="$1"

    log_info "=== Pushing Brik repos to briklab (${platform}) ==="
    echo ""

    if [[ "$platform" == "gitlab" ]]; then
        # GitLab needs group + separate gitlab-templates repo
        e2e.gitlab.ensure_group "brik"
        echo ""

        log_info "--- brik/brik (runtime, brik-lib, schemas) ---"
        e2e.gitlab.create_project "brik" "brik"
        e2e.push.to_vcs "gitlab" "$_PUSH_BRIK_ROOT" "brik/brik" "$_PUSH_TAG_NAME"
        echo ""

        log_info "--- brik/gitlab-templates (GitLab shared library) ---"
        e2e.gitlab.create_project "brik" "gitlab-templates"
        e2e.push.to_vcs "gitlab" "$_PUSH_BRIK_ROOT/shared-libs/gitlab" "brik/gitlab-templates" "$_PUSH_TAG_NAME"
        echo ""
    else
        # Gitea: single brik/brik repo (includes Jenkins shared lib)
        log_info "--- brik/brik (full repo) ---"
        e2e.gitea.create_repo "brik"
        e2e.push.to_vcs "gitea" "$_PUSH_BRIK_ROOT" "brik/brik" "$_PUSH_TAG_NAME"
        echo ""
    fi
}

# Push test projects from the test-projects/ directory.
# Args: platform projects_csv
e2e.push.test_projects() {
    local platform="$1"
    local projects_csv="$2"
    local pushed=()

    IFS=',' read -ra projects_array <<< "$projects_csv"
    for proj in "${projects_array[@]}"; do
        proj="$(echo "$proj" | tr -d '[:space:]')"
        [[ -z "$proj" ]] && continue

        local local_dir="${_PUSH_PROJECT_ROOT}/test-projects/${proj}"
        if [[ ! -d "$local_dir" ]]; then
            log_warn "Test project directory not found: ${local_dir} -- skipping"
            continue
        fi

        log_info "--- brik/${proj} (test project) ---"
        if [[ "$platform" == "gitlab" ]]; then
            e2e.gitlab.create_project "brik" "$proj"
        else
            e2e.gitea.create_repo "$proj"
        fi
        e2e.push.to_vcs "$platform" "$local_dir" "brik/${proj}" "$_PUSH_TAG_NAME"
        pushed+=("$proj")
        echo ""
    done

    local url
    if [[ "$platform" == "gitlab" ]]; then
        url="${_PUSH_GITLAB_URL}"
    else
        url="${_PUSH_GITEA_URL}"
    fi

    log_ok "=== All repos pushed successfully ==="
    echo ""
    echo -e "${BLUE}Projects on briklab (${platform}):${NC}"
    echo "  ${url}/brik/brik"
    [[ "$platform" == "gitlab" ]] && echo "  ${url}/brik/gitlab-templates"
    for proj in "${pushed[@]}"; do
        echo "  ${url}/brik/${proj}"
    done
}
