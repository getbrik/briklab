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
    briklab.http.get "${_E2E_NEXUS_URL}${path}" \
        -u "${_E2E_NEXUS_USER}:${_E2E_NEXUS_PASS}"
}

# Nexus REST API DELETE with auth.
_e2e_nexus_api_delete() {
    local path="$1"
    briklab.http.delete "${_E2E_NEXUS_URL}${path}" \
        -u "${_E2E_NEXUS_USER}:${_E2E_NEXUS_PASS}" 2>/dev/null || true
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

# Resolve the manifest digest of a Docker image tag on the Nexus registry
# (OCI distribution API; the digest comes back in Docker-Content-Digest).
# Args: $1 = image name (e.g. "brik/node-promote-channel"), $2 = tag
# Output: "sha256:<hex>" on stdout (empty when the tag is absent)
e2e.nexus.docker_digest() {
    local name="$1" tag="$2"
    curl -fsS -o /dev/null -D - --max-time 30 \
        -u "${_E2E_NEXUS_USER}:${_E2E_NEXUS_PASS}" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
        "${_E2E_NEXUS_DOCKER_URL}/v2/${name}/manifests/${tag}" 2>/dev/null \
        | tr -d '\r' | grep -i '^Docker-Content-Digest:' | tail -1 | awk '{print $2}'
}

# Count the referrer manifests attached to a digest, via the cosign tag
# fallback scheme (Nexus has no OCI 1.1 referrers API: cosign/oras maintain
# an index tagged "sha256-<hex>" listing the referrers).
# Args: $1 = image name, $2 = digest ("sha256:<hex>")
# Output: number of referrer manifests (0 when the index is absent)
e2e.nexus.docker_referrers_count() {
    local name="$1" digest="$2"
    local index_tag="sha256-${digest#sha256:}"
    curl -fsS --max-time 30 \
        -u "${_E2E_NEXUS_USER}:${_E2E_NEXUS_PASS}" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        "${_E2E_NEXUS_DOCKER_URL}/v2/${name}/manifests/${index_tag}" 2>/dev/null \
        | jq -r '.manifests | length' 2>/dev/null || echo 0
}

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
