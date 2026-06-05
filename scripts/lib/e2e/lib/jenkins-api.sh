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
    briklab.http.get "${_E2E_JENKINS_URL}/${path}" \
        -g -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}"
}

# Get CRUMB for CSRF protection.
# Output: "field:value" string on stdout, or empty if unavailable
e2e.jenkins.get_crumb() {
    _e2e_jenkins_ensure_cookie_jar
    local crumb_json
    crumb_json=$(briklab.http.get "${_E2E_JENKINS_URL}/crumbIssuer/api/json" \
        --max-time 10 \
        -c "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" 2>/dev/null || true)

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

# Pre-register parameters on a job via the /scriptText Groovy API.
# Jenkins evaluates a Pipeline's properties([parameters(...)]) block only
# when the build actually runs, so the very first /buildWithParameters POST
# on a never-built job is rejected with HTTP 400 ("Use POST to build a job
# with parameters") because no ParametersDefinitionProperty exists yet.
# Adding the property up-front via scriptText makes /buildWithParameters
# succeed on the first call without needing to first run an unparameterized
# build (which would deploy snapshots or fail outright).
#
# Args: $1 = job full-name (e.g. "node-deploy-failure")
# Side effect: idempotently attaches BRIK_DRY_RUN + BRIK_TAG + BRIK_WITH_DEPLOY to the job.
e2e.jenkins.pre_register_params() {
    local job_full_name="$1"
    local crumb
    crumb=$(e2e.jenkins.get_crumb)
    local crumb_args=()
    [[ -n "$crumb" ]] && crumb_args=(-H "$crumb")

    local groovy
    groovy=$(cat <<'GROOVY'
import jenkins.model.Jenkins
import hudson.model.ParametersDefinitionProperty
import hudson.model.BooleanParameterDefinition
import hudson.model.StringParameterDefinition

def j = Jenkins.instance.getItemByFullName('__JOB__')
if (j == null) { println 'job-not-found'; return }

// Expected parameters Brik consumes at pipeline runtime. Adding a new
// entry here must stay safe across version upgrades: the early code
// returned `already-set` as soon as ANY ParametersDefinitionProperty
// existed on the job, so a job carrying stale params would not pick up
// new ones -- and the next build would drop them silently (HARN-3 from
// the 2026-05-20 campaign). We now merge missing entries into the
// existing property instead.
def expected = [
    new BooleanParameterDefinition('BRIK_DRY_RUN', false, 'Skip destructive deploy actions.'),
    new StringParameterDefinition('BRIK_TAG', '', 'Release tag (e.g. v0.1.0). Empty for snapshot.'),
    new BooleanParameterDefinition('BRIK_WITH_DEPLOY', false, 'Opt into the deploy stage. Skipped by default.'),
    new BooleanParameterDefinition('BRIK_WITH_PACKAGE', false, 'Opt into the package stage. Skipped by default. brikPipeline maps this to brik plan --with-package.'),
    new StringParameterDefinition('BRIK_RUNNER_CLASSES_FILE', '', 'Runner-class image registry override (absolute, or relative to the brik library root).')
]

def prop = j.getProperty(ParametersDefinitionProperty.class)
if (prop == null) {
    j.addProperty(new ParametersDefinitionProperty(expected))
    j.save()
    println 'registered (initial)'
} else {
    def existing = prop.getParameterDefinitions().collect { it.name } as Set
    def missing = expected.findAll { !(it.name in existing) }
    if (missing.isEmpty()) {
        println 'already-set'
    } else {
        def merged = prop.getParameterDefinitions() + missing
        // removeProperty + addProperty is the portable rebuild path:
        // ParametersDefinitionProperty has no incremental add API that
        // works across our Jenkins LTS matrix.
        j.removeProperty(ParametersDefinitionProperty.class)
        j.addProperty(new ParametersDefinitionProperty(merged))
        j.save()
        println 'registered (added=' + missing.collect { it.name }.join(',') + ')'
    }
}
GROOVY
)
    groovy="${groovy//__JOB__/${job_full_name}}"

    briklab.http.request "${_E2E_JENKINS_URL}/scriptText" -X POST \
        -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        ${crumb_args[@]+"${crumb_args[@]}"} \
        --data-urlencode "script=${groovy}" 2>/dev/null
}

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

    # Parameter registration before trigger. Jenkins silently DROPS any
    # buildWithParameters value whose parameter is not already declared on
    # the job (default ParametersAction behaviour). Two ways a param goes
    # undeclared at trigger time:
    #   1. First-build race: a Pipeline declares its params via
    #      properties([parameters(...)]) only when the build runs, so the
    #      very first /buildWithParameters has no ParametersDefinitionProperty.
    #   2. Partial seed: the casc Job DSL declares a SUBSET (BRIK_DRY_RUN +
    #      BRIK_TAG) at job creation, so has_params>0 from the start but the
    #      Brik-specific params (BRIK_WITH_DEPLOY, BRIK_RUNNER_CLASSES_FILE)
    #      are still missing -- and would be dropped on every trigger until a
    #      build happens to run properties() first.
    # So pre-register whenever ci_vars is requested, NOT only when
    # has_params==0. pre_register_params is idempotent: it merges only the
    # missing expected params and is a no-op ('already-set') otherwise.
    # Multibranch sub-jobs (E2E_JENKINS_BRANCH set) are skipped because their
    # property model is owned by the parent. pre_register_params calls
    # get_crumb internally, which rewrites the cookie jar -- re-fetch the
    # crumb afterwards so the build POST below ships a crumb bound to the
    # current session.
    if [[ -n "$ci_vars" && -z "${E2E_JENKINS_BRANCH:-}" ]]; then
        e2e.jenkins.pre_register_params "$job_name" >/dev/null 2>&1 || true
        crumb=$(e2e.jenkins.get_crumb)
        has_params=$(e2e.jenkins.api_get "${job_path}/api/json?tree=property[parameterDefinitions[name]]" 2>/dev/null | \
            jq -r '[.property[]?.parameterDefinitions // []] | flatten | length' 2>/dev/null || echo "0")
    fi

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

    briklab.http.code "${_E2E_JENKINS_URL}/${job_path}/${endpoint}" -X POST \
        -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        ${crumb_args[@]+"${crumb_args[@]}"} \
        ${trigger_data[@]+"${trigger_data[@]}"} >/dev/null 2>&1

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
#       "brik-artifacts/aggregate-report.json"), $4 = destination file path
# Returns: 0 on success, non-zero otherwise
e2e.jenkins.download_artifact() {
    local job_name="$1" build_number="$2" artifact_path="$3" dest="$4"
    local job_path
    job_path="$(_e2e_jenkins_job_path "$job_name")"
    _e2e_jenkins_ensure_cookie_jar
    briklab.http.get "${_E2E_JENKINS_URL}/${job_path}/${build_number}/artifact/${artifact_path}" \
        --max-time 60 -g -L \
        -b "$_E2E_JENKINS_COOKIE_JAR" \
        -u "${_E2E_JENKINS_USER}:${_E2E_JENKINS_PASSWORD}" \
        -o "$dest"
}
