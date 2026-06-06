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
# shellcheck source=lib/scenario.sh
source "${SCRIPT_DIR}/lib/scenario.sh"
reload_env

# ---------------------------------------------------------------------------
# Scenario definitions
# Format: name|jenkins_job|projects_to_push|timeout|expect_failure|ci_vars|depends_on|error_pattern
# ---------------------------------------------------------------------------
SCENARIOS=(
    # Per-stage, per-stack, planner and findings behavior is covered by the
    # brik repo's contract, unit and integration suites. The Jenkins suite
    # keeps end-to-end scenarios for orchestrator parity with GitLab. The
    # Jenkins adapter (brikPipeline.groovy) runs each stage in an isolated
    # docker.image().inside() container on the same Alpine brik-runner images
    # as GitLab, so the deploy / promote / gitops / CVE-gating paths must be
    # exercised here too -- that is where the v0.6.x execution-model bugs
    # (#25 namespace leak, #26 profile mktemp, #27 promote auth) lived.
    #   - node-full: full release + package happy path (orchestrator parity).
    #     It has no deploy config; the deploy stage only runs as a no-op when
    #     BRIK_WITH_DEPLOY=true, proving stage wiring, NOT a real deploy. Real
    #     deploy coverage is node-deploy-gitops.
    #   - node-complete: full release + package + real Nexus publish, no deploy.
    "node-full|node-full|node-full|600|false"
    "node-complete|node-complete|node-complete|600|false"
    # Real GitOps / ArgoCD sync. node-deploy-gitops is a pipelineJob building
    # */main, so it runs in BRANCH context (BRIK_BRANCH=main). It must NOT get
    # a BRIK_TAG: the trunk-based staging env is gated on `when: branch=='main'`
    # and a tag build would skip it (running the inherited production k8s env
    # instead). The dispatch (a) excludes it from the brik_tag case and (b)
    # injects BRIK_WITH_DEPLOY=true + BRIK_WITH_PACKAGE=true (the published
    # image must exist for the ArgoCD sync). Post-build ArgoCD sync is asserted
    # in _suite_run_scenario via the shared e2e.argocd.assert_synced helper.
    "node-deploy-gitops|node-deploy-gitops|node-deploy-gitops|900|false"
    # Real GitOps rollback. Self-contained in jenkins-rollback.sh (pushes its
    # own v0.1.0 baseline + v0.2.0, manages config-deploy-rollback and the
    # brik-e2e-rollback ArgoCD app). depends_on node-deploy-gitops mirrors the
    # GitLab suite (ordering parity on the shared k8s/argocd infra).
    "node-deploy-rollback|node-deploy-gitops-rollback|node-deploy-gitops-rollback|900|false||node-deploy-gitops"
    # Live promote coverage (#27). Tagged build (BRIK_TAG=v0.1.0 via dispatch)
    # runs release + package + a real candidate->release docker retag. The
    # brik.yml is in `safe` planner mode so promote is not impact-skipped.
    # E2E_ASSERT_PROMOTE=true (set in _suite_run_scenario) makes jenkins-test.sh
    # assert the promote stage really retagged in THIS build's aggregate-report.
    "node-plan-tag|node-plan-tag|node-plan-tag|600|false"
    # Live CVE-gating: a known-vulnerable dep must FAIL brik-scan (expect
    # failure + GHSA advisory id in the console). Mirrors GitLab. Needs a
    # dedicated CasC pipelineJob (node-full-cve).
    "node-full-cve|node-full-cve|node-full-cve|600|true|BRIK_WITH_DEPLOY=true||GHSA"
    # Trunk-based triggering parity. The GitLab counterpart asserts the
    # pipeline.yml `workflow:` rules (GitLab-specific); the Jenkins equivalent
    # is the Multibranch scan firing a build on the default branch and on a tag
    # -- same intent (trunk-based), different mechanism. Push-driven (dispatch
    # sets trigger_mode=push); the tag variant pushes v0.2.0 (release context).
    "workflow-trunk-main|node-workflow-trunk|node-workflow-trunk|600|false"
    "workflow-trunk-tag|node-workflow-trunk|node-workflow-trunk|600|false||workflow-trunk-main"
    # Pull-request trigger parity (Jenkins+Gitea native combo). Pushes a source
    # branch and opens a Gitea pull request; giteaPullRequestDiscovery indexes it
    # as a PR-<n> sub-job and auto-builds it, with CHANGE_ID set -- so brik
    # records pipeline_source=merge_request_event. _suite_run_scenario sets
    # trigger_mode=mr and E2E_EXPECT_PIPELINE_SOURCE=merge_request_event.
    # Sequenced after workflow-trunk-tag (shared multibranch job).
    "workflow-trunk-mr|node-workflow-trunk|node-workflow-trunk|600|false||workflow-trunk-tag"
    # The stub-image variant is no longer a dedicated row: run any scenario
    # with `briklab.sh test --jenkins --stub` to pin every stage to the single
    # brik-runner-stub image (BRIK_RUNNER_CLASSES_FILE injected by
    # _suite_run_scenario). --stub only swaps the image fleet; unlike the
    # former node-full-stub it does NOT force BRIK_WITH_DEPLOY (Jenkins gates
    # deploy via a build parameter), so the deploy stage runs only when the
    # scenario already enables it.
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
        *-complete)          echo "C" ;;
        *-full)              echo "B" ;;
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
    local _test_rc=0
    IFS='|' read -r name job _projects timeout expect_fail ci_vars _depends_on error_pattern <<< "$scenario"

    # Stub mode (briklab.sh test --stub): pin every stage to the stub image.
    # The path is RELATIVE to the brik library root -- Jenkins checks the shared
    # lib into a hash-named ${WORKSPACE}@libs/<hash>/ dir and brikRunStage
    # resolves it against brikHome per stage container.
    if [[ "${E2E_STUB:-}" == "true" ]]; then
        ci_vars="${ci_vars:+${ci_vars},}BRIK_RUNNER_CLASSES_FILE=lib/registry/runner_classes.stub.yml"
    fi

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

    # Per-scenario pre-cleanup: ensure the ArgoCD port-forward is up before a
    # gitops/rollback scenario (dead host-side port-forward causes false fails).
    if e2e.scenario.needs_deploy "$name"; then
        e2e.argocd.ensure_port_forward || \
            log_warn "ArgoCD port-forward could not be established -- gitops scenario may fail"
    fi

    # Multi-step rollback scenario: delegate to dedicated script
    if [[ "$name" == "node-deploy-rollback" ]]; then
        E2E_JENKINS_TIMEOUT="${timeout:-900}" bash "${SCRIPT_DIR}/jenkins-rollback.sh"
        return $?
    fi

    # Auto-detect push mode for workflow scenarios; *-mr opens a real pull
    # request instead (must win over workflow-* -- workflow-trunk-mr matches both).
    local trigger_mode="${E2E_TRIGGER_MODE:-api}"
    if [[ "$name" == workflow-* ]]; then
        trigger_mode="push"
    fi
    if [[ "$name" == *-mr ]]; then
        trigger_mode="mr"
    fi

    # Expected trigger source brik must record in the aggregate report, for
    # cross-host trigger parity. Set only for real git-event scenarios; API
    # scenarios leave it empty so scenario.sh's opt-in assertion stays off.
    local expect_source=""
    case "$name" in
        *-mr)                                   expect_source="merge_request_event" ;;
        workflow-trunk-main|workflow-trunk-tag) expect_source="push" ;;
    esac

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
        # node-deploy-gitops MUST stay in branch context (no tag) so its
        # `when: branch=='main'` staging gitops env runs -- see the SCENARIOS
        # comment. It matches node-deploy* below, so catch it first and leave
        # brik_tag empty.
        node-deploy-gitops) ;;
        *-full|*-complete|node-deploy*|error-deploy|node-plan-tag|node-full-cve)
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

    # Deploy is opt-in in brik's planner: tag-context pipelines run release +
    # package but skip deploy unless BRIK_WITH_DEPLOY=true is asserted. node-
    # deploy*, node-deploy-rollback (handled in jenkins-rollback.sh), and
    # error-deploy (whose whole point is for brik-deploy to fail on a missing
    # kustomize app) all need deploy to actually run. Without this, the deploy
    # stage is silently skipped and the pipeline ends in success, masking the
    # tested behavior.
    case "$name" in
        node-deploy-gitops)
            # Branch-context gitops also needs the package published so the
            # ArgoCD sync has a real image to pull (mirrors the GitLab row).
            ci_vars="${ci_vars:+${ci_vars},}BRIK_WITH_DEPLOY=true,BRIK_WITH_PACKAGE=true"
            ;;
        node-deploy*|error-deploy)
            ci_vars="${ci_vars:+${ci_vars},}BRIK_WITH_DEPLOY=true"
            ;;
    esac

    # node-workflow-trunk is a multibranch Jenkins job backed by gitea-plugin;
    # builds live under job/<name>/job/<branch>/... The api helpers pick up
    # E2E_JENKINS_BRANCH to build the correct URL prefix. Multibranch scan +
    # branch job creation + queue on first push can exceed the default 90s
    # discovery window, so bump it to 180s for these scenarios.
    local branch=""
    local discover_timeout=""
    if [[ "$job" == "node-workflow-trunk" ]]; then
        # In mr mode jenkins-test.sh sets E2E_JENKINS_BRANCH=PR-<n> itself, so
        # leave branch empty here; only bump the discovery window (PR index +
        # sub-job creation + first build can exceed the default).
        [[ "$trigger_mode" != "mr" ]] && branch="main"
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
    E2E_EXPECT_PIPELINE_SOURCE="$expect_source" \
    E2E_ASSERT_PROMOTE="$([[ "$name" == "node-plan-tag" ]] && echo true || echo false)" \
    E2E_EXPECTED_ERROR_PATTERN="${error_pattern//\~/$'|'}" \
        bash "${SCRIPT_DIR}/jenkins-test.sh" && _test_rc=0 || _test_rc=$?

    # A green gitops build proves job status, not that ArgoCD synced. Assert it
    # (parity with the GitLab suite; shared helper in lib/argocd.sh).
    if [[ "$_test_rc" -eq 0 ]]; then
        e2e.scenario.gitops_postcheck "$name" "brik-e2e-gitops" || _test_rc=1
    fi
    return "$_test_rc"
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
