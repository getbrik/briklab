#!/usr/bin/env bash
# E2E Pipeline Test
#
# Triggers a pipeline on brik/node-minimal and waits for completion.
# Validates that Init, Build, and Test stages pass.
#
# Prerequisites:
#   - briklab GitLab must be running
#   - push-test-project.sh must have been run
#   - GITLAB_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
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

GITLAB_URL="http://localhost:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PAT="${GITLAB_PAT:-}"
PROJECT_PATH="brik%2Fnode-minimal"
TIMEOUT_SECONDS=300
POLL_INTERVAL=10

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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik E2E Pipeline Test ==="
echo ""

# 1. Get project ID
log_info "Looking up project brik/node-minimal..."
PROJECT_ID=$(api_get "projects/${PROJECT_PATH}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project brik/node-minimal not found. Run push-test-project.sh first."
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

# 2. Trigger a pipeline on main branch
log_info "Triggering pipeline on main branch..."
PIPELINE_RESPONSE=$(api_post "projects/${PROJECT_ID}/pipeline?ref=main")
PIPELINE_ID=$(echo "$PIPELINE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [[ -z "$PIPELINE_ID" ]]; then
    log_error "Failed to trigger pipeline"
    echo "$PIPELINE_RESPONSE"
    exit 1
fi
log_ok "Pipeline triggered: #${PIPELINE_ID}"
echo "  URL: ${GITLAB_URL}/brik/node-minimal/-/pipelines/${PIPELINE_ID}"
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

# 5. Check required stages
REQUIRED_STAGES=("brik-init" "brik-build" "brik-test")
ALL_PASSED=true

for job_name in "${REQUIRED_STAGES[@]}"; do
    JOB_STATUS=$(echo "$JOBS" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    if j.get('name') == '${job_name}':
        print(j.get('status', 'not_found'))
        break
else:
    print('not_found')
" 2>/dev/null || echo "unknown")

    if [[ "$JOB_STATUS" == "success" ]]; then
        log_ok "${job_name}: PASSED"
    else
        log_error "${job_name}: ${JOB_STATUS}"
        ALL_PASSED=false
    fi
done

echo ""

# 6. Final result
if [[ "$ALL_PASSED" == "true" && "$FINAL_STATUS" == "success" ]]; then
    log_ok "=== E2E TEST PASSED ==="
    exit 0
elif [[ "$ALL_PASSED" == "true" ]]; then
    log_warn "=== Required stages passed, but pipeline status: ${FINAL_STATUS} ==="
    log_warn "This may be due to optional stages (quality, security) or conditional stages"
    exit 0
else
    log_error "=== E2E TEST FAILED ==="
    exit 1
fi
