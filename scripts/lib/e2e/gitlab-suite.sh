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
    # --- Minimal stack coverage (branch push: no release, no package) ---
    # NOTE: node-minimal has no .deploy block; required_jobs still lists brik-deploy here
    # because P0 gating is not yet live. Once chantier/commit-context-and-orchestrator-gating
    # is published on briklab, drop brik-deploy from node-minimal's required_jobs list.
    "node-minimal|node-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||900"
    "python-minimal|python-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||900"
    "java-minimal|java-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "rust-minimal|rust-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "dotnet-minimal|dotnet-minimal|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    # --- Full pipelines (tag push: all stages) ---
    "node-full|node-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-test,brik-package,brik-deploy,brik-notify||600"
    "python-full|python-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600"
    "java-full|java-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-test,brik-package,brik-deploy,brik-notify||600"
    # --- Security and Deploy ---
    "node-security|node-security|main|brik-init,brik-build,brik-sast,brik-scan,brik-test,brik-deploy,brik-notify||300"
    "node-deploy|node-deploy|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-dryrun|node-deploy|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_DRY_RUN=true"
    "node-deploy-k8s|node-deploy-k8s|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-ssh|node-deploy-ssh|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-helm|node-deploy-helm|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600"
    "node-deploy-gitops|node-deploy-gitops|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||900"
    "node-deploy-rollback|node-deploy-gitops-rollback|v0.1.0|||900|||node-deploy-gitops"
    # --- Complete pipelines with Nexus publish (tag push: all stages + publish) ---
    "node-complete|node-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "python-complete|python-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "java-complete|java-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "rust-complete|rust-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    "dotnet-complete|dotnet-complete|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-notify||900"
    # --- Workflow scenarios (push-driven, sequential) ---
    "workflow-trunk-main|node-workflow-trunk|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "workflow-trunk-tag|node-workflow-trunk|v0.2.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600|||workflow-trunk-main"
    "workflow-trunk-feature|node-workflow-trunk|branch:feature/test|brik-init,brik-build,brik-test,brik-notify||600|||workflow-trunk-tag"
    # --- Orchestrator gating: no-package / no-deploy (P0) + commit-context (P2) ---
    # PREREQUISITE: all 4 scenarios below require the chantier branch to be available
    # as a Git ref on briklab's local GitLab:
    #   brik/gitlab-templates@chantier/commit-context-and-orchestrator-gating
    # Until that ref is published, these scenarios will fail at template-include time.
    # Run them individually once the ref is live:
    #   briklab.sh test --only node-no-package
    #   briklab.sh test --only node-no-deploy
    #   briklab.sh test --only commit-docs-only
    #   briklab.sh test --only commit-lock-only
    #
    # node-no-package: project with lint/sast/scan but no .package block.
    # brik-package and brik-container-scan must NOT appear in the instantiated pipeline (P0 rules:).
    "node-no-package|node-no-package|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600"
    # node-no-deploy: project with lint/sast/scan but no .package and no .deploy block.
    # brik-package, brik-container-scan, and brik-deploy must NOT appear (P0 rules:).
    "node-no-deploy|node-no-deploy|main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-notify||600"
    # commit-docs-only: two-step scenario -- baseline push then a docs-only delta.
    # BRIK_COMMIT_CONTEXT=docs-only must be detected by init (P1).
    # Only brik-init, brik-lint, brik-notify must be instantiated (P2 matrix row: docs-only).
    # Step 2 triggers on branch:docs-only-delta; the push helper must land a commit
    # touching only docs/README.md before triggering the assertion pipeline.
    # TODO: implement two-step push in gitlab-test.sh or a dedicated gitlab-commit-context.sh
    # (sketched only -- not executable until P1+P2 are merged and ref is published).
    "commit-docs-only|node-commit-context|branch:docs-only-delta|brik-init,brik-lint,brik-notify||600"
    # commit-lock-only: two-step scenario -- baseline push then a lock-only delta.
    # BRIK_COMMIT_CONTEXT=lock-only must be detected by init (P1).
    # Only brik-init, brik-build, brik-scan, brik-test, brik-notify must be instantiated
    # (P2 matrix row: lock-only -- no lint, no sast, no package/deploy).
    # Step 2 triggers on branch:lock-only-delta; push helper must touch only package-lock.json.
    # TODO: same two-step push infrastructure as commit-docs-only.
    "commit-lock-only|node-commit-context|branch:lock-only-delta|brik-init,brik-build,brik-scan,brik-test,brik-notify||600"
    # --- Error scenarios (expect pipeline failure, with error pattern validation) ---
    # Note: error_pattern uses ~ as OR separator (converted to | at runtime)
    "error-build|node-error-build|main|brik-init||300|brik-build|||Build failed intentionally|brik-init"
    "error-test|node-error-test|main|brik-init,brik-build||300|brik-test|||FAIL~test.*failed|brik-init,brik-build"
    "error-config|invalid-config|main|||300|brik-init|||validat~invalid~schema|"
    "error-deploy|node-deploy-failure|v0.1.0|brik-init,brik-release,brik-build,brik-test,brik-package||600|brik-deploy|||brik-nonexistent~NotFound|brik-init,brik-release,brik-build,brik-test,brik-package"
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
#   I: orchestrator gating (no-package, no-deploy, commit-context)
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
        *-no-*|commit-*)     echo "I" ;;
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
