#!/usr/bin/env bash
# briklab.env.* - .env / versions.env helpers (transverse notion).
# Sourced, not executed. Depends on briklab.log.* (sourced below).
#
# ENV_FILE / VERSIONS_ENV_FILE are normally resolved by common.sh; this module
# resolves them itself (respecting any pre-set value) so it is usable standalone.
# Does NOT set shell options - callers control their own.

[[ -n "${_BRIKLAB_ENV_LOADED:-}" ]] && return 0
_BRIKLAB_ENV_LOADED=1

# shellcheck source=log.sh
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

: "${BRIKLAB_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
: "${ENV_FILE:=${BRIKLAB_ROOT}/.env}"
: "${VERSIONS_ENV_FILE:=${BRIKLAB_ROOT}/versions.env}"

# Save or update a key=value pair in .env (no-op if .env is absent).
briklab.env.save() {
    local key="$1" value="$2"
    [[ ! -f "$ENV_FILE" ]] && return
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# Reload .env into the current shell (exports all variables).
briklab.env.reload() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    fi
}

# Load generated component versions (versions.env) into the environment so that
# docker compose substitution and the setup scripts resolve every version from
# the single source of truth (generated from versions.yml by generate-versions.sh).
briklab.env.load_versions() {
    if [[ -f "$VERSIONS_ENV_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$VERSIONS_ENV_FILE"
        set +a
    else
        briklab.log.warn "versions.env not found - run scripts/generate-versions.sh"
    fi
}
