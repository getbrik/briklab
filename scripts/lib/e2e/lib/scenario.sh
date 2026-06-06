#!/usr/bin/env bash
# E2E scenario helpers shared by the platform test scripts.
#
# Holds the platform-agnostic tail of an E2E run (aggregate-report validation)
# so gitlab-test.sh and jenkins-test.sh do not duplicate it. Platform-specific
# steps (run-id discovery, trigger/wait) stay in the test scripts.
#
# Depends on: common.sh, lib/assert.sh

[[ -n "${_E2E_SCENARIO_LOADED:-}" ]] && return 0
_E2E_SCENARIO_LOADED=1

_E2E_SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=assert.sh
source "${_E2E_SCENARIO_DIR}/assert.sh"

# ---------------------------------------------------------------------------
# Scenario classification (single source of the deploy/gitops taxonomy, so the
# CLI test command and the suites do not each hardcode the naming globs).
# ---------------------------------------------------------------------------

# True if the scenario exercises a real deployment (deploy / gitops / rollback).
# The preflight then enforces --with-deploy (cluster + ArgoCD checks become
# blocking) and the suite ensures the ArgoCD port-forward beforehand.
# Args: $1 = scenario or project name.
e2e.scenario.needs_deploy() {
    case "$1" in
        *deploy*|*gitops*|*rollback*) return 0 ;;
        *) return 1 ;;
    esac
}

# True if the scenario drives a GitOps/ArgoCD sync that must be asserted after a
# green run (a green pipeline alone does not prove the controller synced).
# Args: $1 = scenario name.
e2e.scenario.is_gitops() {
    case "$1" in
        *-deploy-gitops) return 0 ;;
        *) return 1 ;;
    esac
}

# Post-run gitops check: for a *-deploy-gitops scenario, assert the ArgoCD app
# actually reached Synced + Healthy. A green pipeline alone does not prove the
# gitops path ran (the coverage gap that hid the --namespace bug). No-op (0) for
# non-gitops scenarios. Args: $1 = scenario name, $2 = ArgoCD app name.
e2e.scenario.gitops_postcheck() {
    local name="$1" app="$2"
    e2e.scenario.is_gitops "$name" || return 0
    e2e.argocd.assert_synced "$app"
}

# Download the notify-stage aggregate-report.json and run the standard v1
# aggregate assertions on it. The download itself is platform-specific, so the
# caller passes the download command plus its run-id arguments; this helper
# appends the artifact path and a temp destination, then cleans up.
#
# Args:
#   $1     platform (gitlab|jenkins) -- passed through to assert.aggregate_v1
#   $2     trigger ref (e.g. "main", "v0.1.0")
#   $3     assert promote? ("true"/"false")
#   $4..   download command + its leading args, e.g.
#          e2e.gitlab.download_artifact <project_id> <notify_job_id>
#          e2e.jenkins.download_artifact <job_name> <build_number>
e2e.scenario.assert_aggregate() {
    local platform="$1" trigger_ref="$2" assert_promote="$3"
    shift 3
    local -a download_cmd=("$@")

    local agg_tmp agg_file
    agg_tmp="$(mktemp -d)"
    agg_file="${agg_tmp}/aggregate-report.json"

    if "${download_cmd[@]}" "brik-artifacts/aggregate-report.json" "$agg_file" 2>/dev/null; then
        assert.aggregate_v1 "$agg_file" "$platform"
        # On a release ref (v<N>...), assert the package image tag mirrors the
        # release version. Catches the pipeline.env regression class where
        # BRIK_APP_VERSION is dropped and package falls back to the short SHA.
        if [[ "$trigger_ref" =~ ^v[0-9] ]]; then
            assert.image_tag "$agg_file" "${trigger_ref#v}"
        fi
        # Opt-in: assert the promote stage really recorded a candidate->release
        # retag in THIS run's report (run-specific, stale-proof).
        if [[ "$assert_promote" == "true" ]]; then
            assert.promote_succeeded "$agg_file"
        fi
        # Opt-in: assert the trigger source brik recorded matches what the
        # scenario expected (merge_request_event for MR/PR scenarios, push for
        # push/tag scenarios that exercise real git pushes). Cross-platform,
        # cross-git-host trigger parity -- see assert.pipeline_source. Kept
        # opt-in so API-triggered scenarios (source=api) stay unaffected.
        if [[ -n "${E2E_EXPECT_PIPELINE_SOURCE:-}" ]]; then
            assert.pipeline_source "$agg_file" "$E2E_EXPECT_PIPELINE_SOURCE"
        fi
    else
        log_warn "could not download aggregate-report.json (skipping aggregate assertions)"
    fi
    rm -rf "$agg_tmp"
}
