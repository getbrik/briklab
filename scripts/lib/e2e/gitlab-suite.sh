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
    # All projects now use /templates/dynamic-pipeline.yml. The planner
    # gates each stage by context + opt-in flag:
    #   - tag push (v*.*.*) -> _plan.yml auto-passes --with-release --with-package.
    #   - to also run deploy, pass BRIK_WITH_DEPLOY=true via CI variable.
    # Scenarios that previously required brik-deploy on branch push are
    # now corrected: deploy is opt-in only.

    # --- Minimal stack coverage (branch push: no release, no package, no deploy) ---
    "node-minimal|node-minimal|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||900"
    "python-minimal|python-minimal|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||900"
    "java-minimal|java-minimal|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600"
    "rust-minimal|rust-minimal|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600"
    "dotnet-minimal|dotnet-minimal|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600"
    # --- Full pipelines (tag push: release + package; deploy via opt-in) ---
    # node-full is the generic clean Node fixture (deps up-to-date, scan
    # green). The CVE-detection twin lives in the "Broken" section below
    # under node-full-cve so its purpose is obvious from the name.
    "node-full|node-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    "python-full|python-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    "java-full|java-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    # --- Security and Deploy ---
    "node-security|node-security|main|brik-init,brik-build,brik-sast,brik-scan,brik-test,brik-notify||300"
    "node-deploy|node-deploy|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    "node-deploy-dryrun|node-deploy|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_DRY_RUN=true,BRIK_WITH_DEPLOY=true"
    "node-deploy-k8s|node-deploy-k8s|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    "node-deploy-ssh|node-deploy-ssh|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    "node-deploy-helm|node-deploy-helm|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    "node-deploy-gitops|node-deploy-gitops|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||900||BRIK_WITH_DEPLOY=true"
    "node-deploy-rollback|node-deploy-gitops-rollback|v0.1.0|||900|||node-deploy-gitops"
    # --- Complete pipelines with Nexus publish (tag push: all stages + publish, no deploy) ---
    # node-complete is the generic clean Node fixture for publish flows.
    # The CVE+format twin lives in the "Broken" section below under
    # node-complete-cve so its purpose is obvious from the name.
    "node-complete|node-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "python-complete|python-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "java-complete|java-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "rust-complete|rust-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "dotnet-complete|dotnet-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    # --- Workflow scenarios (push-driven, sequential) ---
    "workflow-trunk-main|node-workflow-trunk|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600"
    # workflow-trunk-tag intentionally does NOT set BRIK_WITH_DEPLOY:
    # adding any E2E_CI_VARIABLES forces the harness from push mode
    # to API trigger, and an API trigger on v0.2.0 reuses the stale
    # tag commit (pre-migration) so the pipeline would resolve the
    # legacy /templates/pipeline.yml. Push mode rewrites the tag at
    # the latest source-tree commit and uses the current dynamic
    # template. Deploy coverage is provided by the node-deploy* family.
    "workflow-trunk-tag|node-workflow-trunk|v0.2.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||600|||workflow-trunk-main"
    "workflow-trunk-feature|node-workflow-trunk|branch:feature/test|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600|||workflow-trunk-tag"
    # --- Error scenarios (expect pipeline failure, with error pattern validation) ---
    # Note: error_pattern uses ~ as OR separator (converted to | at runtime)
    "error-build|node-error-build|main|brik-init||300|brik-build|||Build failed intentionally|brik-init"
    "error-test|node-error-test|main|brik-init,brik-build||300|brik-test|||FAIL~test.*failed|brik-init,brik-build"
    # brik-init is still the failing job: brik-plan in the parent succeeds
    # (the planner does not validate brik.yml schema, only the topology),
    # then the child pipeline reaches brik-init which calls config.read
    # and fails. The bridge-follow in gitlab-test.sh makes PIPELINE_ID
    # point at the child, so checking expect_failed_job=brik-init works.
    "error-config|invalid-config|main|||300|brik-init|||validat~invalid~schema|"
    "error-deploy|node-deploy-failure|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package||600|brik-deploy|BRIK_WITH_DEPLOY=true||brik-nonexistent~NotFound|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package"
    # --- CVE / "broken on purpose" fixtures (expect-fail) ---
    # These projects ship with deliberately defective state so the suite
    # proves brik catches the corresponding class of regression:
    # node-full-cve     : known-vulnerable transitive dep
    #                     (brace-expansion 5.0.5, GHSA-jxxr-4gwj-5jf2)
    #                     -> brik-scan exits non-zero.
    # node-complete-cve : same CVE + prettier format violations
    #                     -> brik-lint exits before brik-scan even runs.
    # Their generic-name counterparts (node-full, node-complete) carry
    # cleaned-up deps and prettier-formatted sources and pass end to end.
    "node-full-cve|node-full-cve|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast||600|brik-scan|BRIK_WITH_DEPLOY=true||GHSA|brik-init,brik-release,brik-build,brik-lint,brik-sast"
    "node-complete-cve|node-complete-cve|v0.1.0|brik-init,brik-release,brik-build||900|brik-lint|||format|brik-init,brik-release,brik-build"
    # --- Explicit mode/context coverage for the planner ---
    # Every project now includes /templates/dynamic-pipeline.yml, so
    # bridge-follow in gitlab-test.sh already exercises the parent+child
    # split for every scenario. These three keep dedicated mode and
    # tag-context coverage (balanced/safe and snapshot/release) so a
    # planner regression on one of those axes shows up as its own line
    # in the suite report rather than only as a cascading failure.
    "node-plan-balanced|node-plan-balanced|main|brik-init,brik-build,brik-lint,brik-test,brik-notify||900"
    "node-plan-safe|node-plan-safe|main|brik-init,brik-build,brik-lint,brik-test,brik-notify||900"
    "node-plan-tag|node-plan-tag|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-test,brik-notify||900"
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
    if [[ "$name" == workflow-* || "$ref" == branch:* ]]; then
        trigger_mode="push"
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
