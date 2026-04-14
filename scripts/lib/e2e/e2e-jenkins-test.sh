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
#
# Prerequisites:
#   - briklab Jenkins must be running
#   - Repos must be pushed to Gitea (push-test-project-gitea.sh)
#   - Job must exist (defined via CasC or seed job)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

JENKINS_URL="http://${JENKINS_HOSTNAME:-jenkins.briklab.test}:${JENKINS_HTTP_PORT:-9090}"
JENKINS_USER="admin"
JENKINS_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"
JOB_NAME="${E2E_JENKINS_JOB:-node-minimal}"
TIMEOUT_SECONDS="${E2E_JENKINS_TIMEOUT:-300}"
POLL_INTERVAL=10
EXPECT_FAILURE="${E2E_JENKINS_EXPECT_FAILURE:-false}"

if [[ -z "$JENKINS_PASSWORD" ]]; then
    log_error "JENKINS_ADMIN_PASSWORD is not set in .env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

COOKIE_JAR=$(mktemp)
trap "rm -f '$COOKIE_JAR'" EXIT

jenkins_api() {
    local path="$1"
    curl -sf --max-time 30 -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" "${JENKINS_URL}/${path}"
}

# Get CRUMB for CSRF protection (with session cookie)
get_crumb() {
    local crumb_json
    crumb_json=$(curl -sf --max-time 10 -c "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || true)

    if [[ -n "$crumb_json" ]]; then
        local field value
        field=$(echo "$crumb_json" | jq -r '.crumbRequestField // empty' 2>/dev/null || true)
        value=$(echo "$crumb_json" | jq -r '.crumb // empty' 2>/dev/null || true)
        if [[ -n "$field" && -n "$value" ]]; then
            echo "${field}:${value}"
            return 0
        fi
    fi
    echo ""
}

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

# 1. Verify Jenkins is reachable
log_info "Checking Jenkins..."
if ! curl -sf --max-time 10 -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
    "${JENKINS_URL}/api/json" &>/dev/null; then
    log_error "Jenkins is not reachable at ${JENKINS_URL}"
    exit 1
fi
log_ok "Jenkins is ready"

# 2. Verify job exists (poll in case CasC/Job DSL has not finished seeding)
log_info "Checking job '${JOB_NAME}'..."
JOB_FOUND=false
JOB_WAIT=0
while [[ $JOB_WAIT -lt 60 ]]; do
    if jenkins_api "job/${JOB_NAME}/api/json" &>/dev/null; then
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

# 3. Get the next build number before triggering
NEXT_BUILD=$(jenkins_api "job/${JOB_NAME}/api/json" | \
    jq -r '.nextBuildNumber // 1' 2>/dev/null || echo "1")

# 4. Trigger build
log_info "Triggering build #${NEXT_BUILD}..."
if [[ -n "${E2E_CI_VARIABLES:-}" ]]; then
    log_info "CI variables: ${E2E_CI_VARIABLES}"
fi
CRUMB=$(get_crumb)

# Build curl args for trigger
TRIGGER_ENDPOINT="build"
TRIGGER_DATA=()
if [[ -n "${E2E_CI_VARIABLES:-}" ]]; then
    TRIGGER_ENDPOINT="buildWithParameters"
    IFS=',' read -ra _pairs <<< "$E2E_CI_VARIABLES"
    for pair in "${_pairs[@]}"; do
        _key="${pair%%=*}"
        _val="${pair#*=}"
        _key="$(echo "$_key" | tr -d '[:space:]')"
        [[ -z "$_key" ]] && continue
        TRIGGER_DATA+=(--data-urlencode "${_key}=${_val}")
    done
fi

if [[ -n "$CRUMB" ]]; then
    curl -sf --max-time 30 -X POST -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
        -H "$CRUMB" \
        ${TRIGGER_DATA[@]+"${TRIGGER_DATA[@]}"} \
        "${JENKINS_URL}/job/${JOB_NAME}/${TRIGGER_ENDPOINT}" >/dev/null 2>&1
else
    curl -sf --max-time 30 -X POST -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
        ${TRIGGER_DATA[@]+"${TRIGGER_DATA[@]}"} \
        "${JENKINS_URL}/job/${JOB_NAME}/${TRIGGER_ENDPOINT}" >/dev/null 2>&1
fi

# 5. Wait for build to appear in queue and start
log_info "Waiting for build to start..."
ELAPSED=0
BUILD_STARTED=false
while [[ $ELAPSED -lt 60 ]]; do
    if jenkins_api "job/${JOB_NAME}/${NEXT_BUILD}/api/json" &>/dev/null; then
        BUILD_STARTED=true
        break
    fi
    printf "."
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done
echo ""

if [[ "$BUILD_STARTED" != "true" ]]; then
    log_error "Build #${NEXT_BUILD} did not start within 60s"
    exit 1
fi

BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${NEXT_BUILD}"
log_ok "Build #${NEXT_BUILD} started"
echo "  URL: ${BUILD_URL}"
echo ""

# 6. Poll for completion
log_info "Waiting for build completion (timeout: ${TIMEOUT_SECONDS}s)..."
ELAPSED=0
FINAL_RESULT=""

while [[ $ELAPSED -lt $TIMEOUT_SECONDS ]]; do
    BUILD_JSON=$(jenkins_api "job/${JOB_NAME}/${NEXT_BUILD}/api/json" 2>/dev/null || true)

    if [[ -z "$BUILD_JSON" ]]; then
        printf "."
        sleep "$POLL_INTERVAL"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        continue
    fi

    local_building=$(echo "$BUILD_JSON" | jq -r '.building' 2>/dev/null || echo "true")
    local_result=$(echo "$BUILD_JSON" | jq -r '.result // "null"' 2>/dev/null || echo "null")

    if [[ "$local_building" == "false" && "$local_result" != "null" ]]; then
        FINAL_RESULT="$local_result"
        break
    fi

    printf "."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
echo ""

if [[ -z "$FINAL_RESULT" ]]; then
    log_error "Build timed out after ${TIMEOUT_SECONDS}s"
    exit 1
fi

log_info "Build result: ${FINAL_RESULT}"
echo ""

# 7. Show stage information (via wfapi if available)
STAGES_JSON=$(jenkins_api "job/${JOB_NAME}/${NEXT_BUILD}/wfapi/describe" 2>/dev/null || true)
if [[ -n "$STAGES_JSON" ]]; then
    echo "  Stages:"
    echo "$STAGES_JSON" | jq -r '
        .stages[]? |
        "\(if .status == "SUCCESS" then "  [v]" elif .status == "FAILED" then "  [x]" else "  [?]" end) \(.name): \(.status) (\(.durationMillis / 1000 | floor)s)"
    ' 2>/dev/null || echo "  (could not parse stage details)"
    echo ""
fi

# 8. Final result
if [[ "$EXPECT_FAILURE" == "true" ]]; then
    if [[ "$FINAL_RESULT" == "FAILURE" ]]; then
        log_ok "=== E2E JENKINS TEST PASSED (expected failure confirmed) ==="
        exit 0
    else
        log_error "Expected FAILURE but got: ${FINAL_RESULT}"
        log_error "=== E2E JENKINS TEST FAILED ==="
        exit 1
    fi
fi

if [[ "$FINAL_RESULT" == "SUCCESS" ]]; then
    log_ok "=== E2E JENKINS TEST PASSED ==="
    exit 0
else
    log_error "Expected SUCCESS but got: ${FINAL_RESULT}"

    # Show console output tail for debugging
    log_info "Last 30 lines of console output:"
    jenkins_api "job/${JOB_NAME}/${NEXT_BUILD}/consoleText" 2>/dev/null | tail -30 || true

    log_error "=== E2E JENKINS TEST FAILED ==="
    exit 1
fi
