#!/usr/bin/env bash
# E2E Compose Validation Library
#
# Functions for validating Docker Compose deployments.
# Uses docker inspect to check container state.

[[ -n "${_E2E_COMPOSE_LOADED:-}" ]] && return 0
_E2E_COMPOSE_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Query functions
# ---------------------------------------------------------------------------

# Check if a container is running.
# Args: $1 = container name
# Returns: 0 if running, 1 otherwise
e2e.compose.container_running() {
    local container="$1"
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
    [[ "$status" == "running" ]]
}

# Get the image of a running container.
# Args: $1 = container name
# Output: image string on stdout (e.g. "nexus.briklab.test:8082/brik/node-full:v0.1.0")
e2e.compose.get_container_image() {
    local container="$1"
    docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo ""
}

# Check if a container is healthy (has health check and passes).
# Args: $1 = container name
# Returns: 0 if healthy, 1 otherwise
e2e.compose.container_healthy() {
    local container="$1"
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
    [[ "$health" == "healthy" ]]
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# Force-remove every container belonging to a compose project.
# Compose names containers "<project>-<service>-<ordinal>" and labels them
# with "com.docker.compose.project". Port collisions between scenario runs
# come from stale containers still binding the published port, so this
# helper wipes them before a fresh deploy.
# Args: $1 = compose project name (e.g. "node-deploy")
e2e.compose.teardown_stack() {
    local project="$1"
    [[ -z "$project" ]] && return 0

    local ids
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null)
    if [[ -z "$ids" ]]; then
        # Fall back to name-prefix match for containers started without the label
        ids=$(docker ps -aq --filter "name=^${project}-" 2>/dev/null)
    fi
    [[ -z "$ids" ]] && return 0

    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null 2>&1 || true
}
