#!/usr/bin/env bash
# E2E rollback test library - 3-step GitOps rollback flow.
#
# Tests GitOps rollback via a chain of real commits:
#   1. Trigger pipeline for v0.1.0 -> deploy -> ArgoCD synced
#   2. Push v0.2.0 -> trigger pipeline -> deploy -> ArgoCD synced with new image
#   3. Reset config repo to v0.1.0 deploy commit -> ArgoCD reverts to v0.1.0 image
#
# The calling script must define these callback functions:
#   _rollback_push_v020              -> push v0.2.0 to the source repo
#   _rollback_trigger_deploy tag     -> trigger a pipeline/build for the given tag, wait for success
#                                       must set RESULT_STATUS to the final status
#   _rollback_cancel_auto_triggered  -> cancel auto-triggered pipelines/builds after a push
#
# Then call:
#   e2e.rollback.run platform project_name argocd_app config_repo template_dir timeout
#
# Depends on: common.sh, lib/assert.sh, lib/argocd.sh, lib/reset.sh

[[ -n "${_E2E_ROLLBACK_LOADED:-}" ]] && return 0
_E2E_ROLLBACK_LOADED=1

_E2E_ROLLBACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=assert.sh
source "${_E2E_ROLLBACK_DIR}/assert.sh"
# shellcheck source=argocd.sh
source "${_E2E_ROLLBACK_DIR}/argocd.sh"
# shellcheck source=reset.sh
source "${_E2E_ROLLBACK_DIR}/reset.sh"

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Run the full 3-step rollback test.
# Args: platform project_name argocd_app config_repo template_dir timeout
e2e.rollback.run() {
    local platform="$1"
    local project_name="$2"
    local argocd_app="$3"
    local config_repo="$4"
    local template_dir="$5"
    local timeout_seconds="${6:-300}"

    echo ""
    log_info "=== Brik E2E ${platform^} Rollback Test ==="
    log_info "ArgoCD app: ${argocd_app}"
    log_info "Timeout: ${timeout_seconds}s"
    echo ""

    # Initialize assertion counters
    assert.init

    # Ensure ArgoCD port-forward is active
    ensure_argocd_port_forward

    # Reset source repo to v0.1.0 baseline
    e2e.reset.repo "$platform" "$project_name" "$template_dir"

    # Reset config repo to baseline
    e2e.reset.gitops_config_repo "gitea" "$config_repo"

    # =========================================================================
    # Step 1: Deploy v0.1.0
    # =========================================================================
    echo ""
    log_info "--- Step 1: Deploy v0.1.0 ---"

    _rollback_trigger_deploy "v0.1.0"

    # Wait for ArgoCD to sync
    log_info "Waiting for ArgoCD to sync (${argocd_app})..."
    if ! e2e.argocd.wait_sync "$argocd_app" 180; then
        log_error "ArgoCD did not sync after v0.1.0 deploy"
        exit 1
    fi
    echo ""
    log_ok "ArgoCD synced after v0.1.0"

    # Record image for later comparison
    local image_v1
    image_v1=$(e2e.argocd.get_app_image "$argocd_app")
    log_info "v0.1.0 image: ${image_v1}"

    # =========================================================================
    # Step 2: Deploy v0.2.0
    # =========================================================================
    echo ""
    log_info "--- Step 2: Deploy v0.2.0 ---"

    _rollback_push_v020
    _rollback_cancel_auto_triggered

    _rollback_trigger_deploy "v0.2.0"

    # Trigger ArgoCD sync and wait for the image to change
    log_info "Triggering ArgoCD sync..."
    e2e.argocd.trigger_sync "$argocd_app" || true

    log_info "Waiting for image to change from v0.1.0..."
    local image_v2
    image_v2=$(e2e.argocd.wait_image_change "$argocd_app" "$image_v1" 180) || true
    echo ""
    log_info "v0.2.0 image: ${image_v2}"

    # Assert the image changed
    assert.not_empty "v0.1.0 image recorded" "$image_v1"
    assert.not_empty "v0.2.0 image recorded" "$image_v2"
    if [[ "$image_v1" != "$image_v2" ]]; then
        assert._pass "Image changed between v0.1.0 and v0.2.0"
    else
        assert._fail "Image changed between v0.1.0 and v0.2.0" "both are '${image_v1}'"
    fi

    # =========================================================================
    # Step 3: Rollback via config repo reset to v0.1.0 deploy commit
    # =========================================================================
    echo ""
    log_info "--- Step 3: Rollback via config repo reset ---"

    local tag_v1
    tag_v1=$(e2e.argocd.extract_image_tag "$image_v1")
    log_info "Rolling back config repo to tag '${tag_v1}'..."
    e2e.reset.rollback_config_repo "$config_repo" "$tag_v1"

    # Trigger ArgoCD sync explicitly
    log_info "Triggering ArgoCD sync..."
    e2e.argocd.trigger_sync "$argocd_app" || true

    # Wait for image to change back from v0.2.0
    log_info "Waiting for image to change from v0.2.0..."
    local image_rollback
    image_rollback=$(e2e.argocd.wait_image_change "$argocd_app" "$image_v2" 180) || true
    echo ""
    log_info "Rollback image: ${image_rollback}"

    # Assert the image is back to v0.1.0
    assert.equals "Rollback image matches v0.1.0" "$image_v1" "$image_rollback"

    # =========================================================================
    # Report
    # =========================================================================
    echo ""

    if assert.report; then
        log_ok "=== E2E ${platform^^} ROLLBACK TEST PASSED ==="
        return 0
    else
        log_error "=== E2E ${platform^^} ROLLBACK TEST FAILED ==="
        return 1
    fi
}
