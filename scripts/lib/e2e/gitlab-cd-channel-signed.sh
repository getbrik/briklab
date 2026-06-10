#!/usr/bin/env bash
# E2E GitLab signed CD keystone -- GitLab callbacks for lib/cd-channel.sh.
#
# Same CI -> CD shape as gitlab-cd-channel.sh, but the project signs the
# published digest (cosign attestation + BuildEvidence in the evidence-signed
# state-repo) and the staging environment gates on require_provenance, so the
# deploy verifies the signature before deploying. Deploys to the brik-e2e-signed
# ArgoCD app.
#
# Key handling (air-gapped local key, see scripts/lib/setup/gitlab.sh):
#   CI signs with the private key (referential Signing endpoint,
#   env://COSIGN_PRIVATE_KEY); the CD verify uses trust/cosign.pub so the
#   deploy verifies with the public key (GitLab CE cannot scope one var key per
#   environment, so the trigger variable does the switch).
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
reload_env
briklab.auth.gitlab_pat

TIMEOUT_SECONDS="${E2E_TIMEOUT:-900}"
PROJECT_PATH="brik%2Fnode-deploy-signed"
PROJECT_NAME="brik/node-deploy-signed"
SEED_TAG="v0.1.0"
DEPLOY_VERSION="0.1.0"
ENVIRONMENT="staging"
APP="brik-e2e-signed"

log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID="$(e2e.gitlab.get_project_id "$PROJECT_PATH")"
if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found (was it pushed?)"
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# CI seed: no CD inputs -> brik-integrate.yml. Package publishes to the release
# channel; container-scan signs the digest and records BuildEvidence.
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

# CD: both CD inputs set -> brik-deploy.yml. The provenance gate verifies the
# signature on the resolved digest with the referential's verification key
# (trust/cosign.pub) before deploying.
_cd_channel_deploy() {
    local version="$1" environment="$2" id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" \
        "BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment}")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CD pipeline"
        return 1
    fi
    log_ok "CD pipeline #${id} triggered"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CD status: ${st}"; return 1; }
}

e2e.cd_channel.run "gitlab" "$APP" "$ENVIRONMENT" "$DEPLOY_VERSION" "$TIMEOUT_SECONDS"
