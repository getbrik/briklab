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
#   E2E_EXPECTED_ERROR_PATTERN - Regex pattern expected in the console log (for error scenarios)
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

JOB_NAME="${E2E_JENKINS_JOB:-node-full}"
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
if ! e2e.jenkins.wait_job_exists "$JOB_NAME" 60; then
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

    # Honor the suite-provided trigger ref so workflow-trunk-tag pushes
    # v0.2.0 (Multibranch tag-scan -> release context) and
    # workflow-trunk-feature pushes a feature branch -- mirroring GitLab.
    # Defaulting to "main" preserves behavior for callers that don't set
    # E2E_TRIGGER_REF.
    TRIGGER_REF="${E2E_TRIGGER_REF:-main}"

    # Multibranch routes tag-scan builds under /job/<job>/job/<tag>/...
    # and feature-branch builds under /job/<job>/job/<branch>/. Override
    # E2E_JENKINS_BRANCH so the wait/api helpers query the right URL.
    # Slashes in branch names (e.g. feature/test) must be URL-encoded as
    # %2F or Jenkins parses them as nested folders.
    case "$TRIGGER_REF" in
        v[0-9]*)  export E2E_JENKINS_BRANCH="$TRIGGER_REF" ;;
        branch:*)
            _branch_name="${TRIGGER_REF#branch:}"
            export E2E_JENKINS_BRANCH="${_branch_name//\//%2F}"
            ;;
    esac

    log_info "Triggering via git push (ref: ${TRIGGER_REF})..."
    PUSH_SHA=$(e2e.git.trigger_via_push "gitea" "$JOB_NAME" "$TRIGGER_REF")
    log_ok "Push SHA: ${PUSH_SHA}"

    # Multibranch + giteaTagDiscovery() indexes new tags but does not
    # auto-trigger a build for them (only new branch commits trigger
    # automatically). Wait for the tag sub-job to appear, then issue an
    # explicit /build so the harness can observe the build it expects.
    # Mirrors GitLab where pushing a tag immediately runs a pipeline.
    if [[ "$TRIGGER_REF" =~ ^v[0-9] ]]; then
        log_info "Waiting for Multibranch to discover tag ${TRIGGER_REF}..."
        _tag_path="job/${JOB_NAME}/job/${TRIGGER_REF}"
        _discover=0
        while [[ $_discover -lt 60 ]]; do
            if e2e.jenkins.api_get "${_tag_path}/api/json" 2>/dev/null | jq -e '.name' >/dev/null 2>&1; then
                break
            fi
            sleep 5
            _discover=$((_discover + 5))
        done
        if [[ $_discover -ge 60 ]]; then
            log_warn "Tag sub-job did not appear within 60s; proceeding with wait anyway"
        else
            # Delegate to trigger_build, which already handles the
            # crumb+cookie session correctly. E2E_JENKINS_BRANCH is set
            # above so _e2e_jenkins_job_path routes to the tag sub-job.
            log_info "Triggering build on tag sub-job..."
            e2e.jenkins.trigger_build "$JOB_NAME" >/dev/null 2>&1 || \
                log_warn "Failed to trigger tag sub-job build (will rely on Multibranch auto-scan)"
        fi
    fi

    log_info "Waiting for build triggered by SHA ${PUSH_SHA:0:8}..."
    BUILD_NUMBER=$(e2e.jenkins.wait_build_by_sha "$JOB_NAME" "$PUSH_SHA" "${E2E_JENKINS_DISCOVER_TIMEOUT:-90}" "$TIMEOUT_SECONDS")

    # Multibranch sub-jobs live under /job/<job>/job/<branch_or_tag>/<n>.
    # Include the sub-job segment when E2E_JENKINS_BRANCH is set so log
    # readers (and the parity helper) reach the right artifacts URL.
    if [[ -n "${E2E_JENKINS_BRANCH:-}" ]]; then
        BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/job/${E2E_JENKINS_BRANCH}/${BUILD_NUMBER}"
    else
        BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}"
    fi
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

    # Multibranch sub-jobs live under /job/<job>/job/<branch_or_tag>/<n>.
    # Include the sub-job segment when E2E_JENKINS_BRANCH is set so log
    # readers (and the parity helper) reach the right artifacts URL.
    if [[ -n "${E2E_JENKINS_BRANCH:-}" ]]; then
        BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/job/${E2E_JENKINS_BRANCH}/${BUILD_NUMBER}"
    else
        BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}"
    fi
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

    # Validate error pattern in the console log
    if [[ -n "${E2E_EXPECTED_ERROR_PATTERN:-}" ]]; then
        CONSOLE_LOG=$(e2e.jenkins.get_console_log "$JOB_NAME" "$BUILD_NUMBER")
        assert.build_log_contains "$CONSOLE_LOG" "$E2E_EXPECTED_ERROR_PATTERN"
    fi
else
    assert.build_succeeded "$FINAL_RESULT"
fi

# 7. Validate build logs (only for successful builds)
# Skip log-clean assertion entirely when the build already FAILED: the
# build-result assertion above has caught the failure, and Jenkins's
# console flush has variable latency past 2s, so a "Build logs clean"
# PASS on a failed build would be a misleading false positive that
# masks the real failure.
if [[ "$EXPECT_FAILURE" != "true" && "$SKIP_LOG_CHECK" != "true" && "$FINAL_RESULT" != "FAILURE" ]]; then
    log_info "Checking build logs for errors..."
    # Small settle delay so Jenkins has time to flush the console tail
    # before we fetch it; otherwise final [ERROR] lines can be missing.
    sleep 2
    CONSOLE_LOG=$(e2e.jenkins.get_console_log "$JOB_NAME" "$BUILD_NUMBER")
    if [[ -n "$CONSOLE_LOG" ]]; then
        assert.build_logs_clean "$CONSOLE_LOG"
    fi
fi

echo ""

# 8. Validate the aggregate-report.json aggregate produced by the notify
# stage. Only run on successful builds: a failed build may not have
# reached notify or archived the aggregate.
if [[ "$EXPECT_FAILURE" != "true" && "$SKIP_LOG_CHECK" != "true" && "$FINAL_RESULT" == "SUCCESS" ]]; then
    log_info "Validating aggregate-report.json aggregate (build #${BUILD_NUMBER})..."
    AGG_TMP="$(mktemp -d)"
    AGG_FILE="${AGG_TMP}/aggregate-report.json"
    if e2e.jenkins.download_artifact "$JOB_NAME" "$BUILD_NUMBER" \
            "brik-artifacts/aggregate-report.json" "$AGG_FILE" 2>/dev/null; then
        assert.aggregate_v1 "$AGG_FILE" "jenkins"
        # On tag scenarios (E2E_TRIGGER_REF=v<N>...), assert the package
        # image tag mirrors the release version. Parity counterpart to the
        # GitLab assertion -- both platforms must produce the same tag on
        # the same release commit.
        _trigger_ref="${E2E_TRIGGER_REF:-main}"
        if [[ "$_trigger_ref" =~ ^v[0-9] ]]; then
            assert.image_tag "$AGG_FILE" "${_trigger_ref#v}"
        fi
        # Opt-in: assert the promote stage really ran a candidate->release
        # retag in THIS build's report (run-specific, stale-proof). Parity
        # with the GitLab suite.
        if [[ "${E2E_ASSERT_PROMOTE:-false}" == "true" ]]; then
            assert.promote_succeeded "$AGG_FILE"
        fi
    else
        log_warn "could not download aggregate-report.json from build (skipping aggregate assertions)"
    fi
    rm -rf "$AGG_TMP"
    echo ""
fi

# 9. Report assertions
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
