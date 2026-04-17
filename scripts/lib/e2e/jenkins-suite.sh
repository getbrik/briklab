#!/usr/bin/env bash
# E2E Jenkins Test Suite Orchestrator
#
# Runs multiple Jenkins E2E pipeline scenarios and reports results.
# Supports parallel batch execution for faster runs.
#
# Usage:
#   bash jenkins-suite.sh                    # Run all scenarios (sequential)
#   bash jenkins-suite.sh --batch-size 6     # Run in batches of 6
#   bash jenkins-suite.sh --list             # List available scenarios
#   bash jenkins-suite.sh --only NAME        # Run a single scenario by name
#   bash jenkins-suite.sh --complete         # Run only *-complete scenarios
#
# Prerequisites:
#   - briklab Jenkins must be running
#   - briklab Gitea must be running
#   - GITEA_PAT and JENKINS_ADMIN_PASSWORD must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/push.sh
source "${SCRIPT_DIR}/lib/push.sh"
# shellcheck source=lib/suite.sh
source "${SCRIPT_DIR}/lib/suite.sh"
reload_env

# ---------------------------------------------------------------------------
# Scenario definitions
# Format: name|jenkins_job|projects_to_push|timeout|expect_failure|ci_vars|depends_on|error_pattern
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
    "node-deploy-helm|node-deploy-helm|node-deploy-helm|600|false"
    "node-deploy-gitops|node-deploy-gitops|node-deploy-gitops|900|false"
    "node-deploy-rollback|node-deploy-gitops-rollback|node-deploy-gitops-rollback|900|false||node-deploy-gitops"
    "error-build|node-error-build|node-error-build|300|true||npm ERR!|SyntaxError"
    "error-test|node-error-test|node-error-test|300|true||FAIL|test.*failed"
    "error-config|invalid-config|invalid-config|300|true||validat|invalid|schema"
    "error-deploy|node-deploy-failure|node-deploy-failure|600|true||brik-nonexistent|NotFound"
)

# ---------------------------------------------------------------------------
# Callbacks for suite.sh
# ---------------------------------------------------------------------------

_suite_get_name() { IFS='|' read -r name _ <<< "$1"; echo "$name"; }
_suite_get_project() { IFS='|' read -r _ _ projects _ <<< "$1"; echo "$projects"; }
_suite_get_depends_on() { IFS='|' read -r _ _ _ _ _ _ dep <<< "$1"; echo "${dep:-}"; }

_suite_list_scenarios() {
    echo -e "${BOLD}Available Jenkins E2E scenarios:${NC}"
    echo ""
    printf "  %-20s %-20s %-10s %-8s %s\n" "NAME" "JOB" "TIMEOUT" "EXPECT" "DEPENDS_ON"
    printf "  %-20s %-20s %-10s %-8s %s\n" "----" "---" "-------" "------" "----------"
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name job _projects timeout expect_fail ci_vars depends_on <<< "$scenario"
        local mode="pass"
        [[ "$expect_fail" == "true" ]] && mode="fail"
        printf "  %-20s %-20s %-10s %-8s %s\n" "$name" "$job" "${timeout}s" "$mode" "${depends_on:--}"
    done
    echo ""
}

_suite_run_scenario() {
    local scenario="$1"
    IFS='|' read -r name job _projects timeout expect_fail ci_vars _depends_on error_pattern <<< "$scenario"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Jenkins Scenario: ${name}${NC}"
    echo -e "${BOLD}========================================${NC}"
    if [[ -n "${ci_vars:-}" ]]; then
        echo -e "${BLUE}  CI vars: ${ci_vars}${NC}"
    fi
    if [[ -n "${error_pattern:-}" ]]; then
        echo -e "${YELLOW}  Error pattern: ${error_pattern}${NC}"
    fi

    # Multi-step rollback scenario: delegate to dedicated script
    if [[ "$name" == "node-deploy-rollback" ]]; then
        E2E_JENKINS_TIMEOUT="${timeout:-900}" bash "${SCRIPT_DIR}/jenkins-rollback.sh"
        return $?
    fi

    E2E_JENKINS_JOB="$job" \
    E2E_JENKINS_TIMEOUT="$timeout" \
    E2E_JENKINS_EXPECT_FAILURE="$expect_fail" \
    E2E_CI_VARIABLES="${ci_vars:-}" \
    E2E_EXPECTED_ERROR_PATTERN="${error_pattern:-}" \
        bash "${SCRIPT_DIR}/jenkins-test.sh"
}

_suite_push_projects() {
    local projects_csv="$1"
    e2e.push.brik_repos "gitea"
    e2e.push.test_projects "gitea" "$projects_csv"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
e2e.suite.run SCENARIOS "Brik Jenkins E2E Test Suite" "$@"
