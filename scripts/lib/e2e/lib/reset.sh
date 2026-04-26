#!/usr/bin/env bash
# E2E Reset Library
#
# Functions for resetting E2E test state between runs.
# Provides granular reset for repos, k8s namespaces, ArgoCD apps, and Nexus artifacts.
#
# Prerequisites:
#   - Appropriate platform libraries must be sourceable
#   - Infrastructure must be running

[[ -n "${_E2E_RESET_LOADED:-}" ]] && return 0
_E2E_RESET_LOADED=1

_E2E_RESET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# Source dependent libraries (they have include guards, safe to source multiple times)
# shellcheck source=./gitlab-api.sh
source "${_E2E_RESET_LIB_DIR}/gitlab-api.sh"
# shellcheck source=./gitea-api.sh
source "${_E2E_RESET_LIB_DIR}/gitea-api.sh"
# shellcheck source=./git.sh
source "${_E2E_RESET_LIB_DIR}/git.sh"
# shellcheck source=./k8s.sh
source "${_E2E_RESET_LIB_DIR}/k8s.sh"
# shellcheck source=./argocd.sh
source "${_E2E_RESET_LIB_DIR}/argocd.sh"
# shellcheck source=./nexus.sh
source "${_E2E_RESET_LIB_DIR}/nexus.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Namespaces used by E2E deploy tests
_E2E_DEPLOY_NAMESPACES=(
    brik-e2e-k8s
    brik-e2e-gitops
    brik-e2e-helm
    brik-e2e-rollback
    brik-e2e-workflow
)

# ArgoCD applications used by E2E tests
_E2E_ARGOCD_APPS=(
    brik-e2e-gitops
    brik-e2e-rollback
)

# ---------------------------------------------------------------------------
# Platform -> git host resolution
# ---------------------------------------------------------------------------

# Map a CI platform name to the git host that actually serves the repos.
# briklab Jenkins consumes webhooks from Gitea, so platform=jenkins must
# dispatch to the gitea code path. Returns 0 with the host on stdout, or
# 1 when the platform is unknown.
_e2e.reset._resolve_git_host() {
    case "$1" in
        gitlab)            echo "gitlab" ;;
        gitea | jenkins)   echo "gitea"  ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Granular reset functions
# ---------------------------------------------------------------------------

# Reset a single test repo to its baseline template.
# Force-pushes the template content, overwriting all history.
# Args: $1 = platform (gitlab|gitea), $2 = project name, $3 = template dir
e2e.reset.repo() {
    local platform="$1" project_name="$2" template_dir="$3"

    if [[ ! -d "$template_dir" ]]; then
        log_warn "Template directory not found: ${template_dir}"
        return 1
    fi

    log_info "Resetting repo: ${project_name} (${platform})"

    local git_host
    git_host="$(_e2e.reset._resolve_git_host "$platform")" || {
        log_error "Unknown platform: ${platform}"
        return 1
    }

    # Create a fresh repo from template
    local tmp_dir
    tmp_dir=$(e2e.git.init_from_template "$template_dir")

    local push_result=0
    case "$git_host" in
        gitlab)
            local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
            local remote_url="${gitlab_url}/brik/${project_name}.git"

            # Unprotect main branch for force push
            local encoded_path
            encoded_path=$(printf '%s' "brik/${project_name}" | jq -sRr @uri 2>/dev/null || \
                python3 -c "import urllib.parse; print(urllib.parse.quote('brik/${project_name}', safe=''))" 2>/dev/null)
            e2e.gitlab.api_delete "projects/${encoded_path}/protected_branches/main"

            e2e.git.push "$tmp_dir" "$remote_url" "root" "$GITLAB_PAT" "--force" || push_result=1

            # Cancel auto-triggered pipelines
            local project_id
            project_id=$(e2e.gitlab.get_project_id "$encoded_path" 2>/dev/null || true)
            if [[ -n "$project_id" ]]; then
                e2e.gitlab.cancel_pipelines "$project_id" "running"
                e2e.gitlab.cancel_pipelines "$project_id" "pending"
            fi
            ;;
        gitea)
            local gitea_url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
            local remote_url="${gitea_url}/brik/${project_name}.git"
            local gitea_user="${GITEA_ADMIN_USER:-brik}"
            e2e.git.push "$tmp_dir" "$remote_url" "$gitea_user" "$GITEA_PAT" "--force" || push_result=1
            ;;
    esac

    rm -rf "$tmp_dir"

    if [[ $push_result -eq 0 ]]; then
        log_ok "Repo reset: ${project_name}"
    else
        log_error "Failed to reset repo: ${project_name}"
    fi
    return "$push_result"
}

# Reset all k8s E2E namespaces.
e2e.reset.all_deploy_namespaces() {
    log_info "Resetting E2E k8s namespaces..."
    for ns in "${_E2E_DEPLOY_NAMESPACES[@]}"; do
        e2e.k8s.clean_namespace "$ns"
    done
    log_ok "All E2E namespaces cleaned"
}

# Reset a single k8s namespace.
# Args: $1 = namespace
e2e.reset.namespace() {
    local namespace="$1"
    log_info "Cleaning namespace: ${namespace}"
    e2e.k8s.clean_namespace "$namespace"
}

# Reset an ArgoCD application (delete + wait).
# The app will be recreated by the next sync or setup script.
# Args: $1 = app name
e2e.reset.argocd_app() {
    local app_name="$1"
    log_info "Deleting ArgoCD app: ${app_name}"
    e2e.argocd.api_get "/api/v1/applications/${app_name}" &>/dev/null || {
        log_info "ArgoCD app '${app_name}' does not exist, skipping"
        return 0
    }

    curl -sf --max-time 30 -k \
        -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
        -X DELETE \
        "${_E2E_ARGOCD_URL}/api/v1/applications/${app_name}?cascade=true" &>/dev/null || true

    log_ok "ArgoCD app deleted: ${app_name}"
}

# Reset all ArgoCD E2E applications.
e2e.reset.all_argocd_apps() {
    log_info "Resetting E2E ArgoCD apps..."
    for app in "${_E2E_ARGOCD_APPS[@]}"; do
        e2e.reset.argocd_app "$app"
    done
}

# Reset a gitops config-deploy repo to baseline (empty repo with just a README).
# This reproduces the state after setup/gitea.sh creates the repo.
# The deploy pipeline (brik-lib deploy.gitops) will populate it on first run.
# Args: $1 = platform (gitlab|gitea), $2 = repo name
e2e.reset.gitops_config_repo() {
    local platform="${1:-gitea}" repo_name="${2:-config-deploy-gitops}"

    log_info "Resetting gitops config repo: ${repo_name} (${platform})"

    local git_host
    git_host="$(_e2e.reset._resolve_git_host "$platform")" || {
        log_error "Unknown platform: ${platform}"
        return 1
    }

    local tmp_dir
    tmp_dir=$(mktemp -d)
    (
        cd "$tmp_dir" || exit 1
        git init -b main >/dev/null 2>&1
        echo "# ${repo_name}" > README.md
        git add -A >/dev/null 2>&1
        git commit -m "Initial config" >/dev/null 2>&1
    )

    local push_result=0
    case "$git_host" in
        gitea)
            local gitea_url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
            local gitea_user="${GITEA_ADMIN_USER:-brik}"
            e2e.git.push "$tmp_dir" "${gitea_url}/brik/${repo_name}.git" "$gitea_user" "$GITEA_PAT" "--force" || push_result=1
            ;;
        gitlab)
            local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
            local encoded_path
            encoded_path=$(printf '%s' "brik/${repo_name}" | jq -sRr @uri 2>/dev/null || \
                python3 -c "import urllib.parse; print(urllib.parse.quote('brik/${repo_name}', safe=''))" 2>/dev/null)
            e2e.gitlab.api_delete "projects/${encoded_path}/protected_branches/main"
            e2e.git.push "$tmp_dir" "${gitlab_url}/brik/${repo_name}.git" "root" "$GITLAB_PAT" "--force" || push_result=1
            ;;
    esac

    rm -rf "$tmp_dir"

    if [[ $push_result -eq 0 ]]; then
        log_ok "Config repo reset: ${repo_name}"
    else
        log_error "Failed to reset config repo: ${repo_name}"
    fi
    return "$push_result"
}

# Rollback a config-deploy repo to a specific deploy commit.
# Finds the commit matching the given image tag pattern and force-pushes
# a reset to that state. This handles intermediate commits from
# auto-triggered builds (e.g. Jenkins webhook builds).
# Args: $1 = repo name, $2 = image tag pattern to revert to (e.g. ":0.1.0")
e2e.reset.rollback_config_repo() {
    local repo_name="$1" target_tag="$2"

    log_info "Rolling back ${repo_name} to deploy with tag '${target_tag}'..."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local gitea_user="${GITEA_ADMIN_USER:-brik}"
    local gitea_password="${GITEA_ADMIN_PASSWORD:-Brik-Gitea-2026}"
    local gitea_url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
    local remote_url="http://${gitea_user}:${gitea_password}@${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}/brik/${repo_name}.git"

    local result=0
    (
        cd "$tmp_dir" || exit 1
        git clone "$remote_url" repo >/dev/null 2>&1
        cd repo || exit 1

        # Find the commit that deployed the target tag
        local target_commit
        target_commit=$(git log --all --oneline --grep="deploy: update to ${target_tag}" --format="%H" | head -1)

        if [[ -z "$target_commit" ]]; then
            echo "ERROR: No commit found matching 'deploy: update to ${target_tag}'" >&2
            exit 1
        fi

        git reset --hard "$target_commit" >/dev/null 2>&1
        git push --force origin main >/dev/null 2>&1
    ) || result=1

    rm -rf "$tmp_dir"

    if [[ $result -eq 0 ]]; then
        log_ok "Config repo rolled back to ${target_tag}"
    else
        log_error "Failed to rollback config repo to ${target_tag}"
    fi
    return "$result"
}

# Reset all gitops config-deploy repos.
# Args: $1 = platform (gitlab|gitea)
e2e.reset.all_gitops_config_repos() {
    local platform="${1:-gitea}"

    for repo in config-deploy-gitops config-deploy-rollback; do
        e2e.reset.gitops_config_repo "$platform" "$repo"
    done
}

# Reset Nexus test artifacts.
e2e.reset.nexus_artifacts() {
    log_info "Resetting Nexus test artifacts..."
    e2e.nexus.delete_all_test_artifacts
    log_ok "Nexus test artifacts deleted"
}

# Reset Docker registry images (alias for Nexus Docker cleanup).
e2e.reset.registry_images() {
    log_info "Resetting Docker registry images..."
    e2e.nexus.delete_docker_images "brik/"
    log_ok "Docker registry images cleaned"
}

# ---------------------------------------------------------------------------
# Repo reset (all test projects)
# ---------------------------------------------------------------------------

# All test projects that have a template directory in test-projects/
_E2E_TEST_PROJECTS=(
    node-minimal
    python-minimal
    java-minimal
    rust-minimal
    dotnet-minimal
    node-full
    python-full
    java-full
    node-security
    node-deploy
    node-deploy-k8s
    node-deploy-ssh
    node-deploy-helm
    node-deploy-gitops
    node-deploy-gitops-rollback
    node-deploy-failure
    node-complete
    python-complete
    java-complete
    rust-complete
    dotnet-complete
    node-workflow-trunk
    node-error-build
    node-error-test
    invalid-config
)

# Config repos (gitops/rollback) -- reset to empty baseline
_E2E_CONFIG_REPOS=(
    config-deploy-gitops
    config-deploy-rollback
)

# Reset all test project repos to their baseline template.
# Args: $1 = platform (gitlab|gitea), $2 = optional single project name
e2e.reset.all_repos() {
    local platform="$1"
    local only="${2:-}"
    local project_root
    project_root="$(cd "${_E2E_RESET_LIB_DIR}/../../../.." && pwd)"
    local template_root="${project_root}/test-projects"

    local errors=0

    if [[ -n "$only" ]]; then
        # Single repo reset
        local template_dir="${template_root}/${only}"
        if [[ -d "$template_dir" ]]; then
            e2e.reset.repo "$platform" "$only" "$template_dir" || ((errors++)) || true
        else
            # Maybe it's a config repo
            case "$only" in
                config-deploy-*)
                    e2e.reset.gitops_config_repo "$platform" "$only" || ((errors++)) || true
                    ;;
                *)
                    log_error "Unknown project: ${only} (no template at ${template_dir})"
                    return 1
                    ;;
            esac
        fi
    else
        # All test projects
        log_info "Resetting all test project repos (${platform})..."
        for project in "${_E2E_TEST_PROJECTS[@]}"; do
            local template_dir="${template_root}/${project}"
            if [[ -d "$template_dir" ]]; then
                e2e.reset.repo "$platform" "$project" "$template_dir" || ((errors++)) || true
            else
                log_warn "Template missing for ${project}, skipping"
            fi
        done

        # Config repos
        log_info "Resetting config repos..."
        for repo in "${_E2E_CONFIG_REPOS[@]}"; do
            e2e.reset.gitops_config_repo "$platform" "$repo" || ((errors++)) || true
        done
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "${errors} repo(s) failed to reset"
        return 1
    fi
    log_ok "All repos reset"
}

# ---------------------------------------------------------------------------
# Full reset
# ---------------------------------------------------------------------------

# Reset everything: repos, namespaces, ArgoCD apps, Nexus artifacts, Docker images.
# Args: $1 = platform (gitlab|gitea) -- required for repo reset
e2e.reset.all() {
    local platform="${1:-}"

    log_info "=== Full E2E reset ==="
    if [[ -n "$platform" ]]; then
        e2e.reset.all_repos "$platform"
    else
        log_warn "No platform specified -- skipping repo reset"
    fi
    e2e.reset.all_deploy_namespaces
    e2e.reset.all_argocd_apps
    e2e.reset.nexus_artifacts
    e2e.reset.registry_images
    log_ok "=== Full E2E reset complete ==="
}
