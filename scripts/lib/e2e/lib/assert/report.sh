#!/usr/bin/env bash
# E2E Assertion Library -- Brik report & infra-state assertions.
#
# Builds on core.sh (sourced below). Two families:
#   1. Assertions that read a Brik aggregate-report.json (business outcomes,
#      package/promote, schema shape).
#   2. Assertions that delegate to a domain library (nexus/k8s/helm/argocd/
#      compose/ssh) and to host-side schema validation (SARIF, CycloneDX).
#
# The domain-delegating assertions call the e2e.<domain>.* predicate directly.
# A test that uses them has already sourced the matching domain lib; if it has
# not, bash fails loudly with "command not found" -- a clearer signal than the
# old "lib not loaded" soft assertion, which could only ever produce failures.

[[ -n "${_E2E_ASSERT_REPORT_LOADED:-}" ]] && return 0
_E2E_ASSERT_REPORT_LOADED=1

# shellcheck source=core.sh
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# ---------------------------------------------------------------------------
# Aggregate-report shape
# ---------------------------------------------------------------------------

# assert.aggregate_v1 <artifact_path> <expected_platform>
# Validates the shape of a Brik aggregate-report.json (v1.1).
assert.aggregate_v1() {
    local file="$1" expected_platform="$2"
    if [[ ! -f "$file" ]]; then
        assert._fail "Aggregate v1: file present (${file})" "not found"
        return
    fi
    assert.json_eq    "Aggregate schema_version is 1.1"          "$file" '.schema_version'                '"1.1"'
    assert.json_eq    "Aggregate pipeline.platform"               "$file" '.pipeline.platform'             "\"${expected_platform}\""
    assert.json_match "Aggregate pipeline.id non-empty"           "$file" '.pipeline.id'                   '^.+$'
    assert.json_match "Aggregate pipeline.business.status pass"   "$file" '.pipeline.business.status // ""' '^(success|warning)$'
    assert.json_ge    "Aggregate summary.stages.total >= 4"       "$file" '.summary.stages.total'          4
    local has_commit
    has_commit=$(jq -r '.pipeline | has("commit")' "$file" 2>/dev/null || echo "false")
    if [[ "$has_commit" == "true" ]]; then
        assert.json_match "Aggregate pipeline.commit.sha is 40-char hex" "$file" '.pipeline.commit.sha // ""' '^[a-f0-9]{40}$'
    fi
    assert.json_match "Aggregate stages[0].timestamp is ISO-8601" "$file" '.stages[0].timestamp // ""' '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
}

# ---------------------------------------------------------------------------
# Business outcome assertions (read from Brik aggregate-report.json)
# ---------------------------------------------------------------------------
# Four-category surface aligned on the runtime contract:
#   assert.passed   -- business.status == "success"
#   assert.failed   -- business.status == "error"
#   assert.warned   -- business.status == "warning"
#   assert.skipped  -- business.status absent OR business.reason == "not applicable"
#
# Each helper takes (<stage_name>, <aggregate_json_path>) and uses jq to
# read .stages[] | select(.stage == name) | .business.status.

assert._business_status() {
    local stage="$1" file="$2"
    [[ -f "$file" ]] || { echo "<file-missing>"; return; }
    jq -r --arg s "$stage" \
        '(.stages[]? | select(.stage == $s) | .business.status) // "<absent>"' \
        "$file" 2>/dev/null || echo "<jq-error>"
}

assert._business_reason() {
    local stage="$1" file="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    jq -r --arg s "$stage" \
        '(.stages[]? | select(.stage == $s) | .business.reason) // ""' \
        "$file" 2>/dev/null || echo ""
}

# assert.passed <stage> <aggregate_report_json>
assert.passed() {
    local stage="$1" file="$2"
    local actual; actual="$(assert._business_status "$stage" "$file")"
    if [[ "$actual" == "success" ]]; then
        assert._pass "Stage '${stage}' business.status=success"
    else
        assert._fail "Stage '${stage}' business.status=success" "got '${actual}'"
    fi
}

# assert.failed <stage> <aggregate_report_json>
assert.failed() {
    local stage="$1" file="$2"
    local actual; actual="$(assert._business_status "$stage" "$file")"
    if [[ "$actual" == "error" ]]; then
        assert._pass "Stage '${stage}' business.status=error"
    else
        assert._fail "Stage '${stage}' business.status=error" "got '${actual}'"
    fi
}

# assert.warned <stage> <aggregate_report_json>
assert.warned() {
    local stage="$1" file="$2"
    local actual; actual="$(assert._business_status "$stage" "$file")"
    if [[ "$actual" == "warning" ]]; then
        assert._pass "Stage '${stage}' business.status=warning"
    else
        assert._fail "Stage '${stage}' business.status=warning" "got '${actual}'"
    fi
}

# assert.skipped <stage> <aggregate_report_json>
# Matches both pipeline-skipped (no business.status recorded) and
# stage-self-skipped (business.status=success with reason="not applicable").
assert.skipped() {
    local stage="$1" file="$2"
    local actual; actual="$(assert._business_status "$stage" "$file")"
    local reason; reason="$(assert._business_reason "$stage" "$file")"
    if [[ "$actual" == "<absent>" ]] \
       || { [[ "$actual" == "success" ]] && [[ "$reason" == "not applicable" ]]; }; then
        assert._pass "Stage '${stage}' is skipped"
    else
        assert._fail "Stage '${stage}' is skipped" "business.status='${actual}' reason='${reason}'"
    fi
}

# ---------------------------------------------------------------------------
# Package stage image assertions
# ---------------------------------------------------------------------------

# assert.image_tag <aggregate_json_path> <expected_tag>
# Reads .stages[] | select(.stage == "package") | .business.image.tag from the
# aggregate report and compares it to expected. Catches the parity failure
# class where one platform tags with a release version while the other tags
# with a short SHA (see CHANGELOG: GitLab pipeline.env propagation fix).
assert.image_tag() {
    local file="$1" expected="$2"
    if [[ ! -f "$file" ]]; then
        assert._fail "Package image tag is '${expected}'" "aggregate file missing: ${file}"
        return
    fi
    local actual
    actual=$(jq -r '
        (.stages[]? | select(.stage == "package") | .business.image.tag) // "<absent>"
    ' "$file" 2>/dev/null || echo "<jq-error>")
    # When no docker image was packaged (project has no Dockerfile or its
    # package stage produced only npm/jar/wheel artifacts), .business.image.tag
    # is absent and the regression class this assertion targets (short SHA
    # vs release version on a docker image) cannot occur. Skip rather than
    # fail so non-docker tag-push scenarios stay green.
    if [[ "$actual" == "<absent>" ]]; then
        assert._pass "Package image tag check skipped (no docker image)"
        return
    fi
    if [[ "$actual" == "$expected" ]]; then
        assert._pass "Package image tag is '${expected}'"
    else
        assert._fail "Package image tag is '${expected}'" "got '${actual}'"
    fi
}

# assert.pipeline_source <aggregate_json_path> <expected_source>
# Reads .pipeline.pipeline_source from the aggregate report and compares it to
# the expected trigger source ("merge_request_event" for an MR/PR build,
# "push" for branch/tag pushes). This is the cross-platform, cross-git-host
# trigger-parity proof: brik records the SAME canonical source token whether
# the run was driven by GitLab CI (CI_PIPELINE_SOURCE) or Jenkins (CHANGE_ID),
# and regardless of whether the repo is backed by GitLab or Gitea. Reading it
# from the report (not job colors) keeps the assertion on business outcome.
assert.pipeline_source() {
    local file="$1" expected="$2"
    if [[ ! -f "$file" ]]; then
        assert._fail "Pipeline source is '${expected}'" "aggregate file missing: ${file}"
        return
    fi
    local actual
    actual=$(jq -r '.pipeline.pipeline_source // "<absent>"' "$file" 2>/dev/null || echo "<jq-error>")
    if [[ "$actual" == "$expected" ]]; then
        assert._pass "Pipeline source is '${expected}'"
    else
        assert._fail "Pipeline source is '${expected}'" "got '${actual}'"
    fi
}

# assert.promote_succeeded <aggregate_file>
# Verify the promote stage actually ran and recorded a successful
# candidate->release retag in THIS pipeline's report. Run-specific and
# stale-proof: fails if promote is absent (plan-skipped), not "success", or
# has no release_ref (the business key promote only sets after `docker push`
# returns 0). Preferred over a Nexus tag query, which can pass on a stale
# image left by a previous run.
assert.promote_succeeded() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        assert._fail "Promote stage succeeded (real retag)" "aggregate file missing: ${file}"
        return
    fi
    local status release_ref
    status=$(jq -r '(.stages[]? | select(.stage == "promote") | .status) // "<absent>"' "$file" 2>/dev/null || echo "<jq-error>")
    release_ref=$(jq -r '(.stages[]? | select(.stage == "promote") | .business.release_ref) // ""' "$file" 2>/dev/null || echo "")
    if [[ "$status" == "success" && -n "$release_ref" ]]; then
        assert._pass "Promote stage succeeded (release_ref=${release_ref})"
    else
        assert._fail "Promote stage succeeded (real retag)" "status='${status}' release_ref='${release_ref}' -- promote did not run/push (plan-skip?)"
    fi
}

# ---------------------------------------------------------------------------
# Artifact assertions (Nexus -- delegated to nexus.sh)
# ---------------------------------------------------------------------------

# assert.nexus_docker_exists <image_path>
assert.nexus_docker_exists() {
    local image_path="$1"
    if e2e.nexus.docker_image_exists "$image_path"; then
        assert._pass "Nexus Docker image exists: ${image_path}"
    else
        assert._fail "Nexus Docker image exists: ${image_path}" "not found"
    fi
}

# assert.nexus_docker_tagged <image_path> <tag>
assert.nexus_docker_tagged() {
    local image_path="$1" tag="$2"
    if e2e.nexus.docker_tag_exists "$image_path" "$tag"; then
        assert._pass "Nexus Docker tag exists: ${image_path}:${tag}"
    else
        assert._fail "Nexus Docker tag exists: ${image_path}:${tag}" "tag not found"
    fi
}

# assert.nexus_npm_published <package_name>
assert.nexus_npm_published() {
    local package_name="$1"
    if e2e.nexus.npm_package_exists "$package_name"; then
        assert._pass "Nexus npm package published: ${package_name}"
    else
        assert._fail "Nexus npm package published: ${package_name}" "not found"
    fi
}

# assert.nexus_maven_published <group_id> <artifact_id>
assert.nexus_maven_published() {
    local group_id="$1" artifact_id="$2"
    if e2e.nexus.maven_package_exists "$group_id" "$artifact_id"; then
        assert._pass "Nexus maven artifact published: ${group_id}:${artifact_id}"
    else
        assert._fail "Nexus maven artifact published: ${group_id}:${artifact_id}" "not found"
    fi
}

# assert.nexus_pypi_published <package_name>
assert.nexus_pypi_published() {
    local package_name="$1"
    if e2e.nexus.pypi_package_exists "$package_name"; then
        assert._pass "Nexus PyPI package published: ${package_name}"
    else
        assert._fail "Nexus PyPI package published: ${package_name}" "not found"
    fi
}

# assert.nexus_nuget_published <package_name>
assert.nexus_nuget_published() {
    local package_name="$1"
    if e2e.nexus.nuget_package_exists "$package_name"; then
        assert._pass "Nexus NuGet package published: ${package_name}"
    else
        assert._fail "Nexus NuGet package published: ${package_name}" "not found"
    fi
}

# ---------------------------------------------------------------------------
# Deploy state assertions (delegated to domain libs)
# ---------------------------------------------------------------------------

# Kubernetes
assert.k8s_deployment_ready() {
    local namespace="$1" name="$2"
    if e2e.k8s.deployment_ready "$namespace" "$name"; then
        assert._pass "K8s deployment ready: ${namespace}/${name}"
    else
        assert._fail "K8s deployment ready: ${namespace}/${name}" "not ready"
    fi
}

assert.k8s_deployment_image() {
    local namespace="$1" name="$2" expected="$3"
    local actual
    actual=$(e2e.k8s.get_deployment_image "$namespace" "$name")
    assert.equals "K8s deployment image: ${namespace}/${name}" "$expected" "$actual"
}

assert.k8s_pod_running() {
    local namespace="$1" label="$2"
    if e2e.k8s.pod_running "$namespace" "$label"; then
        assert._pass "K8s pod running: ${namespace} (${label})"
    else
        assert._fail "K8s pod running: ${namespace} (${label})" "no running pod"
    fi
}

# Helm
assert.helm_release_exists() {
    local namespace="$1" release="$2"
    if e2e.k8s.helm_release_exists "$namespace" "$release"; then
        assert._pass "Helm release exists: ${namespace}/${release}"
    else
        assert._fail "Helm release exists: ${namespace}/${release}" "not found"
    fi
}

assert.helm_release_status() {
    local namespace="$1" release="$2" expected="$3"
    local actual
    actual=$(e2e.k8s.helm_release_status "$namespace" "$release")
    assert.equals "Helm release status: ${namespace}/${release}" "$expected" "$actual"
}

# ArgoCD
assert.argocd_app_synced() {
    local app_name="$1"
    if e2e.argocd.app_synced "$app_name"; then
        assert._pass "ArgoCD app synced: ${app_name}"
    else
        assert._fail "ArgoCD app synced: ${app_name}" "not synced"
    fi
}

assert.argocd_app_healthy() {
    local app_name="$1"
    if e2e.argocd.app_healthy "$app_name"; then
        assert._pass "ArgoCD app healthy: ${app_name}"
    else
        assert._fail "ArgoCD app healthy: ${app_name}" "not healthy"
    fi
}

assert.argocd_app_image() {
    local app_name="$1" expected="$2"
    local actual
    actual=$(e2e.argocd.get_app_image "$app_name")
    assert.equals "ArgoCD app image: ${app_name}" "$expected" "$actual"
}

# Compose
assert.compose_container_running() {
    local container="$1"
    if e2e.compose.container_running "$container"; then
        assert._pass "Compose container running: ${container}"
    else
        assert._fail "Compose container running: ${container}" "not running"
    fi
}

assert.compose_container_image() {
    local container="$1" expected="$2"
    local actual
    actual=$(e2e.compose.get_container_image "$container")
    assert.equals "Compose container image: ${container}" "$expected" "$actual"
}

# SSH
assert.ssh_file_deployed() {
    local path="$1"
    if e2e.ssh.file_exists "$path"; then
        assert._pass "SSH file deployed: ${path}"
    else
        assert._fail "SSH file deployed: ${path}" "not found"
    fi
}

assert.ssh_process_running() {
    local process="$1"
    if e2e.ssh.process_running "$process"; then
        assert._pass "SSH process running: ${process}"
    else
        assert._fail "SSH process running: ${process}" "not running"
    fi
}

# ---------------------------------------------------------------------------
# Pipeline-report L4 artifact assertions
# ---------------------------------------------------------------------------
# Validate SARIF and CycloneDX outputs produced by the lint, sast, and scan
# stages. Each takes a local file path (extracted from a downloaded
# artifacts.zip) and a label used in the assertion line.

# Locate the directory where Brik bundles the official schemas (committed
# in Phase 0). When BRIK_HOME is unset, fall back to the checkout path
# alongside briklab.
assert._l4_schema_dir() {
    local _candidates=(
        "${BRIK_HOME:-}/schemas/external"
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." 2>/dev/null && pwd)/brik/schemas/external"
    )
    local _d
    for _d in "${_candidates[@]}"; do
        [[ -n "$_d" && -d "$_d" ]] && { printf '%s\n' "$_d"; return 0; }
    done
    return 1
}

assert.artifact_present() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        assert._pass "Artifact present: ${label}"
    else
        assert._fail "Artifact present: ${label}" "missing at ${path}"
    fi
}

assert.artifact_is_valid_sarif() {
    local label="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        assert._fail "Valid SARIF: ${label}" "file missing at ${path}"
        return
    fi
    if ! command -v jv >/dev/null 2>&1; then
        assert._fail "Valid SARIF: ${label}" "jv binary not available on host"
        return
    fi
    local schema_dir
    if ! schema_dir="$(assert._l4_schema_dir)"; then
        assert._fail "Valid SARIF: ${label}" "schemas/external/ not found"
        return
    fi
    if jv "${schema_dir}/sarif-2.1.0.json" "$path" >/dev/null 2>&1; then
        assert._pass "Valid SARIF: ${label}"
    else
        assert._fail "Valid SARIF: ${label}" "schema validation failed"
    fi
}

assert.artifact_is_valid_cyclonedx() {
    local label="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        assert._fail "Valid CycloneDX 1.5: ${label}" "file missing at ${path}"
        return
    fi
    if ! command -v jv >/dev/null 2>&1; then
        assert._fail "Valid CycloneDX 1.5: ${label}" "jv binary not available on host"
        return
    fi
    local schema_dir
    if ! schema_dir="$(assert._l4_schema_dir)"; then
        assert._fail "Valid CycloneDX 1.5: ${label}" "schemas/external/ not found"
        return
    fi
    if jv "${schema_dir}/cyclonedx-1.5.schema.json" "$path" >/dev/null 2>&1; then
        assert._pass "Valid CycloneDX 1.5: ${label}"
    else
        assert._fail "Valid CycloneDX 1.5: ${label}" "schema validation failed"
    fi
}
