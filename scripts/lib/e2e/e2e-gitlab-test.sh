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
#
# Prerequisites:
#   - briklab GitLab must be running
#   - push-test-project-gitlab.sh must have been run
#   - GITLAB_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Ensure PAT is valid (refresh if expired/missing)
# shellcheck source=ensure-gitlab-pat.sh
. "${SCRIPT_DIR}/ensure-gitlab-pat.sh"
ensure_pat "$ENV_FILE"

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PAT="${GITLAB_PAT:-}"
PROJECT_PATH="${E2E_PROJECT_PATH:-brik%2Fnode-minimal}"
TRIGGER_REF="${E2E_TRIGGER_REF:-main}"
TIMEOUT_SECONDS="${E2E_TIMEOUT:-300}"
POLL_INTERVAL=10
EXPECT_FAILURE="${E2E_EXPECT_FAILURE:-false}"
EXPECT_FAILED_JOB="${E2E_EXPECT_FAILED_JOB:-}"

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
# Helpers
# ---------------------------------------------------------------------------

api_get() {
    curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" "${GITLAB_URL}/api/v4/$1"
}

api_post() {
    curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" -X POST "${GITLAB_URL}/api/v4/$1"
}

# Get the status of a specific job from the jobs JSON.
# Args: $1 = jobs JSON, $2 = job name
# Prints: job status or "not_found"
get_job_status() {
    local jobs_json="$1"
    local job_name="$2"
    JOBS_DATA="$jobs_json" JOB_NAME="$job_name" python3 -c '
import json, os
target = os.environ.get("JOB_NAME", "")
jobs = json.loads(os.environ.get("JOBS_DATA", "[]"))
for j in jobs:
    if j.get("name") == target:
        print(j.get("status", "not_found"))
        break
else:
    print("not_found")
' 2>/dev/null || echo "unknown"
}

# Validate a Docker image exists in the briklab registry.
# Args: $1 = image path (e.g. brik/node-full)
validate_registry_image() {
    local image_path="$1"
    local registry_url="http://${REGISTRY_HOSTNAME:-registry.briklab.test}:${REGISTRY_PORT:-5050}"
    local result
    result=$(curl -sf "${registry_url}/v2/${image_path}/tags/list" 2>/dev/null) || {
        log_warn "Registry unreachable or image not found: ${registry_url}/v2/${image_path}"
        return 1
    }

    if echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tags = d.get('tags') or []
if tags:
    print('Tags: ' + ', '.join(tags))
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null; then
        log_ok "Registry image found: ${image_path}"
        return 0
    else
        log_warn "Registry image not found: ${image_path}"
        return 1
    fi
}

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

# 1. Get project ID
log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID=$(api_get "projects/${PROJECT_PATH}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found. Run push-test-project-gitlab.sh first."
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

# 2. Trigger a pipeline
log_info "Triggering pipeline on ref '${TRIGGER_REF}'..."
PIPELINE_RESPONSE=$(api_post "projects/${PROJECT_ID}/pipeline?ref=${TRIGGER_REF}")
PIPELINE_ID=$(echo "$PIPELINE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [[ -z "$PIPELINE_ID" ]]; then
    log_error "Failed to trigger pipeline"
    echo "$PIPELINE_RESPONSE"
    exit 1
fi
log_ok "Pipeline triggered: #${PIPELINE_ID}"
echo "  URL: ${GITLAB_URL}/${PROJECT_NAME}/-/pipelines/${PIPELINE_ID}"
echo ""

# 3. Poll for completion
log_info "Waiting for pipeline completion (timeout: ${TIMEOUT_SECONDS}s)..."
ELAPSED=0
FINAL_STATUS=""

while [[ $ELAPSED -lt $TIMEOUT_SECONDS ]]; do
    STATUS=$(api_get "projects/${PROJECT_ID}/pipelines/${PIPELINE_ID}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)

    case "$STATUS" in
        success|failed|canceled|skipped)
            FINAL_STATUS="$STATUS"
            break
            ;;
        *)
            printf "."
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
    esac
done
echo ""

if [[ -z "$FINAL_STATUS" ]]; then
    log_error "Pipeline timed out after ${TIMEOUT_SECONDS}s"
    exit 1
fi

# 4. Get job details
log_info "Pipeline status: ${FINAL_STATUS}"
echo ""

JOBS=$(api_get "projects/${PROJECT_ID}/pipelines/${PIPELINE_ID}/jobs")

echo "  Jobs:"
echo "$JOBS" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for job in sorted(jobs, key=lambda j: j.get('id', 0)):
    name = job.get('name', 'unknown')
    status = job.get('status', 'unknown')
    stage = job.get('stage', 'unknown')
    icon = '  ' if status == 'success' else '  ' if status == 'failed' else '  '
    print(f'  {icon} [{stage}] {name}: {status}')
" 2>/dev/null || echo "  (could not parse job details)"

echo ""

# 5. Check required jobs
ALL_PASSED=true

for job_name in "${REQUIRED_JOBS[@]}"; do
    job_name="$(echo "$job_name" | tr -d '[:space:]')"
    [[ -z "$job_name" ]] && continue

    JOB_STATUS=$(get_job_status "$JOBS" "$job_name")

    if [[ "$JOB_STATUS" == "success" ]]; then
        log_ok "${job_name}: PASSED"
    else
        log_error "${job_name}: ${JOB_STATUS}"
        ALL_PASSED=false
    fi
done

# 6. Check optional jobs (warn only, do not fail)
for job_name in "${OPTIONAL_JOBS[@]}"; do
    job_name="$(echo "$job_name" | tr -d '[:space:]')"
    [[ -z "$job_name" ]] && continue

    JOB_STATUS=$(get_job_status "$JOBS" "$job_name")

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

echo ""

# 7. Final result
if [[ "$EXPECT_FAILURE" == "true" ]]; then
    # --- Expect-failure mode ---
    if [[ "$FINAL_STATUS" != "failed" ]]; then
        log_error "Expected pipeline to fail, but status is: ${FINAL_STATUS}"
        log_error "=== E2E TEST FAILED (expected failure did not occur) ==="
        exit 1
    fi

    if [[ -n "$EXPECT_FAILED_JOB" ]]; then
        FAILED_JOB_STATUS=$(get_job_status "$JOBS" "$EXPECT_FAILED_JOB")
        if [[ "$FAILED_JOB_STATUS" == "failed" ]]; then
            log_ok "${EXPECT_FAILED_JOB}: correctly failed"
        else
            log_error "${EXPECT_FAILED_JOB}: expected 'failed' but got '${FAILED_JOB_STATUS}'"
            log_error "=== E2E TEST FAILED (wrong job failed) ==="
            exit 1
        fi
    fi

    log_ok "=== E2E TEST PASSED (expected failure confirmed) ==="
    exit 0
fi

# --- Normal mode ---
if [[ "$ALL_PASSED" == "true" && "$FINAL_STATUS" == "success" ]]; then
    log_ok "=== E2E TEST PASSED ==="
    exit 0
elif [[ "$ALL_PASSED" == "true" ]]; then
    log_warn "=== Required jobs passed, but pipeline status: ${FINAL_STATUS} ==="
    log_warn "This may be due to optional stages (quality, security) or conditional stages"
    exit 0
else
    log_error "=== E2E TEST FAILED ==="
    exit 1
fi
