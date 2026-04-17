#!/usr/bin/env bash
# E2E Jenkins API Library
#
# Reusable functions for interacting with the Jenkins API.
# Extracted from e2e-jenkins-test.sh.
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

# ---------------------------------------------------------------------------
# Low-level API
# ---------------------------------------------------------------------------

# GET request to Jenkins API.
# Args: $1 = path (e.g. "job/node-minimal/api/json")
# Output: response on stdout
e2e.jenkins.api_get() {
    local path="$1"
    _e2e_jenkins_ensure_cookie_jar
    curl -sf --max-time 30 \
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

    # Get next build number before triggering
    local next_build
    next_build=$(e2e.jenkins.api_get "job/${job_name}/api/json" | \
        jq -r '.nextBuildNumber // 1' 2>/dev/null || echo "1")

    # Prepare trigger
    _e2e_jenkins_ensure_cookie_jar
    local crumb
    crumb=$(e2e.jenkins.get_crumb)

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
        "${_E2E_JENKINS_URL}/job/${job_name}/${endpoint}" >/dev/null 2>&1

    # Wait for the build to start (up to 90s)
    local elapsed=0
    while [[ $elapsed -lt 90 ]]; do
        if e2e.jenkins.api_get "job/${job_name}/${next_build}/api/json" &>/dev/null; then
            echo "$next_build"
            return 0
        fi
        # Check if nextBuildNumber advanced
        local current_next
        current_next=$(e2e.jenkins.api_get "job/${job_name}/api/json" 2>/dev/null | \
            jq -r '.nextBuildNumber // 0' 2>/dev/null || echo "0")
        if [[ "$current_next" -gt "$next_build" ]]; then
            if e2e.jenkins.api_get "job/${job_name}/${next_build}/api/json" &>/dev/null; then
                echo "$next_build"
                return 0
            fi
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_error "Build #${next_build} did not start within 90s"
    return 1
}

# Wait for a build to complete.
# Args: $1 = job name, $2 = build number, $3 = timeout (seconds)
# Output: build result on stdout (SUCCESS, FAILURE, etc.)
e2e.jenkins.wait_build() {
    local job_name="$1" build_number="$2" timeout="${3:-300}"
    local poll_interval=10
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local build_json
        build_json=$(e2e.jenkins.api_get "job/${job_name}/${build_number}/api/json" 2>/dev/null || true)

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
    log_error "Build timed out after ${timeout}s"
    echo "TIMEOUT"
    return 1
}

# Get the result of a completed build.
# Args: $1 = job name, $2 = build number
# Output: result string on stdout (SUCCESS, FAILURE, UNSTABLE, ABORTED, etc.)
e2e.jenkins.get_build_result() {
    local job_name="$1" build_number="$2"
    e2e.jenkins.api_get "job/${job_name}/${build_number}/api/json" | \
        jq -r '.result // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN"
}

# Get pipeline stage details.
# Args: $1 = job name, $2 = build number
# Output: stages JSON on stdout
e2e.jenkins.get_stages() {
    local job_name="$1" build_number="$2"
    e2e.jenkins.api_get "job/${job_name}/${build_number}/wfapi/describe" 2>/dev/null || true
}

# Get the full console log of a build.
# Args: $1 = job name, $2 = build number
# Output: log text on stdout
e2e.jenkins.get_console_log() {
    local job_name="$1" build_number="$2"
    e2e.jenkins.api_get "job/${job_name}/${build_number}/consoleText" 2>/dev/null || true
}
