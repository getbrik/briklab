#!/usr/bin/env bash
# E2E Jenkins Pipeline Test
#
# Triggers a Jenkins pipeline build and waits for completion.
# Validates that the build succeeds and all stages are executed.
#
# Configuration (env vars):
#   E2E_JENKINS_JOB     - Job name (default: node-minimal)
#   E2E_JENKINS_TIMEOUT  - Timeout in seconds (default: 300)
#   E2E_JENKINS_EXPECT_FAILURE - Set to "true" to expect failure (default: false)
#   E2E_CI_VARIABLES     - Comma-separated KEY=VALUE pairs for build parameters (default: empty)
#   E2E_SKIP_LOG_CHECK   - Set to "true" to skip build log validation (default: false)
#
# Prerequisites:
#   - briklab Jenkins must be running
#   - Repos must be pushed to Gitea (gitea-push.sh)
#   - Job must exist (defined via CasC or seed job)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

# Source E2E libraries
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source=lib/jenkins-api.sh
source "${SCRIPT_DIR}/lib/jenkins-api.sh"
# shellcheck source=lib/nexus.sh
source "${SCRIPT_DIR}/lib/nexus.sh"

JOB_NAME="${E2E_JENKINS_JOB:-node-minimal}"
TIMEOUT_SECONDS="${E2E_JENKINS_TIMEOUT:-300}"
EXPECT_FAILURE="${E2E_JENKINS_EXPECT_FAILURE:-false}"
SKIP_LOG_CHECK="${E2E_SKIP_LOG_CHECK:-false}"

JENKINS_URL="http://${JENKINS_HOSTNAME:-jenkins.briklab.test}:${JENKINS_HTTP_PORT:-9090}"
JENKINS_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"

if [[ -z "$JENKINS_PASSWORD" ]]; then
    log_error "JENKINS_ADMIN_PASSWORD is not set in .env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik E2E Jenkins Pipeline Test ==="
log_info "Job: ${JOB_NAME}"
log_info "Timeout: ${TIMEOUT_SECONDS}s"
if [[ "$EXPECT_FAILURE" == "true" ]]; then
    log_warn "Mode: EXPECT FAILURE"
fi
echo ""

# Initialize assertion counters
assert.init

# 1. Verify Jenkins is reachable
log_info "Checking Jenkins..."
if ! e2e.jenkins.api_get "api/json" &>/dev/null; then
    log_error "Jenkins is not reachable at ${JENKINS_URL}"
    exit 1
fi
log_ok "Jenkins is ready"

# 2. Verify job exists (poll in case CasC/Job DSL has not finished seeding)
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
    log_error "Job '${JOB_NAME}' not found after 60s. Check CasC or seed job."
    exit 1
fi
log_ok "Job '${JOB_NAME}' found"

# 3. Determine trigger mode
TRIGGER_MODE="${E2E_TRIGGER_MODE:-api}"

if [[ "$TRIGGER_MODE" == "push" ]]; then
    # CI variables not supported in push mode -- fallback to API
    if [[ -n "${E2E_CI_VARIABLES:-}" ]]; then
        log_warn "Push mode + CI variables: falling back to API trigger"
        TRIGGER_MODE="api"
    fi
fi

if [[ "$TRIGGER_MODE" == "push" ]]; then
    # Push-driven trigger
    # shellcheck source=lib/git.sh
    source "${SCRIPT_DIR}/lib/git.sh"

    log_info "Triggering via git push (ref: main)..."
    PUSH_SHA=$(e2e.git.trigger_via_push "gitea" "$JOB_NAME" "main")
    log_ok "Push SHA: ${PUSH_SHA}"

    log_info "Waiting for build triggered by SHA ${PUSH_SHA:0:8}..."
    BUILD_NUMBER=$(e2e.jenkins.wait_build_by_sha "$JOB_NAME" "$PUSH_SHA" 90 "$TIMEOUT_SECONDS")

    BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}"
    FINAL_RESULT=$(e2e.jenkins.get_build_result "$JOB_NAME" "$BUILD_NUMBER")
else
    # API trigger (default, unchanged)
    log_info "Triggering build..."
    if [[ -n "${E2E_CI_VARIABLES:-}" ]]; then
        log_info "CI variables: ${E2E_CI_VARIABLES}"
    fi

    BUILD_NUMBER=$(e2e.jenkins.trigger_build "$JOB_NAME" "${E2E_CI_VARIABLES:-}") || {
        log_error "Failed to trigger build"
        exit 1
    }

    BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}"
    log_ok "Build #${BUILD_NUMBER} started"
    echo "  URL: ${BUILD_URL}"
    echo ""

    log_info "Waiting for build completion (timeout: ${TIMEOUT_SECONDS}s)..."
    FINAL_RESULT=$(e2e.jenkins.wait_build "$JOB_NAME" "$BUILD_NUMBER" "$TIMEOUT_SECONDS") || true
fi
echo ""

if [[ -z "$FINAL_RESULT" || "$FINAL_RESULT" == "TIMEOUT" ]]; then
    log_error "Build timed out after ${TIMEOUT_SECONDS}s"
    exit 1
fi

log_ok "Build #${BUILD_NUMBER}: ${FINAL_RESULT}"
echo "  URL: ${BUILD_URL}"
echo ""

# 5. Show stage information (via wfapi if available)
STAGES_JSON=$(e2e.jenkins.get_stages "$JOB_NAME" "$BUILD_NUMBER")
if [[ -n "$STAGES_JSON" ]]; then
    echo "  Stages:"
    echo "$STAGES_JSON" | jq -r '
        .stages[]? |
        "\(if .status == "SUCCESS" then "  [v]" elif .status == "FAILED" then "  [x]" else "  [?]" end) \(.name): \(.status) (\(.durationMillis / 1000 | floor)s)"
    ' 2>/dev/null || echo "  (could not parse stage details)"
    echo ""
fi

# 6. Assert build result
if [[ "$EXPECT_FAILURE" == "true" ]]; then
    assert.build_failed "$FINAL_RESULT"
else
    assert.build_succeeded "$FINAL_RESULT"
fi

# 7. Validate build logs (only for successful builds)
if [[ "$EXPECT_FAILURE" != "true" && "$SKIP_LOG_CHECK" != "true" ]]; then
    log_info "Checking build logs for errors..."
    CONSOLE_LOG=$(e2e.jenkins.get_console_log "$JOB_NAME" "$BUILD_NUMBER")
    if [[ -n "$CONSOLE_LOG" ]]; then
        assert.build_logs_clean "$CONSOLE_LOG"
    fi
fi

echo ""

# 8. Report assertions
if assert.report; then
    log_ok "=== E2E JENKINS TEST PASSED ==="
    exit 0
else
    # Show console output tail for debugging
    log_info "Last 30 lines of console output:"
    e2e.jenkins.get_console_log "$JOB_NAME" "$BUILD_NUMBER" | tail -30 || true
    echo ""
    log_error "=== E2E JENKINS TEST FAILED ==="
    exit 1
fi
