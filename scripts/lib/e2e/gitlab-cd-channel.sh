#!/usr/bin/env bash
# E2E GitLab CD channel keystone -- GitLab callbacks for lib/cd-channel.sh.
#
# Deploys to staging (ArgoCD app brik-e2e-cd). The shared flow lives in
# e2e.cd_channel.run; this file only wires the GitLab-specific CI/CD triggers.
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
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
# shellcheck source=lib/reset.sh
source "${SCRIPT_DIR}/lib/reset.sh"
# shellcheck source=lib/cd-channel.sh
source "${SCRIPT_DIR}/lib/cd-channel.sh"
reload_env
briklab.auth.gitlab_pat

TIMEOUT_SECONDS="${E2E_TIMEOUT:-900}"
PROJECT_PATH="brik%2Fnode-deploy-channel"
PROJECT_NAME="brik/node-deploy-channel"
SEED_TAG="v0.1.0"
# Package tags the image with the release version without the leading "v"
# (cf. assert.image_tag); brik deploy resolves that version, so DEPLOY_VERSION
# drops the "v".
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

e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# The scenario owns its state-repo: each project push re-mints the commit
# while the reproducible image keeps the SAME digest, so a stale evidence
# record would conflict (another commit claiming the digest) and stale
# validated_for grants would defeat the chain-refusal phase. Start from a
# clean journal (the reset drops and restores the branch-protection rule
# around its baseline force-push).
e2e.reset.gitops_config_repo "gitea" "evidence-cd" || {
    log_error "cannot reset the evidence-cd state-repo"
    exit 1
}

# CI seed: no CD inputs -> include:rules selects brik-integrate.yml, which
# publishes the image to the release channel.
_cd_channel_seed_ci() {
    local id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$SEED_TAG" "BRIK_WITH_PACKAGE=true")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CI seed pipeline"
        return 1
    fi
    log_ok "CI pipeline #${id} triggered"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CI seed status: ${st}"; return 1; }
}

# CD: both CD inputs set -> include:rules selects brik-deploy.yml.
# Records the pipeline id in _CD_LAST_PIPELINE_ID so the chain phase can
# assert the producer trace of the staging run.
_CD_LAST_PIPELINE_ID=""
_cd_channel_deploy() {
    local version="$1" environment="$2" id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" \
        "BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment}")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CD pipeline"
        return 1
    fi
    log_ok "CD pipeline #${id} triggered"
    _CD_LAST_PIPELINE_ID="$id"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CD status: ${st}"; return 1; }
}

# _cd_deploy_trace <pipeline_id> - echo the brik-cd-deploy job trace.
_cd_deploy_trace() {
    local pipeline_id="$1" jobs job_id
    jobs="$(e2e.gitlab.get_jobs "$PROJECT_ID" "$pipeline_id")"
    job_id="$(echo "$jobs" | jq -r '[.[] | select(.name == "brik-cd-deploy")][0].id // empty')"
    if [[ -z "$job_id" ]]; then
        log_error "job brik-cd-deploy not found in pipeline #${pipeline_id}"
        return 1
    fi
    e2e.gitlab.get_job_log "$PROJECT_ID" "$job_id"
}

# _trigger_cd_expect_failure - trigger a CD pipeline that MUST fail, and the
# brik-cd-deploy trace MUST carry <pattern> (true-positive: the right gate
# refused, not an unrelated crash).
_trigger_cd_expect_failure() {
    local version="$1" environment="$2" pattern="$3" id st
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" \
        "BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment}")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CD pipeline"
        return 1
    fi
    log_ok "CD pipeline #${id} triggered (expected to be refused)"
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    if [[ "$st" != "failed" ]]; then
        log_error "CD status: ${st} (expected failed -- the gate must refuse)"
        return 1
    fi
    local trace
    trace="$(_cd_deploy_trace "$id")" || return 1
    if ! grep -q "$pattern" <<< "$trace"; then
        log_error "brik-cd-deploy trace does not show '${pattern}' -- wrong refusal"
        return 1
    fi
    log_ok "deploy refused with '${pattern}'"
}

# _cd_channel_pre_deploy - chain negative: production is gated on
# requires_eligibility [artifact_validated_for] and nothing validated the
# fresh digest yet (the CI seed re-mints a digest, so grants from previous
# runs cannot replay), so the CD deploy to production MUST be refused.
_cd_channel_pre_deploy() {
    log_info "--- Chain: production must be refused before the staging validation ---"
    _trigger_cd_expect_failure "$DEPLOY_VERSION" "production" "refusing to deploy"
}

e2e.cd_channel.run "gitlab" "$APP" "$ENVIRONMENT" "$DEPLOY_VERSION" "$TIMEOUT_SECONDS"

# --- Promotion chain (validates_for): staging validated the artifact for ---
# --- production; the eligibility gate must now let the same digest through. -
echo ""
log_info "=== Chain phase: staging -> production (validates_for producer) ==="

log_info "--- Chain: staging trace shows the journaled validation ---"
STAGING_TRACE="$(_cd_deploy_trace "$_CD_LAST_PIPELINE_ID")"
if ! grep -q "journaled artifact_validated_for" <<< "$STAGING_TRACE"; then
    log_error "staging brik-cd-deploy trace does not show 'journaled artifact_validated_for'"
    exit 1
fi
log_ok "staging journaled the validation for production"

STAGING_IMAGE="$(e2e.argocd.get_app_image "$APP")"
STAGING_DIGEST="${STAGING_IMAGE#*@}"

log_info "--- Chain: the journal carries the digest-bound grant ---"
JOURNAL_TMP="$(mktemp -d)"
JOURNAL_DIR="${JOURNAL_TMP}/evidence-cd"
if ! e2e.git.clone \
        "https://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}/brik/evidence-cd.git" \
        "$JOURNAL_DIR" "${GITEA_ADMIN_USER:-brik}" "$GITEA_PAT"; then
    rm -rf "$JOURNAL_TMP"
    log_error "cannot clone the evidence-cd state-repo"
    exit 1
fi
GRANT_COUNT="$( (find "$JOURNAL_DIR/promotions" -type f -name '*.json' -exec cat {} + 2>/dev/null || true) \
    | jq -s --arg d "$STAGING_DIGEST" \
    '[.[] | select(.type == "artifact_validated_for"
                   and .environment == "production"
                   and .digest == $d)] | length')"
rm -rf "$JOURNAL_TMP"
if [[ -z "$GRANT_COUNT" || "$GRANT_COUNT" -lt 1 ]]; then
    log_error "no artifact_validated_for(production) event bound to ${STAGING_DIGEST} in the journal"
    exit 1
fi
log_ok "journal carries artifact_validated_for(production) bound to ${STAGING_DIGEST}"

log_info "--- Chain: CD deploy ${DEPLOY_VERSION} -> production ---"
if ! _cd_channel_deploy "$DEPLOY_VERSION" "production"; then
    log_error "production CD deploy failed despite the validation grant"
    exit 1
fi

log_info "--- Chain: assert the production digest via ArgoCD (brik-e2e-cd-prod) ---"
if ! e2e.argocd.assert_synced "brik-e2e-cd-prod" "$TIMEOUT_SECONDS"; then
    log_error "ArgoCD app 'brik-e2e-cd-prod' did not reach Synced+Healthy"
    exit 1
fi
PROD_IMAGE="$(e2e.argocd.get_app_image "brik-e2e-cd-prod")"
log_info "production image: ${PROD_IMAGE:-<none>}"
if [[ "$PROD_IMAGE" != *"@${STAGING_DIGEST}" ]]; then
    log_error "production does not run the validated digest (staging=${STAGING_DIGEST} production=${PROD_IMAGE:-<empty>})"
    exit 1
fi
log_ok "=== GITLAB CD CHAIN PASSED (refused -> validated by staging -> deployed) ==="

# --- Independent Layer E (config_ref, A3): an env config change redeploys ---
# --- the SAME version; production keeps the definition frozen at the tag. ---
echo ""
log_info "=== Layer E phase: env config change redeploys without a new version (config_ref) ==="

GITLAB_REPO_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}/brik/node-deploy-channel.git"
GITEA_BASE_URL="https://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"

log_info "--- Layer E: push an env config change on main (no new version) ---"
LE_TMP="$(mktemp -d)"
APP_DIR="${LE_TMP}/node-deploy-channel"
if ! e2e.git.clone "$GITLAB_REPO_URL" "$APP_DIR" "root" "$GITLAB_PAT"; then
    rm -rf "$LE_TMP"
    log_error "cannot clone the app repo from GitLab"
    exit 1
fi
# Idempotent across re-runs: bump replicas from whatever main carries now.
LE_OLD_REPLICAS="$(grep -oE 'replicas: [0-9]+' "${APP_DIR}/k8s/deployment.yaml" | awk '{print $2}')"
LE_NEW_REPLICAS=$((LE_OLD_REPLICAS + 1))
sed -i.bak "s/replicas: ${LE_OLD_REPLICAS}/replicas: ${LE_NEW_REPLICAS}/" \
    "${APP_DIR}/k8s/deployment.yaml" && rm -f "${APP_DIR}/k8s/deployment.yaml.bak"
if ! e2e.git.commit "$APP_DIR" "chore: bump staging replicas to ${LE_NEW_REPLICAS} (env config change)"; then
    rm -rf "$LE_TMP"
    log_error "cannot commit the env config change"
    exit 1
fi
# ci.skip: this push must not fire a CI pipeline -- the point is precisely
# that NO new version is produced for the config change.
if ! e2e.git.push "$APP_DIR" "$GITLAB_REPO_URL" "root" "$GITLAB_PAT" "-o ci.skip"; then
    rm -rf "$LE_TMP"
    log_error "cannot push the env config change"
    exit 1
fi
rm -rf "$LE_TMP"
log_ok "main now carries replicas: ${LE_NEW_REPLICAS} (tag ${SEED_TAG} still carries ${LE_OLD_REPLICAS})"

log_info "--- Layer E: redeploy ${DEPLOY_VERSION} -> staging (same version, new config) ---"
if ! _cd_channel_deploy "$DEPLOY_VERSION" "staging"; then
    log_error "staging CD redeploy failed after the env config change"
    exit 1
fi

log_info "--- Layer E: the deploy resolved the env config at config_ref ---"
LE_TRACE="$(_cd_deploy_trace "$_CD_LAST_PIPELINE_ID")"
if ! grep -q "resolving environment config for 'staging' at main" <<< "$LE_TRACE"; then
    log_error "brik-cd-deploy trace does not show the Layer E resolution (config_ref)"
    exit 1
fi
log_ok "trace shows the env config resolved at main"

log_info "--- Layer E: config repo carries the new config pinned to the SAME digest ---"
LE_CFG_TMP="$(mktemp -d)"
if ! e2e.git.clone "${GITEA_BASE_URL}/brik/config-deploy-cd.git" \
        "${LE_CFG_TMP}/cfg" "${GITEA_ADMIN_USER:-brik}" "$GITEA_PAT"; then
    rm -rf "$LE_CFG_TMP"
    log_error "cannot clone config-deploy-cd"
    exit 1
fi
if ! grep -q "replicas: ${LE_NEW_REPLICAS}" "${LE_CFG_TMP}/cfg/k8s/deployment.yaml"; then
    rm -rf "$LE_CFG_TMP"
    log_error "config-deploy-cd does not carry replicas: ${LE_NEW_REPLICAS} (Layer E not applied)"
    exit 1
fi
if ! grep -q "@${STAGING_DIGEST}" "${LE_CFG_TMP}/cfg/k8s/deployment.yaml"; then
    rm -rf "$LE_CFG_TMP"
    log_error "config-deploy-cd is not pinned to the seeded digest ${STAGING_DIGEST} anymore"
    exit 1
fi
log_ok "staging intent: replicas ${LE_NEW_REPLICAS} @ unchanged digest ${STAGING_DIGEST}"

log_info "--- Layer E: production stays on the tag's definition (no config_ref) ---"
if ! e2e.git.clone "${GITEA_BASE_URL}/brik/config-deploy-cd-prod.git" \
        "${LE_CFG_TMP}/cfg-prod" "${GITEA_ADMIN_USER:-brik}" "$GITEA_PAT" \
    || ! grep -q "replicas: ${LE_OLD_REPLICAS}" "${LE_CFG_TMP}/cfg-prod/k8s/deployment.yaml"; then
    rm -rf "$LE_CFG_TMP"
    log_error "config-deploy-cd-prod no longer carries replicas: ${LE_OLD_REPLICAS} (Layer V leaked)"
    exit 1
fi
rm -rf "$LE_CFG_TMP"
log_ok "production intent untouched (replicas ${LE_OLD_REPLICAS})"

log_info "--- Layer E: ArgoCD reconciles staging to the new config ---"
if ! e2e.argocd.assert_synced "$APP" "$TIMEOUT_SECONDS"; then
    log_error "ArgoCD app '${APP}' did not reach Synced+Healthy after the Layer E redeploy"
    exit 1
fi
log_ok "=== GITLAB LAYER E PASSED (config change redeployed ${DEPLOY_VERSION} without a new version) ==="
