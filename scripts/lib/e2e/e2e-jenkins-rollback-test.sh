#!/usr/bin/env bash
# E2E Jenkins Rollback Test
#
# Tests GitOps rollback via a chain of real commits (Jenkins + Gitea):
#   1. Push v0.1.0 to Gitea -> trigger Jenkins build -> ArgoCD synced
#   2. Push v0.2.0 to Gitea -> trigger Jenkins build -> ArgoCD synced with new image
#   3. Reset config-deploy-rollback repo to v0.1.0 deploy commit -> ArgoCD reverts to v0.1.0 image
#
# Configuration (env vars):
#   E2E_JENKINS_TIMEOUT - Build timeout in seconds (default: 300)
#
# Prerequisites:
#   - briklab Jenkins, Gitea, k3d, and ArgoCD must be running
#   - node-deploy-gitops-rollback must be pushed to Gitea (by the suite)
#   - config-deploy-rollback repo must exist on Gitea (created by setup/gitea.sh)
#   - JENKINS_ADMIN_PASSWORD, GITEA_PAT, ARGOCD_AUTH_TOKEN must be set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/argocd-portfwd.sh
source "${SCRIPT_DIR}/../auth/argocd-portfwd.sh"
# shellcheck source=../auth/argocd-token.sh
source "${SCRIPT_DIR}/../auth/argocd-token.sh"
reload_env

# Source E2E libraries
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source=lib/jenkins-api.sh
source "${SCRIPT_DIR}/lib/jenkins-api.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
# shellcheck source=lib/gitea-api.sh
source "${SCRIPT_DIR}/lib/gitea-api.sh"
# shellcheck source=lib/argocd.sh
source "${SCRIPT_DIR}/lib/argocd.sh"
# shellcheck source=lib/reset.sh
source "${SCRIPT_DIR}/lib/reset.sh"

GITEA_URL="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
TIMEOUT_SECONDS="${E2E_JENKINS_TIMEOUT:-300}"
ARGOCD_APP="brik-e2e-rollback"
JOB_NAME="node-deploy-gitops-rollback"
TEMPLATE_DIR="${PROJECT_ROOT}/test-projects/node-deploy-gitops-rollback"
CONFIG_REPO="config-deploy-rollback"
GITEA_USER="${GITEA_ADMIN_USER:-brik}"

JENKINS_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"
if [[ -z "$JENKINS_PASSWORD" ]]; then
    log_error "JENKINS_ADMIN_PASSWORD is not set in .env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Push a v0.2.0 tag to Gitea.
push_v0_2_0_gitea() {
    log_info "Pushing v0.2.0 to Gitea..."

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

    if e2e.git.push "$tmp_dir" "${GITEA_URL}/brik/${JOB_NAME}.git" "$GITEA_USER" "$GITEA_PAT" "--force"; then
        log_ok "Pushed v0.2.0 to Gitea"
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
log_info "=== Brik E2E Jenkins Rollback Test ==="
log_info "Jenkins job: ${JOB_NAME}"
log_info "ArgoCD app: ${ARGOCD_APP}"
log_info "Timeout: ${TIMEOUT_SECONDS}s"
echo ""

# Initialize assertion counters
assert.init

# Ensure ArgoCD port-forward is active
ensure_argocd_port_forward

# Verify Jenkins is reachable
log_info "Checking Jenkins..."
if ! e2e.jenkins.api_get "api/json" &>/dev/null; then
    log_error "Jenkins is not reachable"
    exit 1
fi
log_ok "Jenkins is ready"

# Wait for job to exist
log_info "Checking job '${JOB_NAME}'..."
JOB_FOUND=false
JOB_WAIT=0
while [[ $JOB_WAIT -lt 60 ]]; do
    if e2e.jenkins.api_get "job/${JOB_NAME}/api/json" &>/dev/null; then
        JOB_FOUND=true
        break
    fi
    printf "."
    sleep 5
    JOB_WAIT=$((JOB_WAIT + 5))
done
echo ""

if [[ "$JOB_FOUND" != "true" ]]; then
    log_error "Job '${JOB_NAME}' not found after 60s"
    exit 1
fi
log_ok "Job '${JOB_NAME}' found"

# Reset source repo to v0.1.0 baseline (undo any push_v0_2_0 from previous runs)
e2e.reset.repo "gitea" "$JOB_NAME" "$TEMPLATE_DIR"

# Reset config repo to baseline (clean state for repeatable runs)
e2e.reset.gitops_config_repo "gitea" "$CONFIG_REPO"

# =========================================================================
# Step 1: Deploy v0.1.0
# =========================================================================
echo ""
log_info "--- Step 1: Deploy v0.1.0 ---"

BUILD_NUMBER=$(e2e.jenkins.trigger_build "$JOB_NAME") || {
    log_error "Failed to trigger v0.1.0 build"
    exit 1
}
log_ok "Build #${BUILD_NUMBER} triggered for v0.1.0"

log_info "Waiting for v0.1.0 build..."
RESULT_V1=$(e2e.jenkins.wait_build "$JOB_NAME" "$BUILD_NUMBER" "$TIMEOUT_SECONDS") || true
echo ""

if [[ "$RESULT_V1" != "SUCCESS" ]]; then
    log_error "v0.1.0 build did not succeed (result: ${RESULT_V1})"
    exit 1
fi
log_ok "v0.1.0 build succeeded"

# Wait for ArgoCD to sync
log_info "Waiting for ArgoCD to sync (${ARGOCD_APP})..."
if ! e2e.argocd.wait_sync "$ARGOCD_APP" 180; then
    log_error "ArgoCD did not sync after v0.1.0 deploy"
    exit 1
fi
echo ""
log_ok "ArgoCD synced after v0.1.0"

IMAGE_V1=$(e2e.argocd.get_app_image "$ARGOCD_APP")
log_info "v0.1.0 image: ${IMAGE_V1}"

# =========================================================================
# Step 2: Deploy v0.2.0
# =========================================================================
echo ""
log_info "--- Step 2: Deploy v0.2.0 ---"

push_v0_2_0_gitea

# Wait briefly for Gitea webhook to trigger, then trigger manually
sleep 5

BUILD_NUMBER=$(e2e.jenkins.trigger_build "$JOB_NAME") || {
    log_error "Failed to trigger v0.2.0 build"
    exit 1
}
log_ok "Build #${BUILD_NUMBER} triggered for v0.2.0"

log_info "Waiting for v0.2.0 build..."
RESULT_V2=$(e2e.jenkins.wait_build "$JOB_NAME" "$BUILD_NUMBER" "$TIMEOUT_SECONDS") || true
echo ""

if [[ "$RESULT_V2" != "SUCCESS" ]]; then
    log_error "v0.2.0 build did not succeed (result: ${RESULT_V2})"
    exit 1
fi
log_ok "v0.2.0 build succeeded"

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

# Trigger ArgoCD sync explicitly
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
    log_ok "=== E2E JENKINS ROLLBACK TEST PASSED ==="
    exit 0
else
    log_error "=== E2E JENKINS ROLLBACK TEST FAILED ==="
    exit 1
fi
