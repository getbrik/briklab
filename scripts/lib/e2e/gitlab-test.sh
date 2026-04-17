#!/usr/bin/env bash
# E2E Pipeline Test
#
# Triggers a pipeline on a Brik test project and waits for completion.
# Validates that required and optional jobs reach expected statuses.
#
# Configuration (env vars with backward-compatible defaults):
#   E2E_PROJECT_PATH    - URL-encoded GitLab project path (default: brik%2Fnode-minimal)
#   E2E_REQUIRED_JOBS   - Comma-separated jobs that must succeed (default: brik-init,brik-build,brik-test)
#   E2E_OPTIONAL_JOBS   - Comma-separated jobs checked but not blocking (default: empty)
#   E2E_TRIGGER_REF     - Git ref to trigger pipeline on (default: main)
#   E2E_TIMEOUT          - Pipeline timeout in seconds (default: 300)
#   E2E_EXPECT_FAILURE   - Set to "true" to expect the pipeline to fail (default: false)
#   E2E_EXPECT_FAILED_JOB - Job name that must have "failed" status (used with E2E_EXPECT_FAILURE)
#   E2E_CI_VARIABLES     - Comma-separated KEY=VALUE pairs to pass as pipeline variables (default: empty)
#   E2E_SKIP_LOG_CHECK   - Set to "true" to skip job log validation (default: false)
#
# Prerequisites:
#   - briklab GitLab must be running
#   - gitlab-push.sh must have been run
#   - GITLAB_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
reload_env

# Source E2E libraries
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/nexus.sh
source "${SCRIPT_DIR}/lib/nexus.sh"

# Ensure PAT is valid (refresh if expired/missing)
ensure_gitlab_pat

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PAT="${GITLAB_PAT:-}"
PROJECT_PATH="${E2E_PROJECT_PATH:-brik%2Fnode-minimal}"
TRIGGER_REF="${E2E_TRIGGER_REF:-main}"
TIMEOUT_SECONDS="${E2E_TIMEOUT:-300}"
EXPECT_FAILURE="${E2E_EXPECT_FAILURE:-false}"
EXPECT_FAILED_JOB="${E2E_EXPECT_FAILED_JOB:-}"
SKIP_LOG_CHECK="${E2E_SKIP_LOG_CHECK:-false}"

# Parse comma-separated job lists into arrays
IFS=',' read -ra REQUIRED_JOBS <<< "${E2E_REQUIRED_JOBS:-brik-init,brik-build,brik-test}"
if [[ -n "${E2E_OPTIONAL_JOBS:-}" ]]; then
    IFS=',' read -ra OPTIONAL_JOBS <<< "$E2E_OPTIONAL_JOBS"
else
    OPTIONAL_JOBS=()
fi

# Derive human-readable project name from path
PROJECT_NAME="${PROJECT_PATH//%2F//}"

if [[ -z "$GITLAB_PAT" ]]; then
    log_error "GITLAB_PAT is not set. Run setup-gitlab.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik E2E Pipeline Test ==="
log_info "Project: ${PROJECT_NAME}"
log_info "Ref: ${TRIGGER_REF}"
log_info "Required jobs: ${REQUIRED_JOBS[*]}"
if [[ ${#OPTIONAL_JOBS[@]} -gt 0 && -n "${OPTIONAL_JOBS[0]}" ]]; then
    log_info "Optional jobs: ${OPTIONAL_JOBS[*]}"
fi
if [[ "$EXPECT_FAILURE" == "true" ]]; then
    log_warn "Mode: EXPECT FAILURE (pipeline should fail)"
    [[ -n "$EXPECT_FAILED_JOB" ]] && log_warn "Expected failed job: ${EXPECT_FAILED_JOB}"
fi
echo ""

# Initialize assertion counters
assert.init

# 1. Get project ID
log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID=$(e2e.gitlab.get_project_id "$PROJECT_PATH")

if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found. Run gitlab-push.sh first."
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

# 2. Cancel any running/pending pipelines to free the runner queue
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

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

    PROJECT_SHORT="${PROJECT_NAME#brik/}"

    log_info "Triggering via git push (ref: ${TRIGGER_REF})..."
    PUSH_SHA=$(e2e.git.trigger_via_push "gitlab" "$PROJECT_SHORT" "$TRIGGER_REF")
    log_ok "Push SHA: ${PUSH_SHA}"

    log_info "Waiting for pipeline triggered by SHA ${PUSH_SHA:0:8}..."
    PIPELINE_RESULT=$(e2e.gitlab.wait_pipeline_by_sha "$PROJECT_ID" "$PUSH_SHA" 60 "$TIMEOUT_SECONDS")
    PIPELINE_ID=$(echo "$PIPELINE_RESULT" | cut -d' ' -f1)
    FINAL_STATUS=$(echo "$PIPELINE_RESULT" | cut -d' ' -f2)
else
    # API trigger (default, unchanged)
    log_info "Triggering pipeline on ref '${TRIGGER_REF}'..."
    if [[ -n "${E2E_CI_VARIABLES:-}" ]]; then
        log_info "CI variables: ${E2E_CI_VARIABLES}"
    fi
    PIPELINE_ID=$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$TRIGGER_REF" "${E2E_CI_VARIABLES:-}")

    if [[ -z "$PIPELINE_ID" ]]; then
        log_error "Failed to trigger pipeline"
        exit 1
    fi
    log_ok "Pipeline triggered: #${PIPELINE_ID}"
    echo "  URL: ${GITLAB_URL}/${PROJECT_NAME}/-/pipelines/${PIPELINE_ID}"
    echo ""

    log_info "Waiting for pipeline completion (timeout: ${TIMEOUT_SECONDS}s)..."
    FINAL_STATUS=$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$PIPELINE_ID" "$TIMEOUT_SECONDS") || true
fi
echo ""

if [[ -z "$PIPELINE_ID" || -z "$FINAL_STATUS" || "$FINAL_STATUS" == "timeout" ]]; then
    log_error "Pipeline timed out or failed to trigger"
    exit 1
fi
log_ok "Pipeline #${PIPELINE_ID} finished: ${FINAL_STATUS}"
echo "  URL: ${GITLAB_URL}/${PROJECT_NAME}/-/pipelines/${PIPELINE_ID}"

# 5. Get job details
log_info "Pipeline status: ${FINAL_STATUS}"
echo ""

JOBS=$(e2e.gitlab.get_jobs "$PROJECT_ID" "$PIPELINE_ID")

echo "  Jobs:"
echo "$JOBS" | jq -r '
    sort_by(.id)[] |
    "\(if .status == "success" then "  [v]" elif .status == "failed" then "  [x]" else "  [?]" end) [\(.stage)] \(.name): \(.status)"
' 2>/dev/null || echo "  (could not parse job details)"

echo ""

# 6. Assert pipeline status
if [[ "$EXPECT_FAILURE" == "true" ]]; then
    assert.pipeline_failed "$FINAL_STATUS"
else
    assert.pipeline_succeeded "$FINAL_STATUS"
fi

# 7. Check required jobs
for job_name in "${REQUIRED_JOBS[@]}"; do
    job_name="$(echo "$job_name" | tr -d '[:space:]')"
    [[ -z "$job_name" ]] && continue

    if [[ "$EXPECT_FAILURE" == "true" ]]; then
        # In expect-failure mode, required jobs may not all succeed
        JOB_STATUS=$(e2e.gitlab.get_job_status "$JOBS" "$job_name")
        if [[ "$JOB_STATUS" == "success" ]]; then
            log_ok "${job_name}: PASSED"
        else
            log_info "${job_name}: ${JOB_STATUS} (expected in failure mode)"
        fi
    else
        assert.job_status "$JOBS" "$job_name" "success"
    fi
done

# 8. Check expected failed job
if [[ "$EXPECT_FAILURE" == "true" && -n "$EXPECT_FAILED_JOB" ]]; then
    assert.job_status "$JOBS" "$EXPECT_FAILED_JOB" "failed"
fi

# 9. Check optional jobs (warn only, do not assert)
for job_name in "${OPTIONAL_JOBS[@]}"; do
    job_name="$(echo "$job_name" | tr -d '[:space:]')"
    [[ -z "$job_name" ]] && continue

    JOB_STATUS=$(e2e.gitlab.get_job_status "$JOBS" "$job_name")

    case "$JOB_STATUS" in
        success)
            log_ok "${job_name}: PASSED (optional)"
            ;;
        skipped|manual|created)
            log_info "${job_name}: ${JOB_STATUS} (optional, acceptable)"
            ;;
        failed)
            log_warn "${job_name}: FAILED (optional, allow_failure)"
            ;;
        *)
            log_warn "${job_name}: ${JOB_STATUS} (optional)"
            ;;
    esac
done

# 10. Validate job logs (only for successful pipelines)
if [[ "$EXPECT_FAILURE" != "true" && "$SKIP_LOG_CHECK" != "true" ]]; then
    echo ""
    log_info "Checking job logs for errors..."
    while IFS=: read -r jid jname; do
        [[ -z "$jid" ]] && continue
        local_log=$(e2e.gitlab.get_job_log "$PROJECT_ID" "$jid")
        if [[ -n "$local_log" ]]; then
            assert.job_logs_clean "$local_log" "Logs clean: ${jname}"
        fi
    done < <(echo "$JOBS" | jq -r '.[] | "\(.id):\(.name)"' 2>/dev/null)
fi

echo ""

# 11. Report assertions
if assert.report; then
    log_ok "=== E2E TEST PASSED ==="
    exit 0
else
    log_error "=== E2E TEST FAILED ==="
    exit 1
fi
