#!/usr/bin/env bash
# E2E GitLab Rollback Test
#
# Tests GitOps rollback via a chain of real commits (GitLab + ArgoCD).
# Delegates the 3-step flow to lib/rollback.sh and provides GitLab-specific callbacks.
#
# Configuration (env vars):
#   E2E_TIMEOUT - Pipeline timeout in seconds (default: 300)
#
# Prerequisites:
#   - briklab GitLab, Gitea, k3d, and ArgoCD must be running
#   - node-deploy-gitops-rollback must be pushed to GitLab (by the suite)
#   - config-deploy-rollback repo must exist on Gitea (created by setup/gitea.sh)
#   - GITLAB_PAT, GITEA_PAT, ARGOCD_AUTH_TOKEN must be set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/rollback.sh
source "${SCRIPT_DIR}/lib/rollback.sh"
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
reload_env
ensure_gitlab_pat

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
TIMEOUT_SECONDS="${E2E_TIMEOUT:-300}"
PROJECT_PATH="brik%2Fnode-deploy-gitops-rollback"
PROJECT_NAME="brik/node-deploy-gitops-rollback"
TEMPLATE_DIR="${PROJECT_ROOT}/test-projects/node-deploy-gitops-rollback"

# Get project ID upfront (needed by callbacks)
log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID=$(e2e.gitlab.get_project_id "$PROJECT_PATH")
if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found"
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

# Cancel any running pipelines
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# ---------------------------------------------------------------------------
# Callbacks for rollback.sh
# ---------------------------------------------------------------------------

_rollback_push_v020() {
    log_info "Pushing v0.2.0 to GitLab..."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cp -r "${TEMPLATE_DIR}"/. "${tmp_dir}/"
    (
        cd "$tmp_dir" || exit 1
        rm -rf .git
        echo '{"version": "0.2.0"}' > VERSION.json
        git init -b main >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit -m "Initial commit" >/dev/null 2>&1
        git tag v0.1.0 >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit --allow-empty -m "Bump to v0.2.0" >/dev/null 2>&1
        git tag v0.2.0 >/dev/null 2>&1
    )

    e2e.gitlab.api_delete "projects/${PROJECT_PATH}/protected_branches/main"

    if e2e.git.push "$tmp_dir" "${GITLAB_URL}/${PROJECT_NAME}.git" "root" "$GITLAB_PAT" "--force"; then
        log_ok "Pushed v0.2.0"
    else
        log_error "Failed to push v0.2.0"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
}

_rollback_trigger_deploy() {
    local tag="$1"
    local pipeline_id
    pipeline_id=$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$tag")
    if [[ -z "$pipeline_id" ]]; then
        log_error "Failed to trigger ${tag} pipeline"
        exit 1
    fi
    log_ok "Pipeline #${pipeline_id} triggered for ${tag}"

    log_info "Waiting for ${tag} pipeline..."
    local status
    status=$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$pipeline_id" "$TIMEOUT_SECONDS") || true
    echo ""

    if [[ "$status" != "success" ]]; then
        log_error "${tag} pipeline did not succeed (status: ${status})"
        exit 1
    fi
    log_ok "${tag} pipeline succeeded"
}

_rollback_cancel_auto_triggered() {
    sleep 3
    e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
    e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
e2e.rollback.run "gitlab" "node-deploy-gitops-rollback" \
    "brik-e2e-rollback" "config-deploy-rollback" "$TEMPLATE_DIR" "$TIMEOUT_SECONDS"
