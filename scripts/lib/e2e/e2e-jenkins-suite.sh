#!/usr/bin/env bash
# E2E Jenkins Test Suite Orchestrator
#
# Runs multiple Jenkins E2E pipeline scenarios and reports results.
# Supports parallel batch execution for faster runs.
#
# Usage:
#   bash e2e-jenkins-suite.sh                    # Run all scenarios (sequential)
#   bash e2e-jenkins-suite.sh --batch-size 6     # Run in batches of 6
#   bash e2e-jenkins-suite.sh --list             # List available scenarios
#   bash e2e-jenkins-suite.sh --only NAME        # Run a single scenario by name
#   bash e2e-jenkins-suite.sh --complete         # Run only *-complete scenarios
#
# Prerequisites:
#   - briklab Jenkins must be running
#   - briklab Gitea must be running
#   - GITEA_PAT and JENKINS_ADMIN_PASSWORD must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

# ---------------------------------------------------------------------------
# Scenario definitions
# Format: name|jenkins_job|projects_to_push|timeout|expect_failure|ci_vars|depends_on
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
    "node-deploy-rollback|node-deploy-gitops-rollback|node-deploy-gitops-rollback|900|false|||node-deploy-gitops"
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

run_scenario() {
    local scenario="$1"
    IFS='|' read -r name job _projects timeout expect_fail ci_vars _depends_on <<< "$scenario"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Jenkins Scenario: ${name}${NC}"
    echo -e "${BOLD}========================================${NC}"
    if [[ -n "${ci_vars:-}" ]]; then
        echo -e "${BLUE}  CI vars: ${ci_vars}${NC}"
    fi

    # Multi-step rollback scenario: delegate to dedicated script
    if [[ "$name" == "node-deploy-rollback" ]]; then
        E2E_JENKINS_TIMEOUT="${timeout:-900}" bash "${SCRIPT_DIR}/e2e-jenkins-rollback-test.sh"
        return $?
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
# Collect and push required test projects to Gitea
# ---------------------------------------------------------------------------
echo ""
log_info "=== Brik Jenkins E2E Test Suite ==="
echo ""

PROJECTS_TO_PUSH=""
if [[ -n "$ONLY_SCENARIO" ]]; then
    FOUND=false
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name _job projects _timeout _expect _ci_vars _depends_on <<< "$scenario"
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
        IFS='|' read -r _name _job projects _timeout _expect _ci_vars _depends_on <<< "$scenario"
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
# Collect scenarios to run
# ---------------------------------------------------------------------------
SCENARIOS_TO_RUN=()
for scenario in "${SCENARIOS[@]}"; do
    IFS='|' read -r name _job _projects _timeout _expect _ci_vars _depends_on <<< "$scenario"

    if [[ -n "$ONLY_SCENARIO" && "$name" != "$ONLY_SCENARIO" ]]; then
        continue
    fi

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
        IFS='|' read -r name _job _projects _timeout _expect _ci_vars depends_on <<< "$scenario"
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
        IFS='|' read -r name _job _projects _timeout _expect _ci_vars depends_on <<< "$scenario"

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
echo -e "${BOLD}  Jenkins E2E Suite Summary${NC}"
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
    log_error "=== JENKINS E2E SUITE FAILED ==="
    exit 1
else
    log_ok "=== JENKINS E2E SUITE PASSED ==="
    exit 0
fi
