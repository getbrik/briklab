#!/usr/bin/env bash
# E2E GitLab API Library
#
# Reusable functions for interacting with the GitLab API.
# Extracted from gitlab-test.sh and gitlab-push.sh.
#
# Prerequisites:
#   - GITLAB_PAT must be set (via ensure_gitlab_pat or .env)
#   - GITLAB_HOSTNAME / GITLAB_HTTP_PORT for non-default URLs

[[ -n "${_E2E_GITLAB_API_LOADED:-}" ]] && return 0
_E2E_GITLAB_API_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_E2E_GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"

# ---------------------------------------------------------------------------
# Low-level API
# ---------------------------------------------------------------------------

# GET request to GitLab API.
# Args: $1 = endpoint (e.g. "projects/42")
# Output: JSON response on stdout
e2e.gitlab.api_get() {
    local endpoint="$1"
    curl -sf --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${_E2E_GITLAB_URL}/api/v4/${endpoint}"
}

# POST request to GitLab API (form-encoded).
# Args: $1 = endpoint, $2... = optional curl data args
# Output: JSON response on stdout
e2e.gitlab.api_post() {
    local endpoint="$1"
    shift
    curl -sf --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -X POST \
        "$@" \
        "${_E2E_GITLAB_URL}/api/v4/${endpoint}"
}

# POST request with JSON body.
# Args: $1 = endpoint, $2 = JSON body
# Output: JSON response on stdout
e2e.gitlab.api_post_json() {
    local endpoint="$1"
    local json_body="$2"
    curl -sf --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$json_body" \
        "${_E2E_GITLAB_URL}/api/v4/${endpoint}"
}

# PUT request to GitLab API.
# Args: $1 = endpoint, $2... = optional curl data args
# Output: JSON response on stdout
e2e.gitlab.api_put() {
    local endpoint="$1"
    shift
    curl -sf --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -X PUT \
        "$@" \
        "${_E2E_GITLAB_URL}/api/v4/${endpoint}"
}

# DELETE request to GitLab API.
# Args: $1 = endpoint
e2e.gitlab.api_delete() {
    local endpoint="$1"
    curl -sf --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -X DELETE \
        "${_E2E_GITLAB_URL}/api/v4/${endpoint}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Project management
# ---------------------------------------------------------------------------

# Get project ID from URL-encoded path.
# Args: $1 = URL-encoded project path (e.g. "brik%2Fnode-minimal")
# Output: project ID on stdout
e2e.gitlab.get_project_id() {
    local encoded_path="$1"
    e2e.gitlab.api_get "projects/${encoded_path}" | \
        jq -r '.id // empty' 2>/dev/null
}

# Create a GitLab group (idempotent).
# Args: $1 = group name
e2e.gitlab.ensure_group() {
    local group_name="$1"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${_E2E_GITLAB_URL}/api/v4/groups" \
        -d "name=${group_name}&path=${group_name}&visibility=public")

    case "$http_code" in
        201) log_ok "Group '${group_name}' created" ;;
        400) log_info "Group '${group_name}' already exists" ;;
        *)   log_warn "Group creation returned HTTP ${http_code}" ;;
    esac
}

# Create a GitLab project under a namespace.
# Args: $1 = namespace, $2 = project name
# Output: project ID on stdout
e2e.gitlab.create_project() {
    local namespace="$1"
    local project_name="$2"

    # Get namespace ID
    local ns_id
    ns_id=$(e2e.gitlab.api_get "namespaces?search=${namespace}" | \
        jq -r --arg ns "$namespace" '[.[] | select(.path == $ns)][0].id // empty' 2>/dev/null || true)

    if [[ -z "$ns_id" ]]; then
        log_warn "Namespace '${namespace}' not found, creating under root"
        ns_id=""
    fi

    local data="name=${project_name}&path=${project_name}&visibility=public&initialize_with_readme=false"
    if [[ -n "$ns_id" ]]; then
        data="${data}&namespace_id=${ns_id}"
    fi

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${_E2E_GITLAB_URL}/api/v4/projects" \
        -d "$data")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        201)
            local project_id
            project_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null || true)
            log_ok "Project '${namespace}/${project_name}' created (ID: ${project_id})"
            echo "$project_id"
            ;;
        400)
            log_info "Project '${namespace}/${project_name}' already exists"
            # Get existing project ID
            local encoded_path
            encoded_path=$(printf '%s' "${namespace}/${project_name}" | jq -sRr @uri 2>/dev/null || \
                python3 -c "import urllib.parse; print(urllib.parse.quote('${namespace}/${project_name}', safe=''))" 2>/dev/null)
            e2e.gitlab.get_project_id "$encoded_path"
            ;;
        *)
            log_error "Project creation failed (HTTP ${http_code}): ${body}"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Pipeline management
# ---------------------------------------------------------------------------

# Trigger a pipeline on a project.
# Args: $1 = project ID, $2 = ref, $3 = CI variables (optional, "KEY=VAL,KEY2=VAL2")
# Output: pipeline ID on stdout
e2e.gitlab.trigger_pipeline() {
    local project_id="$1"
    local ref="$2"
    local ci_vars="${3:-}"

    local json_body
    if [[ -z "$ci_vars" ]]; then
        json_body=$(printf '{"ref":"%s"}' "$ref")
    else
        local vars_json="["
        local first=true
        IFS=',' read -ra pairs <<< "$ci_vars"
        for pair in "${pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            key="$(echo "$key" | tr -d '[:space:]')"
            [[ -z "$key" ]] && continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                vars_json+=","
            fi
            vars_json+="{\"key\":\"${key}\",\"variable_type\":\"env_var\",\"value\":\"${value}\"}"
        done
        vars_json+="]"
        json_body=$(printf '{"ref":"%s","variables":%s}' "$ref" "$vars_json")
    fi

    local response
    response=$(e2e.gitlab.api_post_json "projects/${project_id}/pipeline" "$json_body")
    echo "$response" | jq -r '.id // empty' 2>/dev/null
}

# Get pipeline status.
# Args: $1 = project ID, $2 = pipeline ID
# Output: status string on stdout
e2e.gitlab.get_pipeline_status() {
    local project_id="$1" pipeline_id="$2"
    e2e.gitlab.api_get "projects/${project_id}/pipelines/${pipeline_id}" | \
        jq -r '.status // empty' 2>/dev/null
}

# Wait for pipeline to reach a terminal state.
# Args: $1 = project ID, $2 = pipeline ID, $3 = timeout (seconds)
# Output: final status on stdout
e2e.gitlab.wait_pipeline() {
    local project_id="$1" pipeline_id="$2" timeout="${3:-300}"
    local poll_interval=10
    local elapsed=0
    local status

    while [[ $elapsed -lt $timeout ]]; do
        status=$(e2e.gitlab.get_pipeline_status "$project_id" "$pipeline_id")
        case "$status" in
            success|failed|canceled|skipped)
                echo "$status"
                return 0
                ;;
            *)
                printf "." >&2
                sleep "$poll_interval"
                elapsed=$((elapsed + poll_interval))
                ;;
        esac
    done

    echo "" >&2
    log_error "Pipeline timed out after ${timeout}s"
    echo "timeout"
    return 1
}

# Wait for a pipeline triggered by a specific SHA to appear, then wait for completion.
# Args: $1 = project ID, $2 = commit SHA, $3 = timeout for discovery (default 60),
#        $4 = timeout for pipeline completion (default 300)
# Output: "pipeline_id status" on stdout
e2e.gitlab.wait_pipeline_by_sha() {
    local project_id="$1" sha="$2"
    local discover_timeout="${3:-60}"
    local completion_timeout="${4:-300}"
    local poll_interval=5
    local elapsed=0
    local pipeline_id=""

    # Phase 1: discover pipeline triggered by this SHA
    while [[ $elapsed -lt $discover_timeout ]]; do
        pipeline_id=$(e2e.gitlab.api_get "projects/${project_id}/pipelines?sha=${sha}&per_page=1" | \
            jq -r '.[0].id // empty' 2>/dev/null || true)

        if [[ -n "$pipeline_id" ]]; then
            break
        fi

        printf "." >&2
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$pipeline_id" ]]; then
        echo "" >&2
        log_error "No pipeline found for SHA ${sha} after ${discover_timeout}s" >&2
        return 1
    fi

    # Route log lines to stderr: this function's stdout is captured by the
    # caller via `$(...)`, so any log_* call (which writes to stdout by
    # default) would contaminate the returned "pipeline_id status" string
    # with ANSI-coloured [INFO] text. Progress dots already go to stderr
    # above; this aligns the rest of the function with that convention.
    log_info "Pipeline #${pipeline_id} found for SHA ${sha:0:8}" >&2

    # Phase 2: wait for pipeline completion
    local status
    status=$(e2e.gitlab.wait_pipeline "$project_id" "$pipeline_id" "$completion_timeout")

    echo "${pipeline_id} ${status}"
}

# Cancel pipelines with a given status.
# Args: $1 = project ID, $2 = status filter (running|pending)
e2e.gitlab.cancel_pipelines() {
    local project_id="$1" status_filter="$2"
    local pipeline_ids
    pipeline_ids=$(e2e.gitlab.api_get "projects/${project_id}/pipelines?status=${status_filter}&per_page=100" | \
        jq -r '.[].id' 2>/dev/null || true)

    for ppid in $pipeline_ids; do
        e2e.gitlab.api_post "projects/${project_id}/pipelines/${ppid}/cancel" >/dev/null 2>&1 || true
    done
}

# Cancel all running/pending pipelines for all projects in a group.
# Args: $1 = group name (default: "brik")
e2e.gitlab.cancel_all_group_pipelines() {
    local group_name="${1:-brik}"

    # Get all project IDs in the group
    local project_ids
    project_ids=$(e2e.gitlab.api_get "groups/${group_name}/projects?per_page=100&include_subgroups=true" | \
        jq -r '.[].id' 2>/dev/null || true)

    for pid in $project_ids; do
        for status in running pending; do
            e2e.gitlab.cancel_pipelines "$pid" "$status"
        done
    done
}

# Get latest pipeline for a project/ref.
# Args: $1 = project ID, $2 = ref (optional)
# Output: pipeline JSON on stdout
e2e.gitlab.get_latest_pipeline() {
    local project_id="$1" ref="${2:-}"
    local endpoint="projects/${project_id}/pipelines?per_page=1&order_by=id&sort=desc"
    if [[ -n "$ref" ]]; then
        endpoint="${endpoint}&ref=${ref}"
    fi
    e2e.gitlab.api_get "$endpoint" | jq '.[0] // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Job management
# ---------------------------------------------------------------------------

# Get all jobs for a pipeline.
# Args: $1 = project ID, $2 = pipeline ID
# Output: jobs JSON array on stdout
e2e.gitlab.get_jobs() {
    local project_id="$1" pipeline_id="$2"
    e2e.gitlab.api_get "projects/${project_id}/pipelines/${pipeline_id}/jobs?per_page=100"
}

# Get status of a specific job from jobs JSON.
# Args: $1 = jobs JSON, $2 = job name
# Output: status string on stdout (or "not_found")
e2e.gitlab.get_job_status() {
    local jobs_json="$1" job_name="$2"
    echo "$jobs_json" | jq -r \
        --arg name "$job_name" \
        '[.[] | select(.name == $name)][0].status // "not_found"' 2>/dev/null || echo "unknown"
}

# Get the log (trace) of a specific job.
# Args: $1 = project ID, $2 = job ID
# Output: log text on stdout
e2e.gitlab.get_job_log() {
    local project_id="$1" job_id="$2"
    curl -sf --max-time 60 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${_E2E_GITLAB_URL}/api/v4/projects/${project_id}/jobs/${job_id}/trace" 2>/dev/null || true
}

# Download a single file from a job's artifact archive into <dest>.
# Args: $1 = project ID, $2 = job ID, $3 = artifact path (e.g.
#       "brik-artifacts/aggregate-report.json"), $4 = destination file path
# Returns: 0 on success (file downloaded), non-zero otherwise
e2e.gitlab.download_artifact() {
    local project_id="$1" job_id="$2" artifact_path="$3" dest="$4"
    curl -sfL --max-time 60 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -o "$dest" \
        "${_E2E_GITLAB_URL}/api/v4/projects/${project_id}/jobs/${job_id}/artifacts/${artifact_path}"
}

# ---------------------------------------------------------------------------
# CI Variables
# ---------------------------------------------------------------------------

# Set a CI variable on a group.
# Args: $1 = group ID/path, $2 = key, $3 = value, $4 = masked (true/false, default false)
e2e.gitlab.set_group_variable() {
    local group_id="$1" key="$2" value="$3" masked="${4:-false}"

    # Try update first, then create
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -X PUT \
        --data-urlencode "value=${value}" \
        -d "masked=${masked}" \
        "${_E2E_GITLAB_URL}/api/v4/groups/${group_id}/variables/${key}" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        return 0
    fi

    # Variable does not exist, create it
    curl -s -o /dev/null --max-time 30 \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        -X POST \
        --data-urlencode "value=${value}" \
        -d "key=${key}&masked=${masked}&protected=false" \
        "${_E2E_GITLAB_URL}/api/v4/groups/${group_id}/variables" 2>/dev/null || true
}
