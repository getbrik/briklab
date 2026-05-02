#!/usr/bin/env bash
# E2E Jenkins API Library
#
# Reusable functions for interacting with the Jenkins API.
# Extracted from jenkins-test.sh.
#
# Prerequisites:
#   - JENKINS_ADMIN_PASSWORD must be set (via .env)
#   - JENKINS_HOSTNAME / JENKINS_HTTP_PORT for non-default URLs

[[ -n "${_E2E_JENKINS_API_LOADED:-}" ]] && return 0
_E2E_JENKINS_API_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_E2E_JENKINS_URL="http://${JENKINS_HOSTNAME:-jenkins.briklab.test}:${JENKINS_HTTP_PORT:-9090}"
_E2E_JENKINS_USER="admin"
_E2E_JENKINS_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"

# Cookie jar for CSRF handling (created lazily)
_E2E_JENKINS_COOKIE_JAR=""

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Ensure cookie jar exists.
_e2e_jenkins_ensure_cookie_jar() {
    if [[ -z "$_E2E_JENKINS_COOKIE_JAR" || ! -f "$_E2E_JENKINS_COOKIE_JAR" ]]; then
        _E2E_JENKINS_COOKIE_JAR=$(mktemp)
    fi
}

# Resolve the Jenkins URL prefix for a job.
# Flat pipelineJob: "job/<name>"
# Multibranch (when $E2E_JENKINS_BRANCH is set): "job/<name>/job/<branch>"
_e2e_jenkins_job_path() {
    local job_name="$1"
    if [[ -n "${E2E_JENKINS_BRANCH:-}" ]]; then
        printf 'job/%s/job/%s' "$job_name" "$E2E_JENKINS_BRANCH"
    else
        printf 'job/%s' "$job_name"
    fi
}

# ---------------------------------------------------------------------------
# Low-level API
# ---------------------------------------------------------------------------

# GET request to Jenkins API.
# Args: $1 = path (e.g. "job/node-minimal/api/json")
# Output: response on stdout
# Note: -g disables curl URL globbing so Jenkins tree=builds[...,actions[...]]
# queries with literal brackets are sent as-is instead of failing silently.
e2e.jenkins.api_get() {
    local path="$1"
    _e2e_jenkins_ensure_cookie_jar
    curl -sfg --max-time 30 \
        -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        "${_E2E_JENKINS_URL}/${path}"
}

# Get CRUMB for CSRF protection.
# Output: "field:value" string on stdout, or empty if unavailable
e2e.jenkins.get_crumb() {
    _e2e_jenkins_ensure_cookie_jar
    local crumb_json
    crumb_json=$(curl -sf --max-time 10 \
        -c "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        "${_E2E_JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || true)

    if [[ -n "$crumb_json" ]]; then
        local field value
        field=$(echo "$crumb_json" | jq -r '.crumbRequestField // empty' 2>/dev/null || true)
        value=$(echo "$crumb_json" | jq -r '.crumb // empty' 2>/dev/null || true)
        if [[ -n "$field" && -n "$value" ]]; then
            echo "${field}:${value}"
            return 0
        fi
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Build management
# ---------------------------------------------------------------------------

# Trigger a build and return the build number.
# Args: $1 = job name, $2 = CI variables (optional, "KEY=VAL,KEY2=VAL2")
# Output: build number on stdout
e2e.jenkins.trigger_build() {
    local job_name="$1"
    local ci_vars="${2:-}"
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"

    # Get next build number before triggering
    local next_build
    next_build=$(e2e.jenkins.api_get "${job_path}/api/json" | \
        jq -r '.nextBuildNumber // 1' 2>/dev/null || echo "1")

    # Prepare trigger
    _e2e_jenkins_ensure_cookie_jar
    local crumb
    crumb=$(e2e.jenkins.get_crumb)

    # Parameterized jobs (e.g. those using properties([parameters(...)])) reject
    # plain /build with HTTP 400 -- they require /buildWithParameters. Detect by
    # inspecting the job's property[].parameterDefinitions via the API.
    local has_params
    has_params=$(e2e.jenkins.api_get "${job_path}/api/json?tree=property[parameterDefinitions[name]]" 2>/dev/null | \
        jq -r '[.property[]?.parameterDefinitions // []] | flatten | length' 2>/dev/null || echo "0")

    local endpoint="build"
    local trigger_data=()
    if [[ -n "$ci_vars" ]]; then
        endpoint="buildWithParameters"
        IFS=',' read -ra _pairs <<< "$ci_vars"
        for pair in "${_pairs[@]}"; do
            local _key="${pair%%=*}"
            local _val="${pair#*=}"
            _key="$(echo "$_key" | tr -d '[:space:]')"
            [[ -z "$_key" ]] && continue
            trigger_data+=(--data-urlencode "${_key}=${_val}")
        done
    elif [[ "${has_params:-0}" -gt 0 ]]; then
        endpoint="buildWithParameters"
    fi

    # Fire the trigger
    local crumb_args=()
    if [[ -n "$crumb" ]]; then
        crumb_args=(-H "$crumb")
    fi

    curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST \
        -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        ${crumb_args[@]+"${crumb_args[@]}"} \
        ${trigger_data[@]+"${trigger_data[@]}"} \
        "${_E2E_JENKINS_URL}/${job_path}/${endpoint}" >/dev/null 2>&1

    # Wait for the build to start (up to 90s)
    local elapsed=0
    while [[ $elapsed -lt 90 ]]; do
        if e2e.jenkins.api_get "${job_path}/${next_build}/api/json" &>/dev/null; then
            echo "$next_build"
            return 0
        fi
        # Check if nextBuildNumber advanced
        local current_next
        current_next=$(e2e.jenkins.api_get "${job_path}/api/json" 2>/dev/null | \
            jq -r '.nextBuildNumber // 0' 2>/dev/null || echo "0")
        if [[ "$current_next" -gt "$next_build" ]]; then
            if e2e.jenkins.api_get "${job_path}/${next_build}/api/json" &>/dev/null; then
                echo "$next_build"
                return 0
            fi
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_error "Build #${next_build} did not start within 90s" >&2
    return 1
}

# Wait for a build to complete.
# Args: $1 = job name, $2 = build number, $3 = timeout (seconds)
# Output: build result on stdout (SUCCESS, FAILURE, etc.)
e2e.jenkins.wait_build() {
    local job_name="$1" build_number="$2" timeout="${3:-300}"
    local poll_interval=10
    local elapsed=0
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"

    while [[ $elapsed -lt $timeout ]]; do
        local build_json
        build_json=$(e2e.jenkins.api_get "${job_path}/${build_number}/api/json" 2>/dev/null || true)

        if [[ -n "$build_json" ]]; then
            local building result
            building=$(echo "$build_json" | jq -r '.building' 2>/dev/null || echo "true")
            result=$(echo "$build_json" | jq -r '.result // "null"' 2>/dev/null || echo "null")

            if [[ "$building" == "false" && "$result" != "null" ]]; then
                echo "$result"
                return 0
            fi
        fi

        printf "." >&2
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    echo "" >&2
    log_error "Build timed out after ${timeout}s" >&2
    echo "TIMEOUT"
    return 1
}

# Wait for a build triggered by a specific Git SHA to appear, then wait for completion.
# Args: $1 = job name, $2 = commit SHA, $3 = timeout for discovery (default 90),
#        $4 = timeout for build completion (default 300)
# Output: build number on stdout
e2e.jenkins.wait_build_by_sha() {
    local job_name="$1" sha="$2"
    local discover_timeout="${3:-90}"
    local completion_timeout="${4:-300}"
    local poll_interval=5
    local elapsed=0
    local build_number=""
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"

    # Phase 1: discover build by SHA
    while [[ $elapsed -lt $discover_timeout ]]; do
        local builds_json
        builds_json=$(e2e.jenkins.api_get "${job_path}/api/json?tree=builds[number,actions[lastBuiltRevision[SHA1]],building,result]" 2>/dev/null || true)

        if [[ -n "$builds_json" ]]; then
            # Find a build matching the SHA in lastBuiltRevision
            build_number=$(echo "$builds_json" | jq -r --arg sha "$sha" '
                .builds[]? |
                select(.actions[]?.lastBuiltRevision?.SHA1 == $sha) |
                .number
            ' 2>/dev/null | head -1 || true)

            if [[ -n "$build_number" ]]; then
                break
            fi
        fi

        printf "." >&2
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        echo "" >&2
        log_error "No build found for SHA ${sha} after ${discover_timeout}s" >&2
        return 1
    fi

    log_info "Build #${build_number} found for SHA ${sha:0:8}" >&2

    # Phase 2: wait for build completion
    local result
    result=$(e2e.jenkins.wait_build "$job_name" "$build_number" "$completion_timeout")

    echo "$build_number"
}

# Get the result of a completed build.
# Args: $1 = job name, $2 = build number
# Output: result string on stdout (SUCCESS, FAILURE, UNSTABLE, ABORTED, etc.)
e2e.jenkins.get_build_result() {
    local job_name="$1" build_number="$2"
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"
    e2e.jenkins.api_get "${job_path}/${build_number}/api/json" | \
        jq -r '.result // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN"
}

# Get pipeline stage details.
# Args: $1 = job name, $2 = build number
# Output: stages JSON on stdout
e2e.jenkins.get_stages() {
    local job_name="$1" build_number="$2"
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"
    e2e.jenkins.api_get "${job_path}/${build_number}/wfapi/describe" 2>/dev/null || true
}

# Get the full console log of a build.
# Args: $1 = job name, $2 = build number
# Output: log text on stdout
e2e.jenkins.get_console_log() {
    local job_name="$1" build_number="$2"
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"
    e2e.jenkins.api_get "${job_path}/${build_number}/consoleText" 2>/dev/null || true
}

# Download a single archived artifact from a build into <dest>.
# Args: $1 = job name, $2 = build number, $3 = artifact path (e.g.
#       "brik-artifacts/pipeline-report.json"), $4 = destination file path
# Returns: 0 on success, non-zero otherwise
e2e.jenkins.download_artifact() {
    local job_name="$1" build_number="$2" artifact_path="$3" dest="$4"
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"
    _e2e_jenkins_ensure_cookie_jar
    curl -sfgL --max-time 60 \
        -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        -o "$dest" \
        "${_E2E_JENKINS_URL}/${job_path}/${build_number}/artifact/${artifact_path}"
}
