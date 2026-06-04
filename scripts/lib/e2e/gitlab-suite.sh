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
    # a live orchestrator or real infrastructure remain here:
    #   - node-full: end-to-end happy path on GitLab (orchestrator parity). It
    #     has no deploy config, so brik-deploy runs as a no-op success: this
    #     proves the deploy stage is wired into the orchestrator, NOT that a
    #     real deployment works. Real deploy coverage is node-deploy-gitops.
    #   - node-deploy-gitops: real ArgoCD / GitOps sync.
    #   - node-deploy-rollback: real GitOps rollback (depends on the gitops run).
    #   - node-plan-tag / node-full-cve / workflow-trunk-*: live coverage for the
    #     promote / scan-CVE / workflow-filter gaps (see docs/e2e-coverage.md).
    "node-full|node-full|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||600||BRIK_WITH_DEPLOY=true"
    # The stub-image variant is no longer a dedicated row: run any scenario
    # with `briklab.sh test --gitlab --stub` to pin every stage to the single
    # brik-runner-stub image (BRIK_RUNNER_CLASSES_FILE injected by
    # _suite_run_scenario). `test --gitlab --project node-full --stub`
    # reproduces the former node-full-stub exactly.
    # Triggered on `branch:main` (NOT a tag): the trunk-based profile gates the
    # gitops `staging` env on `when: branch=='main'`, so only a main-branch
    # pipeline actually exercises the gitops/ArgoCD path. On a tag, staging is
    # skipped and the inherited `production` (target k8s) runs instead -- which
    # is why the former tag-based row never tested gitops. brik-release is absent
    # (no tag); package is opted in explicitly so the published image exists for
    # the ArgoCD sync. The post-pipeline ArgoCD assertion lives in
    # _suite_run_scenario (see _suite_assert_gitops_sync).
    "node-deploy-gitops|node-deploy-gitops|branch:main|brik-init,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-deploy,brik-notify||900||BRIK_WITH_DEPLOY=true,BRIK_WITH_PACKAGE=true"
    "node-deploy-rollback|node-deploy-gitops-rollback|v0.1.0|||900|||node-deploy-gitops"
    # Gap-coverage scenarios (kept after the consolidation because brik/spec
    # cannot prove the live orchestrator behaviour) -- see docs/e2e-coverage.md:
    #   - node-plan-tag: tagged commit runs the planner inline AND exercises a
    #     real candidate->release docker promote. package publishes the
    #     candidate image, then on the tag brik-promote pulls/retags/pushes it
    #     to the release zone. The post-pipeline assertion checks the release
    #     image landed in Nexus (_suite_assert_promote_retag), so a self-skipping
    #     or no-op promote can no longer pass.
    #   - node-full-cve: a CVE in deps must FAIL brik-scan (live gating proof).
    #   - workflow-trunk-{main,tag}: trunk-based `workflow:` filter -- the default
    #     branch and a tag must each create a pipeline. A bare feature-branch push
    #     is intentionally suppressed by the anti-duplicate push+MR rule (no
    #     pipeline), so it has no live scenario (the framework cannot assert the
    #     ABSENCE of a pipeline); the rule itself is unit-tested in brik/spec
    #     (gitlab_pipeline_template_spec.sh).
    "node-plan-tag|node-plan-tag|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast,brik-scan,brik-test,brik-package,brik-promote,brik-notify||600"
    "node-full-cve|node-full-cve|v0.1.0|brik-init,brik-release,brik-build,brik-lint,brik-sast||600|brik-scan|BRIK_WITH_DEPLOY=true||GHSA|brik-init,brik-release,brik-build,brik-lint,brik-sast"
    "workflow-trunk-main|node-workflow-trunk|main|brik-init,brik-build,brik-test,brik-deploy,brik-notify||600"
    "workflow-trunk-tag|node-workflow-trunk|v0.2.0|brik-init,brik-release,brik-build,brik-test,brik-package,brik-deploy,brik-notify||600|||workflow-trunk-main"
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
        *-cve)               echo "D" ;;   # scan/CVE gating
        *-deploy-gitops|*-deploy-rollback) echo "F" ;;
        workflow-*)          echo "G" ;;
        node-plan-*)         echo "I" ;;
        *-full)              echo "B" ;;
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
    local _test_rc=0
    IFS='|' read -r name project ref required _optional timeout expect_fail ci_vars _depends_on error_pattern success_jobs <<< "$scenario"

    # Stub mode (briklab.sh test --stub): pin every stage to the stub image by
    # injecting the runner_classes override into this scenario's CI variables.
    # The path is absolute -- it is where brik is installed inside the runner
    # image (/opt/brik). init still boots on its default base image, then emits
    # the stub image map via its dotenv.
    if [[ "${E2E_STUB:-}" == "true" ]]; then
        ci_vars="${ci_vars:+${ci_vars},}BRIK_RUNNER_CLASSES_FILE=/opt/brik/lib/registry/runner_classes.stub.yml"
    fi

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

    # Per-scenario pre-cleanup: ensure the ArgoCD port-forward is up before a
    # gitops/rollback scenario (dead host-side port-forward causes false fails).
    case "$name" in
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
    E2E_ASSERT_PROMOTE="$([[ "$name" == "node-plan-tag" ]] && echo true || echo false)" \
        bash "${SCRIPT_DIR}/gitlab-test.sh" && _test_rc=0 || _test_rc=$?

    # A green pipeline is necessary but NOT sufficient for a gitops scenario:
    # gitlab-test.sh checks job status, not the ArgoCD controller. Without this
    # a skipped or no-op gitops deploy would pass unnoticed (the coverage gap
    # that hid the --namespace bug). Assert the app actually reached Synced +
    # Healthy after the pipeline succeeds.
    if [[ "$_test_rc" -eq 0 && "$name" == *-deploy-gitops ]]; then
        _suite_assert_gitops_sync "brik-e2e-gitops" || _test_rc=1
    fi
    return "$_test_rc"
}

# Assert that the ArgoCD app driven by a *-deploy-gitops scenario actually
# synced the rendered manifests. A green pipeline alone does not prove the
# gitops path ran. Args: $1 = ArgoCD app name. Returns: 0 if Synced+Healthy.
_suite_assert_gitops_sync() {
    # Thin wrapper over the shared assertion (lib/argocd.sh), kept so the
    # dispatch reads naturally; the Jenkins suite calls e2e.argocd.assert_synced
    # directly.
    e2e.argocd.assert_synced "$1"
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
