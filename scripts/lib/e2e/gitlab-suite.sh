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
# shellcheck source=lib/compose.sh
source "${SCRIPT_DIR}/lib/compose.sh"
# shellcheck source=lib/nexus.sh
source "${SCRIPT_DIR}/lib/nexus.sh"
# shellcheck source=lib/argocd.sh
source "${SCRIPT_DIR}/lib/argocd.sh"
reload_env
ensure_gitlab_pat

# ---------------------------------------------------------------------------
# Scenario definitions
# ---------------------------------------------------------------------------
# Each scenario: name | project_name | trigger_ref | required_jobs | _legacy_optional | timeout | expect_failure:failed_job | ci_vars | depends_on | error_pattern | success_jobs
# The 5th column (_legacy_optional) is kept as a vestigial empty placeholder
# to preserve the positional parser; the optional-jobs convention was
# dropped in chantier 20260510 sub-chantier 10. All jobs that the runtime
# now produces a fragment for are required.

SCENARIOS=(
    # The per-stage, per-stack, planner and findings behavior is covered by
    # the brik repo's contract, unit and integration suites
    # (spec/{contracts,unit,integration}/). Only scenarios that genuinely need
    # a live orchestrator or real deploy infrastructure remain here:
    #   - node-full: end-to-end happy path on GitLab (orchestrator parity).
    #   - node-deploy-gitops: real ArgoCD / GitOps sync.
    #   - node-deploy-rollback: real GitOps rollback (depends on the gitops run).
    "node-full|node-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    # Stub-image variant: every stage runs on the single brik-runner-stub
    # image via the BRIK_RUNNER_CLASSES_FILE override (built locally from
    # brik-images/images/stub/Dockerfile). Validates the FULL shared-library
    # workflow (context, planner, gates, needs, image parity) on the real
    # orchestrator without pulling heavy stack images. init itself boots on
    # its default base image, then emits the stub image map via its dotenv.
    # Reuses the node-full project repo.
    "node-full-stub|node-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true,BRIK_RUNNER_CLASSES_FILE=/opt/brik/lib/registry/runner_classes.stub.yml"
    "node-deploy-gitops|node-deploy-gitops|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||900||BRIK_WITH_DEPLOY=true"
    "node-deploy-rollback|node-deploy-gitops-rollback|v0.1.0|||900|||node-deploy-gitops"
)

# ---------------------------------------------------------------------------
# Callbacks for suite.sh
# ---------------------------------------------------------------------------

_suite_get_name() { IFS='|' read -r name _ <<< "$1"; echo "$name"; }
_suite_get_project() { IFS='|' read -r _ project _ <<< "$1"; echo "$project"; }
# Trailing `_ _` absorbs columns 10 (error_pattern) and 11 (success_jobs)
# so they don't get glued into depends_on. Without them, error-* and
# workflow-trunk-tag/feature returned depends_on=
# "|<error_pattern>|<success_jobs>" or "|workflow-trunk-main", which
# never matched a passed scenario name and SKIPped every dependent test
# in --all runs (single-scenario --only mode bypassed dep resolution so
# the bug stayed invisible there).
_suite_get_depends_on() { IFS='|' read -r _ _ _ _ _ _ _ _ dep _ _ <<< "$1"; echo "${dep:-}"; }

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
        node-plan-*)         echo "I" ;;
        *)                   echo "" ;;
    esac
}

_suite_list_scenarios() {
    echo -e "${BOLD}Available E2E scenarios:${NC}"
    echo ""
    printf "  %-20s %-15s %-10s %-8s %-20s %s\n" "NAME" "PROJECT" "REF" "EXPECT" "DEPENDS_ON" "REQUIRED JOBS"
    printf "  %-20s %-15s %-10s %-8s %-20s %s\n" "----" "-------" "---" "------" "----------" "-------------"
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r name project ref required _optional timeout expect_fail ci_vars depends_on <<< "$scenario"
        local mode="pass"
        [[ -n "${expect_fail:-}" ]] && mode="fail"
        printf "  %-20s %-15s %-10s %-8s %-20s %s\n" "$name" "$project" "$ref" "$mode" "${depends_on:--}" "$required"
    done
    echo ""
}

_suite_run_scenario() {
    local scenario="$1"
    IFS='|' read -r name project ref required _optional timeout expect_fail ci_vars _depends_on error_pattern success_jobs <<< "$scenario"

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

    # Per-scenario pre-cleanup: wipe stale state that would cause false
    # failures (stale compose stacks holding ports, cargo crates already
    # published in Nexus, dead ArgoCD port-forward on the host).
    case "$name" in
        node-deploy|node-deploy-dryrun)
            e2e.compose.teardown_stack "node-deploy"
            ;;
        rust-complete)
            e2e.nexus.delete_cargo_crate "rust-complete" "0.1.0"
            ;;
        *-deploy-gitops|*-deploy-rollback)
            e2e.argocd.ensure_port_forward || \
                log_warn "ArgoCD port-forward could not be established -- gitops scenario may fail"
            ;;
    esac

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
    # Push mode for workflow scenarios, branch: refs, and the docs-only
    # two-phase trigger (an API trigger would target a non-existent
    # "docs-only" ref; only e2e.git.trigger_via_push handles it).
    if [[ "$name" == workflow-* || "$ref" == branch:* || "$ref" == docs-only ]]; then
        trigger_mode="push"
    fi

    # A docs-only commit reduces the dynamic child to brik-notify alone;
    # the child aggregate-report carries zero stages (parent skip
    # fragments are not propagated -- known D.5c gap), so the generic
    # aggregate assertions do not apply.
    local skip_aggregate=false
    if [[ "$ref" == docs-only ]]; then
        skip_aggregate=true
    fi

    E2E_PROJECT_PATH="$project_encoded" \
    E2E_REQUIRED_JOBS="$required" \
    E2E_TRIGGER_REF="$ref" \
    E2E_TRIGGER_MODE="$trigger_mode" \
    E2E_TIMEOUT="${timeout:-300}" \
    E2E_EXPECT_FAILURE="$e2e_expect_failure" \
    E2E_EXPECT_FAILED_JOB="$e2e_expect_failed_job" \
    E2E_CI_VARIABLES="${ci_vars:-}" \
    E2E_EXPECTED_ERROR_PATTERN="${error_pattern//\~/$'|'}" \
    E2E_EXPECT_SUCCESS_JOBS="${success_jobs:-}" \
    E2E_SKIP_AGGREGATE="$skip_aggregate" \
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
