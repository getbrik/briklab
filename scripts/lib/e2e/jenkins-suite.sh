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
# shellcheck source=lib/compose.sh
source "${SCRIPT_DIR}/lib/compose.sh"
# shellcheck source=lib/nexus.sh
source "${SCRIPT_DIR}/lib/nexus.sh"
# shellcheck source=lib/argocd.sh
source "${SCRIPT_DIR}/lib/argocd.sh"
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
    # --- Workflow scenarios (push-driven, sequential) ---
    "workflow-trunk-main|node-workflow-trunk|node-workflow-trunk|600|false"
    "workflow-trunk-tag|node-workflow-trunk|node-workflow-trunk|600|false||workflow-trunk-main"
    "workflow-trunk-feature|node-workflow-trunk|node-workflow-trunk|600|false||workflow-trunk-tag"
    # --- Error scenarios ---
    # Note: error_pattern uses ~ as OR separator (converted to | at runtime)
    "error-build|node-error-build|node-error-build|300|true|||Build failed intentionally"
    "error-test|node-error-test|node-error-test|300|true|||FAIL~test.*failed"
    "error-config|invalid-config|invalid-config|300|true|||validat~invalid~schema"
    "error-deploy|node-deploy-failure|node-deploy-failure|600|true|||brik-nonexistent~NotFound"
)

# ---------------------------------------------------------------------------
# Callbacks for suite.sh
# ---------------------------------------------------------------------------

_suite_get_name() { IFS='|' read -r name _ <<< "$1"; echo "$name"; }
_suite_get_project() { IFS='|' read -r _ _ projects _ <<< "$1"; echo "$projects"; }
# Adding a trailing `_` after `dep` is critical: bash's `read` slurps
# every remaining field into the last variable. Without the extra
# absorber the 8-field scenario "...||depends|error_pattern" was being
# parsed as depends_on="" + "|" + error_pattern, which then never matched
# any passed scenario name and SKIPped every dependent test in --all.
_suite_get_depends_on() { IFS='|' read -r _ _ _ _ _ _ dep _ <<< "$1"; echo "${dep:-}"; }

# Group mapping (same scheme as gitlab-suite.sh)
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
        E2E_JENKINS_TIMEOUT="${timeout:-900}" bash "${SCRIPT_DIR}/jenkins-rollback.sh"
        return $?
    fi

    # Auto-detect push mode for workflow scenarios
    local trigger_mode="${E2E_TRIGGER_MODE:-api}"
    if [[ "$name" == workflow-* ]]; then
        trigger_mode="push"
    fi

    # Mirror GitLab's tag-trigger semantics on Jenkins. The gitlab-suite
    # counterpart of these scenarios triggers on ref v0.1.0 (or v0.2.0
    # for workflow-trunk-tag), which gives the pipeline CI_COMMIT_TAG and
    # routes brik into release context. Jenkins pipelineJobs always build
    # the configured branch, so we signal the tag explicitly via the
    # BRIK_TAG build parameter declared in brikPipeline.groovy. Without
    # this, *-full / *-complete / node-deploy* scenarios would skip the
    # release stage and tag images with the short SHA instead of the
    # release tag -- breaking parity with GitLab.
    local brik_tag=""
    case "$name" in
        *-full|*-complete|node-deploy*|error-deploy)
            brik_tag="v0.1.0"
            ;;
    esac
    if [[ -n "$brik_tag" ]]; then
        if [[ -n "${ci_vars:-}" ]]; then
            ci_vars="${ci_vars},BRIK_TAG=${brik_tag}"
        else
            ci_vars="BRIK_TAG=${brik_tag}"
        fi
    fi

    # node-workflow-trunk is a multibranch Jenkins job backed by gitea-plugin;
    # builds live under job/<name>/job/<branch>/... The api helpers pick up
    # E2E_JENKINS_BRANCH to build the correct URL prefix. Multibranch scan +
    # branch job creation + queue on first push can exceed the default 90s
    # discovery window, so bump it to 180s for these scenarios.
    local branch=""
    local discover_timeout=""
    if [[ "$job" == "node-workflow-trunk" ]]; then
        branch="main"
        discover_timeout="300"
    fi

    # Trigger ref selection for push-mode scenarios. GitLab's counterpart
    # uses a per-scenario trigger_ref column (main / v0.2.0 / branch:feat).
    # On Jenkins the test script defaulted to "main" for every push, which
    # made workflow-trunk-tag behave like a branch push (snapshot context)
    # instead of a tag push (release context) -- breaking parity. Derive
    # the ref from the scenario name so each workflow variant pushes the
    # right git reference and Multibranch routes to the right build kind.
    # API-mode scenarios that inject BRIK_TAG also export the matching
    # trigger_ref so test-side assertions (e.g. assert.image_tag) treat
    # the build as a release-context tag push, mirroring GitLab.
    local trigger_ref=""
    case "$name" in
        workflow-trunk-tag)     trigger_ref="v0.2.0" ;;
        workflow-trunk-feature) trigger_ref="branch:feature/test" ;;
    esac
    if [[ -z "$trigger_ref" && -n "$brik_tag" ]]; then
        trigger_ref="$brik_tag"
    fi

    E2E_JENKINS_JOB="$job" \
    E2E_JENKINS_TIMEOUT="$timeout" \
    E2E_JENKINS_EXPECT_FAILURE="$expect_fail" \
    E2E_CI_VARIABLES="${ci_vars:-}" \
    E2E_TRIGGER_MODE="$trigger_mode" \
    E2E_TRIGGER_REF="$trigger_ref" \
    E2E_JENKINS_BRANCH="$branch" \
    E2E_JENKINS_DISCOVER_TIMEOUT="$discover_timeout" \
    E2E_EXPECTED_ERROR_PATTERN="${error_pattern//\~/$'|'}" \
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
