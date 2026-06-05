#!/usr/bin/env bash
# Briklab CLI - dispatcher bootstrap helpers (prerequisites + .env loading).
#
# Sourced by both dispatchers (scripts/infra.sh and scripts/briklab.sh) AFTER
# lib/common.sh, so check_prereqs/load_env resolve log_*/ENV_FILE/reload_env at
# call time. load_env here intentionally overrides the bare alias from common.sh
# with a friendlier "missing .env" warning.
# Not meant to run standalone.

[[ -n "${_BRIKLAB_CLI_PREREQS_LOADED:-}" ]] && return 0
_BRIKLAB_CLI_PREREQS_LOADED=1

# Verify required CLI tools are installed and the Docker daemon is reachable.
check_prereqs() {
    local missing=()
    for cmd in docker jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]}"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        log_error "Docker is not running"
        exit 1
    fi
}

# Load .env if present, warning (not failing) when it is absent.
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        reload_env
    else
        log_warn ".env not found - using default values"
        log_info "Copy .env.example to .env: cp .env.example .env"
    fi
}
