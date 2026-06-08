#!/usr/bin/env bash
# E2E GitLab CD channel keystone.
#
# Proves the decoupled CI -> CD flow on a single repo (node-deploy-channel):
#   Phase 1 (CI):  brik integrate builds and publishes an immutable image to the
#                  release channel registry (no CD inputs -> brik-integrate.yml).
#   Phase 2 (CD):  brik deploy --version --environment resolves that version to a
#                  digest in the channel staging accepts, fails closed on
#                  require_digest, and deploys the pinned digest via gitops
#                  (CD inputs set -> brik-deploy.yml selected by include:rules).
#   Phase 3:       assert the ArgoCD app reached Synced + Healthy AND that the
#                  live image is digest-pinned (@sha256:) -- the keystone of the
#                  decoupling design (build once, deploy that exact digest).
#
# Configuration (env vars):
#   E2E_TIMEOUT - per-pipeline timeout in seconds (default: 900)
#
# Prerequisites:
#   - briklab GitLab, Gitea, k3d, ArgoCD running
#   - node-deploy-channel pushed to GitLab (by the suite)
#   - config-deploy-cd repo on Gitea + brik-e2e-cd ArgoCD app (setup)
#   - GITLAB_PAT, ARGOCD_AUTH_TOKEN set; Nexus publish creds on the brik group
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/argocd.sh
source "${SCRIPT_DIR}/lib/argocd.sh"
reload_env
briklab.auth.gitlab_pat

TIMEOUT_SECONDS="${E2E_TIMEOUT:-900}"
PROJECT_PATH="brik%2Fnode-deploy-channel"
PROJECT_NAME="brik/node-deploy-channel"
SEED_TAG="v0.1.0"
# Package tags the image with the release version without the leading "v"
# (cf. assert.image_tag in scenario.sh); brik deploy resolves that version in
# the registry, so the deploy input drops the "v".
DEPLOY_VERSION="0.1.0"
ENVIRONMENT="staging"
APP="brik-e2e-cd"

log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID="$(e2e.gitlab.get_project_id "$PROJECT_PATH")"
if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found (was it pushed?)"
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

e2e.argocd.ensure_port_forward || \
    log_warn "ArgoCD port-forward could not be established -- the assert may fail"

e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# ---------------------------------------------------------------------------
# Phase 1 -- CI: publish the artifact (no CD inputs -> brik-integrate.yml).
# ---------------------------------------------------------------------------
log_info "Phase 1: CI seed -- integrate ${SEED_TAG} (build + publish image)..."
CI_ID="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$SEED_TAG" "BRIK_WITH_PACKAGE=true")"
if [[ -z "$CI_ID" ]]; then
    log_error "failed to trigger the CI seed pipeline"
    exit 1
fi
log_ok "CI pipeline #${CI_ID} triggered"
CI_STATUS="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$CI_ID" "$TIMEOUT_SECONDS")" || true
echo ""
if [[ "$CI_STATUS" != "success" ]]; then
    log_error "CI seed pipeline did not succeed (status: ${CI_STATUS})"
    exit 1
fi
log_ok "CI seed published the artifact to the release channel"

# ---------------------------------------------------------------------------
# Phase 2 -- CD: deploy that version to staging (CD inputs -> brik-deploy.yml).
# ---------------------------------------------------------------------------
log_info "Phase 2: CD -- deploy ${DEPLOY_VERSION} to ${ENVIRONMENT}..."
CD_ID="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" \
    "BRIK_DEPLOY_VERSION=${DEPLOY_VERSION},BRIK_DEPLOY_ENVIRONMENT=${ENVIRONMENT}")"
if [[ -z "$CD_ID" ]]; then
    log_error "failed to trigger the CD pipeline"
    exit 1
fi
log_ok "CD pipeline #${CD_ID} triggered"
CD_STATUS="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$CD_ID" "$TIMEOUT_SECONDS")" || true
echo ""
if [[ "$CD_STATUS" != "success" ]]; then
    log_error "CD pipeline did not succeed (status: ${CD_STATUS})"
    exit 1
fi
log_ok "CD pipeline succeeded"

# ---------------------------------------------------------------------------
# Phase 3 -- assert the pinned digest reached the live cluster via ArgoCD.
# ---------------------------------------------------------------------------
if ! e2e.argocd.assert_synced "$APP" "$TIMEOUT_SECONDS"; then
    log_error "ArgoCD app '${APP}' did not reach Synced+Healthy"
    exit 1
fi

DEPLOYED_IMAGE="$(e2e.argocd.get_app_image "$APP")"
log_info "deployed image: ${DEPLOYED_IMAGE:-<none>}"
case "$DEPLOYED_IMAGE" in
    *@sha256:*)
        log_ok "deployed image is digest-pinned -- CD channel keystone PASSED"
        ;;
    *)
        log_error "deployed image is NOT digest-pinned: ${DEPLOYED_IMAGE:-<empty>}"
        exit 1
        ;;
esac
