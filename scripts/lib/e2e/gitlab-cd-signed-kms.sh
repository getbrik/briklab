#!/usr/bin/env bash
# E2E GitLab signed CD keystone, KMS variant -- the same CI -> CD flow as
# gitlab-cd-channel-signed.sh on the same project, but every pipeline runs
# against the infra-kms referential instance: the Signing endpoint declares
# backend kms (cosign openbao://brik-signing), so the CI signature and the
# CD require_attestation verification both go through the lab OpenBAO
# Transit engine instead of a file key. The signing key never enters the
# job environment.
#
# Trigger-time selection (GitLab CE cannot scope variables per instance):
#   BRIK_INFRA_DIR=/etc/brik/infra-kms  - the runner mounts both instances
#   BRIK_BAO_TOKEN=<dev root token>     - resolved by the SecretManager
#                                         endpoint's env:// credential ref
#
# True-positive guards: the scenario fails if the traces do not show the
# kms backend doing the work ('attesting ... [kms]' in the CI signing job,
# 'verifying ... [kms]' in the CD deploy job), so a silent fallback to
# another backend cannot pass.
#
# Configuration (env vars):
#   E2E_TIMEOUT - per-pipeline timeout in seconds (default: 900)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/cd-channel.sh
source "${SCRIPT_DIR}/lib/cd-channel.sh"
# shellcheck source=lib/reset.sh
source "${SCRIPT_DIR}/lib/reset.sh"
reload_env
briklab.auth.gitlab_pat

TIMEOUT_SECONDS="${E2E_TIMEOUT:-900}"
PROJECT_PATH="brik%2Fnode-deploy-signed"
PROJECT_NAME="brik/node-deploy-signed"
SEED_TAG="v0.1.0"
DEPLOY_VERSION="0.1.0"
ENVIRONMENT="staging"
APP="brik-e2e-signed"

# The dev-mode root token doubles as the job credential (P-lab posture).
KMS_VARS="BRIK_INFRA_DIR=/etc/brik/infra-kms,BRIK_BAO_TOKEN=${OPENBAO_ROOT_TOKEN:-brik-bao-root-2026}"

log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID="$(e2e.gitlab.get_project_id "$PROJECT_PATH")"
if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found (was it pushed?)"
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# Append-only evidence store: force-push a clean baseline so the (version,
# digest) events of a previous signed run cannot collide with this one.
e2e.reset.gitops_config_repo "gitea" "evidence-signed"

# _assert_kms_trace - fail unless <job>'s trace of <pipeline> shows the kms
# backend doing <verb> (attesting | verifying).
_assert_kms_trace() {
    local pipeline_id="$1" job_name="$2" verb="$3"
    local jobs job_id trace
    jobs="$(e2e.gitlab.get_jobs "$PROJECT_ID" "$pipeline_id")"
    job_id="$(echo "$jobs" | jq -r --arg n "$job_name" '[.[] | select(.name == $n)][0].id // empty')"
    if [[ -z "$job_id" ]]; then
        log_error "job ${job_name} not found in pipeline #${pipeline_id}"
        return 1
    fi
    trace="$(e2e.gitlab.get_job_log "$PROJECT_ID" "$job_id")"
    if ! grep -Eq "${verb} .*\[kms\]" <<< "$trace"; then
        log_error "${job_name} trace does not show '${verb} ... [kms]' - the kms backend did not do the work"
        return 1
    fi
    log_ok "${job_name}: ${verb} through the kms backend"
}

# CI seed: no CD inputs -> brik-integrate.yml. Package publishes the image;
# container-scan attests the digest through openbao:// and records the
# BuildEvidence in the evidence-signed state-repo.
_cd_channel_seed_ci() {
    local id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$SEED_TAG" \
        "BRIK_WITH_PACKAGE=true,${KMS_VARS}")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CI seed pipeline"
        return 1
    fi
    log_ok "CI pipeline #${id} triggered (infra-kms instance)"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CI seed status: ${st}"; return 1; }
    _assert_kms_trace "$id" "brik-container-scan" "attesting"
}

# CD: both CD inputs set -> brik-deploy.yml. require_attestation verifies the
# attestation on the resolved digest through the same openbao:// reference.
_cd_channel_deploy() {
    local version="$1" environment="$2" id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" \
        "BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment},${KMS_VARS}")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CD pipeline"
        return 1
    fi
    log_ok "CD pipeline #${id} triggered (infra-kms instance)"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CD status: ${st}"; return 1; }
    _assert_kms_trace "$id" "brik-cd-deploy" "verifying"
}

# Eligibility: the kms seed produced a fresh digest, so the journal must be
# granted again before the CD deploy (the grant is digest-bound). The host
# authorize goes through the main P-lab instance: the journal and its ssh
# signing are backend-agnostic, only the artifact signing differs in kms.
_cd_channel_pre_deploy() {
    local version="$1" environment="$2"
    log_info "--- Eligibility: brik authorize ${version} --for ${environment} (kms digest) ---"
    local brik_bin="${BRIKLAB_ROOT}/../brik/bin/brik"
    local project_dir="${BRIKLAB_ROOT}/test-projects/node-deploy-signed"
    local log_dir
    log_dir="$(mktemp -d)"
    if ! BRIK_INFRA_DIR="${BRIKLAB_ROOT}/data/infra" BRIK_LOG_DIR="$log_dir" \
            "$brik_bin" authorize --version "$version" --for "$environment" \
            --workspace "$project_dir"; then
        rm -rf "$log_dir"
        log_error "brik authorize failed"
        return 1
    fi
    rm -rf "$log_dir"
    log_ok "authorization granted (artifact_authorized_for in the journal)"
}

e2e.cd_channel.run "gitlab" "$APP" "$ENVIRONMENT" "$DEPLOY_VERSION" "$TIMEOUT_SECONDS"
