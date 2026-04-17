#!/usr/bin/env bash
# E2E Jenkins Rollback Test
#
# Tests GitOps rollback via a chain of real commits (Jenkins + Gitea + ArgoCD).
# Delegates the 3-step flow to lib/rollback.sh and provides Jenkins-specific callbacks.
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
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/rollback.sh
source "${SCRIPT_DIR}/lib/rollback.sh"
# shellcheck source=lib/jenkins-api.sh
source "${SCRIPT_DIR}/lib/jenkins-api.sh"
# shellcheck source=lib/gitea-api.sh
source "${SCRIPT_DIR}/lib/gitea-api.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
reload_env

GITEA_URL="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
TIMEOUT_SECONDS="${E2E_JENKINS_TIMEOUT:-300}"
JOB_NAME="node-deploy-gitops-rollback"
TEMPLATE_DIR="${PROJECT_ROOT}/test-projects/node-deploy-gitops-rollback"
GITEA_USER="${GITEA_ADMIN_USER:-brik}"

JENKINS_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"
if [[ -z "$JENKINS_PASSWORD" ]]; then
    log_error "JENKINS_ADMIN_PASSWORD is not set in .env"
    exit 1
fi

# Verify Jenkins is reachable and job exists
log_info "Checking Jenkins..."
if ! e2e.jenkins.api_get "api/json" &>/dev/null; then
    log_error "Jenkins is not reachable"
    exit 1
fi
log_ok "Jenkins is ready"

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

# ---------------------------------------------------------------------------
# Callbacks for rollback.sh
# ---------------------------------------------------------------------------

_rollback_push_v020() {
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

_rollback_trigger_deploy() {
    local tag="$1"

    # Wait briefly for Gitea webhook
    [[ "$tag" == "v0.2.0" ]] && sleep 5

    local build_number
    build_number=$(e2e.jenkins.trigger_build "$JOB_NAME") || {
        log_error "Failed to trigger ${tag} build"
        exit 1
    }
    log_ok "Build #${build_number} triggered for ${tag}"

    log_info "Waiting for ${tag} build..."
    local result
    result=$(e2e.jenkins.wait_build "$JOB_NAME" "$build_number" "$TIMEOUT_SECONDS") || true
    echo ""

    if [[ "$result" != "SUCCESS" ]]; then
        log_error "${tag} build did not succeed (result: ${result})"
        exit 1
    fi
    log_ok "${tag} build succeeded"
}

_rollback_cancel_auto_triggered() {
    # Jenkins builds triggered by Gitea webhook are handled by manual trigger
    true
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
e2e.rollback.run "jenkins" "$JOB_NAME" \
    "brik-e2e-rollback" "config-deploy-rollback" "$TEMPLATE_DIR" "$TIMEOUT_SECONDS"
