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

    # Create a fresh repo from template
    local tmp_dir
    tmp_dir=$(e2e.git.init_from_template "$template_dir")

    local push_result=0
    case "$platform" in
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
        *)
            log_error "Unknown platform: ${platform}"
            push_result=1
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

# Reset the gitops config-deploy repo to baseline.
# Args: $1 = platform (gitlab|gitea), $2 = template dir
e2e.reset.gitops_config_repo() {
    local platform="${1:-gitea}" template_dir="${2:-}"

    if [[ -z "$template_dir" ]]; then
        log_warn "No template dir specified for gitops config repo reset"
        return 1
    fi

    e2e.reset.repo "$platform" "config-deploy" "$template_dir"
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
# Full reset
# ---------------------------------------------------------------------------

# Reset everything: namespaces, ArgoCD apps, Nexus artifacts, Docker images.
# Does NOT reset repos (that requires template dirs and platform info).
e2e.reset.all() {
    log_info "=== Full E2E reset ==="
    e2e.reset.all_deploy_namespaces
    e2e.reset.all_argocd_apps
    e2e.reset.nexus_artifacts
    e2e.reset.registry_images
    log_ok "=== Full E2E reset complete ==="
}
