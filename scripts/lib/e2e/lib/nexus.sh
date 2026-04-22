#!/usr/bin/env bash
# E2E Nexus Validation Library
#
# Functions for querying and validating artifacts in Nexus (unified registry).
# Nexus serves as the single registry for Docker, npm, Maven, PyPI, and NuGet.
#
# Prerequisites:
#   - Nexus must be running on briklab
#   - NEXUS_ADMIN_PASSWORD must be set (via .env)

[[ -n "${_E2E_NEXUS_LOADED:-}" ]] && return 0
_E2E_NEXUS_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_E2E_NEXUS_URL="http://${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_HTTP_PORT:-8081}"
_E2E_NEXUS_DOCKER_URL="http://${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_DOCKER_PORT:-8082}"
_E2E_NEXUS_USER="admin"
_E2E_NEXUS_PASS="${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Nexus REST API GET with auth.
_e2e_nexus_api_get() {
    local path="$1"
    curl -sf --max-time 30 \
        -u "${_E2E_NEXUS_USER}:${_E2E_NEXUS_PASS}" \
        "${_E2E_NEXUS_URL}${path}"
}

# Nexus REST API DELETE with auth.
_e2e_nexus_api_delete() {
    local path="$1"
    curl -sf --max-time 30 \
        -u "${_E2E_NEXUS_USER}:${_E2E_NEXUS_PASS}" \
        -X DELETE \
        "${_E2E_NEXUS_URL}${path}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Docker registry queries (via Docker Registry HTTP API V2 on port 8082)
# ---------------------------------------------------------------------------

# Check if a Docker image exists in Nexus.
# Args: $1 = image path (e.g. "brik/node-full")
# Returns: 0 if exists, 1 otherwise
e2e.nexus.docker_image_exists() {
    local image_path="$1"
    local result
    result=$(curl -sf --max-time 15 "${_E2E_NEXUS_DOCKER_URL}/v2/${image_path}/tags/list" 2>/dev/null) || return 1

    local tag_count
    tag_count=$(echo "$result" | jq -r '.tags | length // 0' 2>/dev/null || echo "0")
    [[ "$tag_count" -gt 0 ]]
}

# Get all tags for a Docker image.
# Args: $1 = image path
# Output: JSON array of tags on stdout
e2e.nexus.docker_get_tags() {
    local image_path="$1"
    curl -sf --max-time 15 "${_E2E_NEXUS_DOCKER_URL}/v2/${image_path}/tags/list" 2>/dev/null | \
        jq -r '.tags // []' 2>/dev/null
}

# Check if a specific Docker tag exists.
# Args: $1 = image path, $2 = tag
# Returns: 0 if exists, 1 otherwise
e2e.nexus.docker_tag_exists() {
    local image_path="$1" tag="$2"
    local tags
    tags=$(e2e.nexus.docker_get_tags "$image_path")
    echo "$tags" | jq -e --arg tag "$tag" 'index($tag) != null' &>/dev/null
}

# ---------------------------------------------------------------------------
# Package registry queries (via Nexus REST API)
# ---------------------------------------------------------------------------

# Check if an npm package exists.
# Args: $1 = package name (e.g. "@brik/node-complete")
# Returns: 0 if exists, 1 otherwise
e2e.nexus.npm_package_exists() {
    local package_name="$1"
    local result
    result=$(_e2e_nexus_api_get "/service/rest/v1/search?repository=brik-npm&name=${package_name}" 2>/dev/null) || return 1
    local count
    count=$(echo "$result" | jq -r '.items | length // 0' 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# Check if a Maven artifact exists.
# Args: $1 = group ID (e.g. "com.example"), $2 = artifact ID (e.g. "my-app")
# Returns: 0 if exists, 1 otherwise
e2e.nexus.maven_package_exists() {
    local group_id="$1" artifact_id="$2"
    local result
    result=$(_e2e_nexus_api_get "/service/rest/v1/search?repository=brik-maven&group=${group_id}&name=${artifact_id}" 2>/dev/null) || return 1
    local count
    count=$(echo "$result" | jq -r '.items | length // 0' 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# Check if a PyPI package exists.
# Args: $1 = package name
# Returns: 0 if exists, 1 otherwise
e2e.nexus.pypi_package_exists() {
    local package_name="$1"
    local result
    result=$(_e2e_nexus_api_get "/service/rest/v1/search?repository=brik-pypi&name=${package_name}" 2>/dev/null) || return 1
    local count
    count=$(echo "$result" | jq -r '.items | length // 0' 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# Check if a NuGet package exists.
# Args: $1 = package name
# Returns: 0 if exists, 1 otherwise
e2e.nexus.nuget_package_exists() {
    local package_name="$1"
    local result
    result=$(_e2e_nexus_api_get "/service/rest/v1/search?repository=brik-nuget&name=${package_name}" 2>/dev/null) || return 1
    local count
    count=$(echo "$result" | jq -r '.items | length // 0' 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# Delete Docker images matching a prefix.
# Args: $1 = image path prefix (e.g. "brik/")
e2e.nexus.delete_docker_images() {
    local prefix="$1"
    local components
    components=$(_e2e_nexus_api_get "/service/rest/v1/components?repository=brik-docker" 2>/dev/null) || return 0

    echo "$components" | jq -r --arg prefix "$prefix" \
        '.items[] | select(.name | startswith($prefix)) | .id' 2>/dev/null | \
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        _e2e_nexus_api_delete "/service/rest/v1/components/${id}"
    done
}

# Delete a specific cargo crate (and its sparse-index entry) from brik-cargo.
# Cargo's sparse index rejects re-publishing the same name@version, so the
# index path component (e.g. "/ru/st/rust-complete") must be removed as well
# as the .crate component itself.
# Args: $1 = crate name, $2 = crate version
e2e.nexus.delete_cargo_crate() {
    local name="$1" version="$2"
    local components
    components=$(_e2e_nexus_api_get "/service/rest/v1/components?repository=brik-cargo" 2>/dev/null) || return 0

    echo "$components" | jq -r --arg name "$name" --arg version "$version" \
        '.items[] | select((.name == $name and .version == $version) or (.name | endswith("/" + $name))) | .id' 2>/dev/null | \
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        _e2e_nexus_api_delete "/service/rest/v1/components/${id}"
    done
}

# Delete all test artifacts from all Nexus repositories.
e2e.nexus.delete_all_test_artifacts() {
    for repo in brik-docker brik-npm brik-maven brik-pypi brik-nuget brik-cargo; do
        local continuation_token=""
        while true; do
            local url="/service/rest/v1/components?repository=${repo}"
            if [[ -n "$continuation_token" ]]; then
                url="${url}&continuationToken=${continuation_token}"
            fi

            local result
            result=$(_e2e_nexus_api_get "$url" 2>/dev/null) || break

            local ids
            ids=$(echo "$result" | jq -r '.items[].id // empty' 2>/dev/null)
            for id in $ids; do
                [[ -z "$id" ]] && continue
                _e2e_nexus_api_delete "/service/rest/v1/components/${id}"
            done

            continuation_token=$(echo "$result" | jq -r '.continuationToken // empty' 2>/dev/null)
            [[ -z "$continuation_token" ]] && break
        done
    done
}
