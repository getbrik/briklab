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
    else
        log_warn "could not download aggregate-report.json (skipping aggregate assertions)"
    fi
    rm -rf "$agg_tmp"
}
