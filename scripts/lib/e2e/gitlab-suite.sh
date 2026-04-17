#!/usr/bin/env bash
# E2E Test Suite Orchestrator (GitLab)
#
# Runs multiple E2E pipeline scenarios and reports results.
# Supports parallel batch execution for faster runs.
#
# Usage:
#   bash gitlab-suite.sh                    # Run all scenarios (sequential)
#   bash gitlab-suite.sh --batch-size 4     # Run in batches of 4
#   bash gitlab-suite.sh --list             # List available scenarios
#   bash gitlab-suite.sh --only NAME        # Run a single scenario by name
#   bash gitlab-suite.sh --complete         # Run only *-complete scenarios
#
# Prerequisites:
#   - briklab GitLab must be running
#   - GITLAB_PAT must be set in .env
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
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
reload_env
ensure_gitlab_pat

# ---------------------------------------------------------------------------
# Scenario definitions
# ---------------------------------------------------------------------------
# Each scenario: name | project_name | trigger_ref | required_jobs | optional_jobs | timeout | expect_failure:failed_job | ci_vars | depends_on | error_pattern | success_jobs

SCENARIOS=(
    # --- Minimal stack coverage (branch push: no release, no package) ---
    "node-minimal|node-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||900"
    "python-minimal|python-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||900"
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
    "node-deploy-dryrun|node-deploy|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_DRY_RUN=true"
    "node-deploy-k8s|node-deploy-k8s|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-ssh|node-deploy-ssh|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-helm|node-deploy-helm|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-gitops|node-deploy-gitops|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||900"
    "node-deploy-rollback|node-deploy-gitops-rollback|v0.1.0|||900|||node-deploy-gitops"
    # --- Complete pipelines with Nexus publish (tag push: all stages + publish) ---
    "node-complete|node-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "python-complete|python-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "java-complete|java-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "rust-complete|rust-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "dotnet-complete|dotnet-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    # --- Workflow scenarios (push-driven, sequential) ---
    "workflow-trunk-main|node-workflow-trunk|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "workflow-trunk-tag|node-workflow-trunk|v0.2.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600||||workflow-trunk-main"
    "workflow-trunk-feature|node-workflow-trunk|branch:feature/test|brik-init,brik-build,brik-test,brik-notify||600||||workflow-trunk-tag"
    # --- Error scenarios (expect pipeline failure, with error pattern validation) ---
    # Note: error_pattern uses ~ as OR separator (converted to | at runtime)
    "error-build|node-error-build|main|brik-init||300|brik-build|||npm ERR!~SyntaxError|brik-init"
    "error-test|node-error-test|main|brik-init,brik-build||300|brik-test|||FAIL~test.*failed|brik-init,brik-build"
    "error-config|invalid-config|main|||300|brik-init|||validat~invalid~schema|"
    "error-deploy|node-deploy-failure|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package||600|brik-deploy|||brik-nonexistent~NotFound|brik-init,brik-release,brik-build,brik-test,brik-package"
)

# ---------------------------------------------------------------------------
# Callbacks for suite.sh
# ---------------------------------------------------------------------------

_suite_get_name() { IFS='|' read -r name _ <<< "$1"; echo "$name"; }
_suite_get_project() { IFS='|' read -r _ project _ <<< "$1"; echo "$project"; }
_suite_get_depends_on() { IFS='|' read -r _ _ _ _ _ _ _ _ dep <<< "$1"; echo "${dep:-}"; }

# Group mapping by scenario name prefix:
#   A: stack-minimal (node-minimal, python-minimal, etc.)
#   B: full pipelines (node-full, python-full, etc.)
#   C: complete pipelines (node-complete, python-complete, etc.)
#   D: security
#   E: deploy (compose, k8s, ssh, helm)
#   F: gitops + rollback (sequential)
#   G: workflow (sequential)
#   H: error scenarios
_suite_get_group() {
    local name
    IFS='|' read -r name _ <<< "$1"
    case "$name" in
        *-minimal)           echo "A" ;;
        *-full)              echo "B" ;;
        *-complete)          echo "C" ;;
        *-security)          echo "D" ;;
        *-deploy-gitops|*-deploy-rollback) echo "F" ;;
        *-deploy*)           echo "E" ;;
        workflow-*)          echo "G" ;;
        error-*)             echo "H" ;;
        *)                   echo "" ;;
    esac
}

_suite_list_scenarios() {
    echo -e "${BOLD}Available E2E scenarios:${NC}"
    echo ""
    printf "  %-20s %-15s %-10s %-8s %-20s %s\n" "NAME" "PROJECT" "REF" "EXPECT" "DEPENDS_ON" "REQUIRED JOBS"
    printf "  %-20s %-15s %-10s %-8s %-20s %s\n" "----" "-------" "---" "------" "----------" "-------------"
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail ci_vars depends_on <<< "$scenario"
        local mode="pass"
        [[ -n "${expect_fail:-}" ]] && mode="fail"
        printf "  %-20s %-15s %-10s %-8s %-20s %s\n" "$name" "$project" "$ref" "$mode" "${depends_on:--}" "$required"
    done
    echo ""
}

_suite_run_scenario() {
    local scenario="$1"
    IFS='|' read -r name project ref required optional timeout expect_fail ci_vars _depends_on error_pattern success_jobs <<< "$scenario"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Scenario: ${name}${NC}"
    if [[ -n "${expect_fail:-}" ]]; then
        echo -e "${YELLOW}  (expect failure: ${expect_fail})${NC}"
    fi
    if [[ -n "${ci_vars:-}" ]]; then
        echo -e "${BLUE}  CI vars: ${ci_vars}${NC}"
    fi
    if [[ -n "${error_pattern:-}" ]]; then
        echo -e "${YELLOW}  Error pattern: ${error_pattern}${NC}"
    fi
    echo -e "${BOLD}========================================${NC}"

    # Multi-step rollback scenario: delegate to dedicated script
    if [[ "$name" == "node-deploy-rollback" ]]; then
        E2E_TIMEOUT="${timeout:-900}" bash "${SCRIPT_DIR}/gitlab-rollback.sh"
        return $?
    fi

    local project_encoded="brik%2F${project}"
    local e2e_expect_failure="false"
    local e2e_expect_failed_job=""
    if [[ -n "${expect_fail:-}" ]]; then
        e2e_expect_failure="true"
        e2e_expect_failed_job="$expect_fail"
    fi

    # Auto-detect push mode for workflow scenarios or branch: refs
    local trigger_mode="${E2E_TRIGGER_MODE:-api}"
    if [[ "$name" == workflow-* || "$ref" == branch:* ]]; then
        trigger_mode="push"
    fi

    E2E_PROJECT_PATH="$project_encoded" \
    E2E_REQUIRED_JOBS="$required" \
    E2E_OPTIONAL_JOBS="${optional:-}" \
    E2E_TRIGGER_REF="$ref" \
    E2E_TRIGGER_MODE="$trigger_mode" \
    E2E_TIMEOUT="${timeout:-300}" \
    E2E_EXPECT_FAILURE="$e2e_expect_failure" \
    E2E_EXPECT_FAILED_JOB="$e2e_expect_failed_job" \
    E2E_CI_VARIABLES="${ci_vars:-}" \
    E2E_EXPECTED_ERROR_PATTERN="${error_pattern//\~/$'|'}" \
    E2E_EXPECT_SUCCESS_JOBS="${success_jobs:-}" \
        bash "${SCRIPT_DIR}/gitlab-test.sh"
}

_suite_push_projects() {
    local projects_csv="$1"
    e2e.push.brik_repos "gitlab"
    e2e.push.test_projects "gitlab" "$projects_csv"

    # Cancel auto-triggered pipelines from the push
    sleep 3
    log_info "Cancelling auto-triggered pipelines..."
    e2e.gitlab.cancel_all_group_pipelines "brik"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
e2e.suite.run SCENARIOS "Brik E2E Test Suite" "$@"
