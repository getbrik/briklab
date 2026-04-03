#!/usr/bin/env bash
# E2E Test Suite Orchestrator
#
# Runs multiple E2E pipeline scenarios sequentially and reports results.
#
# Usage:
#   bash e2e-run-suite.sh              # Run all scenarios
#   bash e2e-run-suite.sh --list       # List available scenarios
#   bash e2e-run-suite.sh --only NAME  # Run a single scenario by name
#
# Prerequisites:
#   - briklab GitLab must be running
#   - GITLAB_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Scenario definitions
# ---------------------------------------------------------------------------
# Each scenario: name | project_name | trigger_ref | required_jobs | optional_jobs | timeout | expect_failure:failed_job

SCENARIOS=(
    # --- Minimal stack coverage (branch push: no release, no package) ---
    "node-minimal|node-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||300"
    "python-minimal|python-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||300"
    "java-minimal|java-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "rust-minimal|rust-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "dotnet-minimal|dotnet-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    # --- Full pipelines (tag push: all stages) ---
    "node-full|node-full|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify|brik-quality|600"
    "python-full|python-full|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify|brik-quality,brik-security|600"
    "java-full|java-full|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify|brik-quality|600"
    # --- Security and Deploy ---
    "node-security|node-security|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify|brik-security|300"
    "node-deploy|node-deploy|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    # --- Error scenarios (expect pipeline failure) ---
    "error-build|node-error-build|main|brik-init||300|brik-build"
    "error-test|node-error-test|main|brik-init,brik-build||300|brik-test"
    "error-config|invalid-config|main|||300|brik-init"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

list_scenarios() {
    echo -e "${BOLD}Available E2E scenarios:${NC}"
    echo ""
    printf "  %-20s %-15s %-10s %-8s %s\n" "NAME" "PROJECT" "REF" "EXPECT" "REQUIRED JOBS"
    printf "  %-20s %-15s %-10s %-8s %s\n" "----" "-------" "---" "------" "-------------"
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail <<< "$scenario"
        local mode="pass"
        [[ -n "${expect_fail:-}" ]] && mode="fail"
        printf "  %-20s %-15s %-10s %-8s %s\n" "$name" "$project" "$ref" "$mode" "$required"
    done
    echo ""
}

# Run a single scenario.
# Args: scenario string (pipe-delimited)
# Returns: 0 on pass, 1 on fail
run_scenario() {
    local scenario="$1"
    IFS='|' read -r name project ref required optional timeout expect_fail <<< "$scenario"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Scenario: ${name}${NC}"
    if [[ -n "${expect_fail:-}" ]]; then
        echo -e "${YELLOW}  (expect failure: ${expect_fail})${NC}"
    fi
    echo -e "${BOLD}========================================${NC}"

    local project_encoded
    project_encoded="brik%2F${project}"

    # Parse expect_fail field: "failed_job_name" means expect pipeline failure
    local e2e_expect_failure="false"
    local e2e_expect_failed_job=""
    if [[ -n "${expect_fail:-}" ]]; then
        e2e_expect_failure="true"
        e2e_expect_failed_job="$expect_fail"
    fi

    E2E_PROJECT_PATH="$project_encoded" \
    E2E_REQUIRED_JOBS="$required" \
    E2E_OPTIONAL_JOBS="${optional:-}" \
    E2E_TRIGGER_REF="$ref" \
    E2E_TIMEOUT="${timeout:-300}" \
    E2E_EXPECT_FAILURE="$e2e_expect_failure" \
    E2E_EXPECT_FAILED_JOB="$e2e_expect_failed_job" \
        bash "${SCRIPT_DIR}/e2e-pipeline-test.sh"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ONLY_SCENARIO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            list_scenarios
            exit 0
            ;;
        --only)
            if [[ -z "${2:-}" ]]; then
                log_error "--only requires a scenario name"
                exit 1
            fi
            ONLY_SCENARIO="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 [--list] [--only SCENARIO_NAME]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Push all required test projects
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik E2E Test Suite ==="
echo ""

# Determine which projects to push
if [[ -n "$ONLY_SCENARIO" ]]; then
    # Find the matching scenario
    FOUND=false
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail <<< "$scenario"
        if [[ "$name" == "$ONLY_SCENARIO" ]]; then
            FOUND=true
            PROJECTS_TO_PUSH="$project"
            break
        fi
    done
    if [[ "$FOUND" != "true" ]]; then
        log_error "Scenario '${ONLY_SCENARIO}' not found"
        list_scenarios
        exit 1
    fi
else
    # Collect unique project names (deduplicated)
    PROJECTS_TO_PUSH=""
    declare -A _seen_projects=()
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail <<< "$scenario"
        if [[ -z "${_seen_projects[$project]:-}" ]]; then
            _seen_projects["$project"]=1
            PROJECTS_TO_PUSH="${PROJECTS_TO_PUSH:+${PROJECTS_TO_PUSH},}${project}"
        fi
    done
    unset _seen_projects
fi

log_info "Pushing test projects: ${PROJECTS_TO_PUSH}"
echo ""

E2E_TEST_PROJECTS="$PROJECTS_TO_PUSH" bash "${SCRIPT_DIR}/push-test-project.sh"

# ---------------------------------------------------------------------------
# Run scenarios
# ---------------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
RESULTS=()

for scenario in "${SCENARIOS[@]}"; do
    IFS='|' read -r name project ref required optional timeout expect_fail <<< "$scenario"

    # Skip if --only is set and this isn't the target
    if [[ -n "$ONLY_SCENARIO" && "$name" != "$ONLY_SCENARIO" ]]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))

    if run_scenario "$scenario"; then
        PASSED=$((PASSED + 1))
        RESULTS+=("PASS: ${name}")
    else
        FAILED=$((FAILED + 1))
        RESULTS+=("FAIL: ${name}")
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  E2E Suite Summary${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

for result in "${RESULTS[@]}"; do
    if [[ "$result" == PASS:* ]]; then
        log_ok "$result"
    else
        log_error "$result"
    fi
done

echo ""
echo -e "  Total: ${TOTAL} | Passed: ${GREEN}${PASSED}${NC} | Failed: ${RED}${FAILED}${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    log_error "=== E2E SUITE FAILED ==="
    exit 1
else
    log_ok "=== E2E SUITE PASSED ==="
    exit 0
fi
