#!/usr/bin/env bash
# E2E GitLab Rollback Test
#
# Tests GitOps rollback via a chain of real commits:
#   1. Trigger pipeline for v0.1.0 -> deploy -> ArgoCD synced
#   2. Push v0.2.0 -> trigger pipeline -> deploy -> ArgoCD synced with new image
#   3. Reset config-deploy-rollback repo to v0.1.0 deploy commit -> ArgoCD reverts to v0.1.0 image
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
# shellcheck source=../auth/gitlab-pat.sh
source "${SCRIPT_DIR}/../auth/gitlab-pat.sh"
# shellcheck source=../auth/argocd-portfwd.sh
source "${SCRIPT_DIR}/../auth/argocd-portfwd.sh"
# shellcheck source=../auth/argocd-token.sh
source "${SCRIPT_DIR}/../auth/argocd-token.sh"
reload_env
ensure_gitlab_pat

# Source E2E libraries
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
# shellcheck source=lib/argocd.sh
source "${SCRIPT_DIR}/lib/argocd.sh"
# shellcheck source=lib/reset.sh
source "${SCRIPT_DIR}/lib/reset.sh"

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
TIMEOUT_SECONDS="${E2E_TIMEOUT:-300}"
ARGOCD_APP="brik-e2e-rollback"
PROJECT_PATH="brik%2Fnode-deploy-gitops-rollback"
PROJECT_NAME="brik/node-deploy-gitops-rollback"
TEMPLATE_DIR="${PROJECT_ROOT}/test-projects/node-deploy-gitops-rollback"
CONFIG_REPO="config-deploy-rollback"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Push a v0.2.0 tag to GitLab by re-creating the repo with a modified file.
push_v0_2_0() {
    log_info "Pushing v0.2.0 to GitLab..."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cp -r "${TEMPLATE_DIR}"/. "${tmp_dir}/"
    (
        cd "$tmp_dir" || exit 1
        rm -rf .git
        # Modify a file to create a real change
        echo '{"version": "0.2.0"}' > VERSION.json
        git init -b main >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit -m "Initial commit" >/dev/null 2>&1
        git tag v0.1.0 >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit --allow-empty -m "Bump to v0.2.0" >/dev/null 2>&1
        git tag v0.2.0 >/dev/null 2>&1
    )

    # Unprotect main branch for force push
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik E2E GitLab Rollback Test ==="
log_info "ArgoCD app: ${ARGOCD_APP}"
log_info "Timeout: ${TIMEOUT_SECONDS}s"
echo ""

# Initialize assertion counters
assert.init

# Ensure ArgoCD port-forward is active
ensure_argocd_port_forward

# 1. Get project ID
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

# Reset source repo to v0.1.0 baseline (undo any push_v0_2_0 from previous runs)
# reset.repo cancels auto-triggered pipelines internally
e2e.reset.repo "gitlab" "node-deploy-gitops-rollback" "$TEMPLATE_DIR"

# Reset config repo to baseline (clean state for repeatable runs)
e2e.reset.gitops_config_repo "gitea" "$CONFIG_REPO"

# =========================================================================
# Step 1: Deploy v0.1.0
# =========================================================================
echo ""
log_info "--- Step 1: Deploy v0.1.0 ---"

PIPELINE_ID=$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "v0.1.0")
if [[ -z "$PIPELINE_ID" ]]; then
    log_error "Failed to trigger v0.1.0 pipeline"
    exit 1
fi
log_ok "Pipeline #${PIPELINE_ID} triggered for v0.1.0"

log_info "Waiting for v0.1.0 pipeline..."
STATUS_V1=$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$PIPELINE_ID" "$TIMEOUT_SECONDS") || true
echo ""

if [[ "$STATUS_V1" != "success" ]]; then
    log_error "v0.1.0 pipeline did not succeed (status: ${STATUS_V1})"
    exit 1
fi
log_ok "v0.1.0 pipeline succeeded"

# Wait for ArgoCD to sync
log_info "Waiting for ArgoCD to sync (${ARGOCD_APP})..."
if ! e2e.argocd.wait_sync "$ARGOCD_APP" 180; then
    log_error "ArgoCD did not sync after v0.1.0 deploy"
    exit 1
fi
echo ""
log_ok "ArgoCD synced after v0.1.0"

# Record image for later comparison
IMAGE_V1=$(e2e.argocd.get_app_image "$ARGOCD_APP")
log_info "v0.1.0 image: ${IMAGE_V1}"

# =========================================================================
# Step 2: Deploy v0.2.0
# =========================================================================
echo ""
log_info "--- Step 2: Deploy v0.2.0 ---"

push_v0_2_0

# Cancel auto-triggered pipelines from the push
sleep 3
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

PIPELINE_ID=$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "v0.2.0")
if [[ -z "$PIPELINE_ID" ]]; then
    log_error "Failed to trigger v0.2.0 pipeline"
    exit 1
fi
log_ok "Pipeline #${PIPELINE_ID} triggered for v0.2.0"

log_info "Waiting for v0.2.0 pipeline..."
STATUS_V2=$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$PIPELINE_ID" "$TIMEOUT_SECONDS") || true
echo ""

if [[ "$STATUS_V2" != "success" ]]; then
    log_error "v0.2.0 pipeline did not succeed (status: ${STATUS_V2})"
    exit 1
fi
log_ok "v0.2.0 pipeline succeeded"

# Trigger ArgoCD sync and wait for the image to change from v0.1.0
log_info "Triggering ArgoCD sync..."
e2e.argocd.trigger_sync "$ARGOCD_APP" || true

log_info "Waiting for image to change from v0.1.0..."
IMAGE_V2=$(e2e.argocd.wait_image_change "$ARGOCD_APP" "$IMAGE_V1" 180) || true
echo ""
log_info "v0.2.0 image: ${IMAGE_V2}"

# Assert the image changed
assert.not_empty "v0.1.0 image recorded" "$IMAGE_V1"
assert.not_empty "v0.2.0 image recorded" "$IMAGE_V2"
if [[ "$IMAGE_V1" != "$IMAGE_V2" ]]; then
    assert._pass "Image changed between v0.1.0 and v0.2.0"
else
    assert._fail "Image changed between v0.1.0 and v0.2.0" "both are '${IMAGE_V1}'"
fi

# =========================================================================
# Step 3: Rollback via config repo reset to v0.1.0 deploy commit
# =========================================================================
echo ""
log_info "--- Step 3: Rollback via config repo reset ---"

# Extract v0.1.0 tag for the rollback target
TAG_V1=$(e2e.argocd.extract_image_tag "$IMAGE_V1")
log_info "Rolling back config repo to tag '${TAG_V1}'..."
e2e.reset.rollback_config_repo "$CONFIG_REPO" "$TAG_V1"

# Trigger ArgoCD sync explicitly (don't wait for auto-sync)
log_info "Triggering ArgoCD sync..."
e2e.argocd.trigger_sync "$ARGOCD_APP" || true

# Wait for image to change back from v0.2.0
log_info "Waiting for image to change from v0.2.0..."
IMAGE_ROLLBACK=$(e2e.argocd.wait_image_change "$ARGOCD_APP" "$IMAGE_V2" 180) || true
echo ""
log_info "Rollback image: ${IMAGE_ROLLBACK}"

# Assert the image is back to v0.1.0
assert.equals "Rollback image matches v0.1.0" "$IMAGE_V1" "$IMAGE_ROLLBACK"

# =========================================================================
# Report
# =========================================================================
echo ""

if assert.report; then
    log_ok "=== E2E GITLAB ROLLBACK TEST PASSED ==="
    exit 0
else
    log_error "=== E2E GITLAB ROLLBACK TEST FAILED ==="
    exit 1
fi
