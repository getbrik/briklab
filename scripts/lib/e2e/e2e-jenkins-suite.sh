#!/usr/bin/env bash
# E2E Jenkins Test Suite Orchestrator
#
# Runs multiple Jenkins E2E pipeline scenarios sequentially and reports results.
#
# Usage:
#   bash e2e-jenkins-suite.sh              # Run all scenarios
#   bash e2e-jenkins-suite.sh --list       # List available scenarios
#   bash e2e-jenkins-suite.sh --only NAME  # Run a single scenario by name
#   bash e2e-jenkins-suite.sh --complete   # Run only *-complete scenarios
#
# Prerequisites:
#   - briklab Jenkins must be running
#   - briklab Gitea must be running
#   - GITEA_PAT and JENKINS_ADMIN_PASSWORD must be set in .env
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
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Scenario definitions
# Format: name|jenkins_job|projects_to_push|timeout|expect_failure|ci_vars
# ---------------------------------------------------------------------------
SCENARIOS=(
    "node-minimal|node-minimal|node-minimal|300|false"
    "python-minimal|python-minimal|python-minimal|300|false"
    "java-minimal|java-minimal|java-minimal|300|false"
    "rust-minimal|rust-minimal|rust-minimal|300|false"
    "dotnet-minimal|dotnet-minimal|dotnet-minimal|300|false"
    "node-complete|node-complete|node-complete|600|false"
    "python-complete|python-complete|python-complete|600|false"
    "java-complete|java-complete|java-complete|900|false"
    "rust-complete|rust-complete|rust-complete|900|false"
    "dotnet-complete|dotnet-complete|dotnet-complete|900|false"
    "node-full|node-full|node-full|600|false"
    "python-full|python-full|python-full|600|false"
    "java-full|java-full|java-full|600|false"
    "node-security|node-security|node-security|300|false"
    "node-deploy|node-deploy|node-deploy|600|false"
    "node-deploy-dryrun|node-deploy|node-deploy|600|false|BRIK_DRY_RUN=true"
    "node-deploy-k8s|node-deploy-k8s|node-deploy-k8s|600|false"
    "node-deploy-ssh|node-deploy-ssh|node-deploy-ssh|600|false"
    "node-deploy-gitops|node-deploy-gitops|node-deploy-gitops|900|false"
    "node-deploy-rollback|node-deploy-gitops|node-deploy-gitops|900|false|BRIK_DEPLOY_ROLLBACK_TEST=true"
    "node-deploy-failure|node-deploy-failure|node-deploy-failure|600|true"
    "error-build|node-error-build|node-error-build|300|true"
    "error-test|node-error-test|node-error-test|300|true"
    "error-config|invalid-config|invalid-config|300|true"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

list_scenarios() {
    echo -e "${BOLD}Available Jenkins E2E scenarios:${NC}"
    echo ""
    printf "  %-20s %-20s %-10s %s\n" "NAME" "JOB" "TIMEOUT" "EXPECT"
    printf "  %-20s %-20s %-10s %s\n" "----" "---" "-------" "------"
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name job _projects timeout expect_fail ci_vars <<< "$scenario"
        local mode="pass"
        [[ "$expect_fail" == "true" ]] && mode="fail"
        printf "  %-20s %-20s %-10s %s\n" "$name" "$job" "${timeout}s" "$mode"
    done
    echo ""
}

run_scenario() {
    local scenario="$1"
    IFS='|' read -r name job _projects timeout expect_fail ci_vars <<< "$scenario"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Jenkins Scenario: ${name}${NC}"
    echo -e "${BOLD}========================================${NC}"
    if [[ -n "${ci_vars:-}" ]]; then
        echo -e "${BLUE}  CI vars: ${ci_vars}${NC}"
    fi

    E2E_JENKINS_JOB="$job" \
    E2E_JENKINS_TIMEOUT="$timeout" \
    E2E_JENKINS_EXPECT_FAILURE="$expect_fail" \
    E2E_CI_VARIABLES="${ci_vars:-}" \
        bash "${SCRIPT_DIR}/e2e-jenkins-test.sh"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ONLY_SCENARIO=""
FILTER_COMPLETE=""

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
        --complete)
            FILTER_COMPLETE="true"
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 [--list] [--only SCENARIO_NAME] [--complete]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Collect and push required test projects to Gitea
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik Jenkins E2E Test Suite ==="
echo ""

PROJECTS_TO_PUSH=""
if [[ -n "$ONLY_SCENARIO" ]]; then
    FOUND=false
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name _job projects _timeout _expect _ci_vars <<< "$scenario"
        if [[ "$name" == "$ONLY_SCENARIO" ]]; then
            FOUND=true
            PROJECTS_TO_PUSH="$projects"
            break
        fi
    done
    if [[ "$FOUND" != "true" ]]; then
        log_error "Scenario '${ONLY_SCENARIO}' not found"
        list_scenarios
        exit 1
    fi
elif [[ "$FILTER_COMPLETE" == "true" ]]; then
    PROJECTS_TO_PUSH="node-complete,python-complete,java-complete,rust-complete,dotnet-complete"
else
    declare -A _seen=()
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r _name _job projects _timeout _expect <<< "$scenario"
        if [[ -z "${_seen[$projects]:-}" ]]; then
            _seen["$projects"]=1
            PROJECTS_TO_PUSH="${PROJECTS_TO_PUSH:+${PROJECTS_TO_PUSH},}${projects}"
        fi
    done
    unset _seen
fi

log_info "Pushing test projects: ${PROJECTS_TO_PUSH}"
echo ""

E2E_JENKINS_PROJECTS="$PROJECTS_TO_PUSH" bash "${SCRIPT_DIR}/push-test-project-gitea.sh"

# ---------------------------------------------------------------------------
# Run scenarios
# ---------------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
RESULTS=()

for scenario in "${SCENARIOS[@]}"; do
    IFS='|' read -r name _job _projects _timeout _expect <<< "$scenario"

    if [[ -n "$ONLY_SCENARIO" && "$name" != "$ONLY_SCENARIO" ]]; then
        continue
    fi

    if [[ "$FILTER_COMPLETE" == "true" && "$name" != *-complete ]]; then
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
echo -e "${BOLD}  Jenkins E2E Suite Summary${NC}"
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
    log_error "=== JENKINS E2E SUITE FAILED ==="
    exit 1
else
    log_ok "=== JENKINS E2E SUITE PASSED ==="
    exit 0
fi
