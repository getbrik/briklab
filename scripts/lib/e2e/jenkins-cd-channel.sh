#!/usr/bin/env bash
# E2E Jenkins CD channel keystone.
#
# Proves the decoupled CD verb on Jenkins (the brikDeploy pipelineJob), the
# Jenkins counterpart of gitlab-cd-channel.sh. It deploys to the dev
# environment (ArgoCD app brik-e2e-cd-dev) so it is independent of the GitLab
# keystone (which uses staging / brik-e2e-cd) and also exercises the
# build-once / deploy-many property (the same digest to a second environment).
#
#   Phase 1: ensure an immutable artifact exists in the release channel
#            (published by CI -- the node-deploy-channel integrate flow).
#   Phase 2: trigger node-deploy-channel-deploy (brikDeploy) with
#            BRIK_DEPLOY_VERSION + BRIK_DEPLOY_ENVIRONMENT=dev.
#   Phase 3: assert ArgoCD brik-e2e-cd-dev is Synced+Healthy on a
#            digest-pinned image.
#
# Configuration (env vars):
#   E2E_JENKINS_TIMEOUT - per-build timeout in seconds (default: 900)
#
# Prerequisites:
#   - briklab Jenkins, Gitea, k3d, ArgoCD running
#   - node-deploy-channel pushed to Gitea (by the suite); the
#     node-deploy-channel-deploy CD pipelineJob exists (JCasC)
#   - config-deploy-cd-dev repo on Gitea + brik-e2e-cd-dev ArgoCD app (setup)
#   - the release-channel image already published by a CI run
#   - JENKINS_ADMIN_PASSWORD, ARGOCD_AUTH_TOKEN set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/jenkins-api.sh
source "${SCRIPT_DIR}/lib/jenkins-api.sh"
# shellcheck source=lib/nexus.sh
source "${SCRIPT_DIR}/lib/nexus.sh"
# shellcheck source=lib/argocd.sh
source "${SCRIPT_DIR}/lib/argocd.sh"
reload_env

TIMEOUT_SECONDS="${E2E_JENKINS_TIMEOUT:-900}"
CD_JOB="node-deploy-channel-deploy"
IMAGE_PATH="brik/node-deploy-channel"
DEPLOY_VERSION="0.1.0"
ENVIRONMENT="dev"
APP="brik-e2e-cd-dev"

if [[ -z "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
    log_error "JENKINS_ADMIN_PASSWORD is not set in .env"
    exit 1
fi

log_info "Checking Jenkins + CD job '${CD_JOB}'..."
if ! e2e.jenkins.api_get "api/json" &>/dev/null; then
    log_error "Jenkins is not reachable"
    exit 1
fi
if ! e2e.jenkins.wait_job_exists "$CD_JOB" 60; then
    log_error "CD job '${CD_JOB}' not found (JCasC not applied?)"
    exit 1
fi
log_ok "CD job '${CD_JOB}' present"

e2e.argocd.ensure_port_forward || \
    log_warn "ArgoCD port-forward could not be established -- the assert may fail"

# ---------------------------------------------------------------------------
# Phase 1 -- the CI artifact must exist in the release channel.
# ---------------------------------------------------------------------------
log_info "Phase 1: verifying the release-channel artifact ${IMAGE_PATH}:${DEPLOY_VERSION}..."
if ! e2e.nexus.docker_tag_exists "$IMAGE_PATH" "$DEPLOY_VERSION"; then
    log_error "image ${IMAGE_PATH}:${DEPLOY_VERSION} is not in Nexus -- run the integrate (CI) flow first"
    exit 1
fi
log_ok "artifact present in the release channel"

# ---------------------------------------------------------------------------
# Phase 2 -- CD: deploy that version to dev via the brikDeploy pipelineJob.
# ---------------------------------------------------------------------------
log_info "Phase 2: CD -- deploy ${DEPLOY_VERSION} to ${ENVIRONMENT} via ${CD_JOB}..."
BUILD_NUM="$(e2e.jenkins.trigger_build "$CD_JOB" \
    "BRIK_DEPLOY_VERSION=${DEPLOY_VERSION},BRIK_DEPLOY_ENVIRONMENT=${ENVIRONMENT}")"
if [[ -z "$BUILD_NUM" ]]; then
    log_error "failed to trigger the CD build"
    exit 1
fi
log_ok "CD build #${BUILD_NUM} triggered"
RESULT="$(e2e.jenkins.wait_build "$CD_JOB" "$BUILD_NUM" "$TIMEOUT_SECONDS")" || true
echo ""
if [[ "$RESULT" != "SUCCESS" ]]; then
    log_error "CD build did not succeed (result: ${RESULT})"
    e2e.jenkins.get_console_log "$CD_JOB" "$BUILD_NUM" 2>/dev/null | tail -30 || true
    exit 1
fi
log_ok "CD build succeeded"

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
        log_ok "deployed image is digest-pinned -- Jenkins CD channel keystone PASSED"
        ;;
    *)
        log_error "deployed image is NOT digest-pinned: ${DEPLOYED_IMAGE:-<empty>}"
        exit 1
        ;;
esac
