#!/usr/bin/env bash
# E2E Test Suite Orchestrator
#
# Runs multiple E2E pipeline scenarios and reports results.
# Supports parallel batch execution for faster runs.
#
# Usage:
#   bash e2e-gitlab-suite.sh                    # Run all scenarios (sequential)
#   bash e2e-gitlab-suite.sh --batch-size 4     # Run in batches of 4
#   bash e2e-gitlab-suite.sh --list             # List available scenarios
#   bash e2e-gitlab-suite.sh --only NAME        # Run a single scenario by name
#   bash e2e-gitlab-suite.sh --complete         # Run only *-complete scenarios
#
# Prerequisites:
#   - briklab GitLab must be running
#   - GITLAB_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/gitlab-pat.sh
source "${SCRIPT_DIR}/../auth/gitlab-pat.sh"
reload_env
ensure_gitlab_pat

# Source E2E libraries
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"

# ---------------------------------------------------------------------------
# Scenario definitions
# ---------------------------------------------------------------------------
# Each scenario: name | project_name | trigger_ref | required_jobs | optional_jobs | timeout | expect_failure:failed_job | ci_vars | depends_on

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
    "node-deploy-gitops|node-deploy-gitops|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||900"
    "node-deploy-rollback|node-deploy-gitops-rollback|v0.1.0|||900|||node-deploy-gitops"
    # --- Deploy failure scenario (expect pipeline failure at deploy) ---
    "node-deploy-failure|node-deploy-failure|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package||600|brik-deploy"
    # --- Complete pipelines with Nexus publish (tag push: all stages + publish) ---
    "node-complete|node-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "python-complete|python-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "java-complete|java-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "rust-complete|rust-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
    "dotnet-complete|dotnet-complete|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-notify|brik-quality,brik-security|900"
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

# Run a single scenario.
# Args: scenario string (pipe-delimited)
# Returns: 0 on pass, 1 on fail
run_scenario() {
    local scenario="$1"
    IFS='|' read -r name project ref required optional timeout expect_fail ci_vars _depends_on <<< "$scenario"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Scenario: ${name}${NC}"
    if [[ -n "${expect_fail:-}" ]]; then
        echo -e "${YELLOW}  (expect failure: ${expect_fail})${NC}"
    fi
    if [[ -n "${ci_vars:-}" ]]; then
        echo -e "${BLUE}  CI vars: ${ci_vars}${NC}"
    fi
    echo -e "${BOLD}========================================${NC}"

    # Multi-step rollback scenario: delegate to dedicated script
    if [[ "$name" == "node-deploy-rollback" ]]; then
        E2E_TIMEOUT="${timeout:-900}" bash "${SCRIPT_DIR}/e2e-gitlab-rollback-test.sh"
        return $?
    fi

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
    E2E_CI_VARIABLES="${ci_vars:-}" \
        bash "${SCRIPT_DIR}/e2e-gitlab-test.sh"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ONLY_SCENARIO=""
FILTER_COMPLETE=""
BATCH_SIZE="${E2E_BATCH_SIZE:-0}"

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
        --batch-size)
            if [[ -z "${2:-}" ]]; then
                log_error "--batch-size requires a number"
                exit 1
            fi
            BATCH_SIZE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 [--list] [--only SCENARIO_NAME] [--complete] [--batch-size N]"
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
        IFS='|' read -r name project ref required optional timeout expect_fail ci_vars depends_on <<< "$scenario"
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
elif [[ "$FILTER_COMPLETE" == "true" ]]; then
    PROJECTS_TO_PUSH="node-complete,python-complete,java-complete,rust-complete,dotnet-complete"
else
    # Collect unique project names (deduplicated)
    PROJECTS_TO_PUSH=""
    declare -A _seen_projects=()
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail ci_vars depends_on <<< "$scenario"
        if [[ -z "${_seen_projects[$project]:-}" ]]; then
            _seen_projects["$project"]=1
            PROJECTS_TO_PUSH="${PROJECTS_TO_PUSH:+${PROJECTS_TO_PUSH},}${project}"
        fi
    done
    unset _seen_projects
fi

log_info "Pushing test projects: ${PROJECTS_TO_PUSH}"
echo ""

E2E_TEST_PROJECTS="$PROJECTS_TO_PUSH" bash "${SCRIPT_DIR}/push-test-project-gitlab.sh"

# Wait briefly for GitLab to create auto-triggered pipelines from the push,
# then cancel them all to free runner slots and avoid ArgoCD conflicts.
sleep 3
log_info "Cancelling auto-triggered pipelines..."
e2e.gitlab.cancel_all_group_pipelines "brik"

# ---------------------------------------------------------------------------
# Collect scenarios to run
# ---------------------------------------------------------------------------
SCENARIOS_TO_RUN=()
for scenario in "${SCENARIOS[@]}"; do
    IFS='|' read -r name project ref required optional timeout expect_fail ci_vars depends_on <<< "$scenario"

    # Skip if --only is set and this isn't the target
    if [[ -n "$ONLY_SCENARIO" && "$name" != "$ONLY_SCENARIO" ]]; then
        continue
    fi

    # Skip if --complete and this isn't a *-complete scenario
    if [[ "$FILTER_COMPLETE" == "true" && "$name" != *-complete ]]; then
        continue
    fi

    SCENARIOS_TO_RUN+=("$scenario")
done

# ---------------------------------------------------------------------------
# Run scenarios (sequential or batched)
# ---------------------------------------------------------------------------
TOTAL=${#SCENARIOS_TO_RUN[@]}
PASSED=0
FAILED=0
RESULTS=()

# Separate independent and dependent scenarios
# When --only is used, skip dependency checks (user explicitly chose the scenario)
INDEPENDENT_SCENARIOS=()
DEPENDENT_SCENARIOS=()
if [[ -n "$ONLY_SCENARIO" ]]; then
    INDEPENDENT_SCENARIOS=("${SCENARIOS_TO_RUN[@]}")
else
    for scenario in "${SCENARIOS_TO_RUN[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail ci_vars depends_on <<< "$scenario"
        if [[ -n "${depends_on:-}" ]]; then
            DEPENDENT_SCENARIOS+=("$scenario")
        else
            INDEPENDENT_SCENARIOS+=("$scenario")
        fi
    done
fi

INDEPENDENT_TOTAL=${#INDEPENDENT_SCENARIOS[@]}
DEPENDENT_TOTAL=${#DEPENDENT_SCENARIOS[@]}
[[ $DEPENDENT_TOTAL -gt 0 ]] && log_info "${DEPENDENT_TOTAL} scenario(s) with dependencies will run after their dependency passes"

# Track passed scenario names for dependency resolution
declare -A PASSED_SCENARIOS=()

# --- Phase 1: Run independent scenarios (batched or sequential) ---
if [[ $BATCH_SIZE -gt 1 && $INDEPENDENT_TOTAL -gt 1 ]]; then
    log_info "Running ${INDEPENDENT_TOTAL} independent scenarios in batches of ${BATCH_SIZE}"
    echo ""

    RESULT_DIR=$(mktemp -d)
    trap 'rm -rf "$RESULT_DIR"' EXIT

    idx=0
    while [[ $idx -lt $INDEPENDENT_TOTAL ]]; do
        batch_end=$((idx + BATCH_SIZE))
        [[ $batch_end -gt $INDEPENDENT_TOTAL ]] && batch_end=$INDEPENDENT_TOTAL
        batch_num=$(( (idx / BATCH_SIZE) + 1 ))

        echo ""
        log_info "--- Batch ${batch_num}: scenarios $((idx + 1)) to ${batch_end} ---"

        PIDS=()
        BATCH_NAMES=()
        for (( i=idx; i<batch_end; i++ )); do
            scenario="${INDEPENDENT_SCENARIOS[$i]}"
            IFS='|' read -r name _rest <<< "$scenario"
            BATCH_NAMES+=("$name")

            (
                if run_scenario "$scenario" > "${RESULT_DIR}/${name}.log" 2>&1; then
                    echo "PASS" > "${RESULT_DIR}/${name}.result"
                else
                    echo "FAIL" > "${RESULT_DIR}/${name}.result"
                fi
            ) &
            PIDS+=($!)
        done

        # Wait for all processes in this batch
        for pid in "${PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        # Collect results from this batch
        for name in "${BATCH_NAMES[@]}"; do
            result_file="${RESULT_DIR}/${name}.result"
            if [[ -f "$result_file" && "$(cat "$result_file")" == "PASS" ]]; then
                PASSED=$((PASSED + 1))
                RESULTS+=("PASS: ${name}")
                PASSED_SCENARIOS["$name"]=1
                log_ok "PASS: ${name}"
            else
                FAILED=$((FAILED + 1))
                RESULTS+=("FAIL: ${name}")
                log_error "FAIL: ${name}"
                # Show last 10 lines of log for failed scenarios
                if [[ -f "${RESULT_DIR}/${name}.log" ]]; then
                    echo "  --- last 10 lines ---"
                    tail -10 "${RESULT_DIR}/${name}.log" | sed 's/^/  /'
                    echo "  ---"
                fi
            fi
        done

        idx=$batch_end
    done
else
    # Sequential execution (default, backward compatible)
    for scenario in "${INDEPENDENT_SCENARIOS[@]}"; do
        IFS='|' read -r name _rest <<< "$scenario"

        if run_scenario "$scenario"; then
            PASSED=$((PASSED + 1))
            RESULTS+=("PASS: ${name}")
            PASSED_SCENARIOS["$name"]=1
        else
            FAILED=$((FAILED + 1))
            RESULTS+=("FAIL: ${name}")
        fi
    done
fi

# --- Phase 2: Run dependent scenarios sequentially ---
if [[ $DEPENDENT_TOTAL -gt 0 ]]; then
    echo ""
    log_info "--- Running ${DEPENDENT_TOTAL} dependent scenario(s) ---"

    for scenario in "${DEPENDENT_SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required optional timeout expect_fail ci_vars depends_on <<< "$scenario"

        # Check that the dependency passed
        if [[ -z "${PASSED_SCENARIOS[$depends_on]:-}" ]]; then
            log_warn "SKIP: ${name} (dependency '${depends_on}' did not pass)"
            FAILED=$((FAILED + 1))
            RESULTS+=("SKIP: ${name} (dependency '${depends_on}' failed)")
            continue
        fi

        log_info "Dependency '${depends_on}' passed - running ${name}"
        if run_scenario "$scenario"; then
            PASSED=$((PASSED + 1))
            RESULTS+=("PASS: ${name}")
            PASSED_SCENARIOS["$name"]=1
        else
            FAILED=$((FAILED + 1))
            RESULTS+=("FAIL: ${name}")
        fi
    done
fi

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
    elif [[ "$result" == SKIP:* ]]; then
        log_warn "$result"
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
