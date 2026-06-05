#!/usr/bin/env bash
# Briklab shared library - BACKWARD-COMPAT FACADE.
#
# The transverse helpers now live as focused notion modules under lib/transverse/:
#   log.sh   briklab.log.{info,ok,warn,error}   (+ colors)
#   env.sh   briklab.env.{save,reload,load_versions}
#   http.sh  briklab.http.{get,post_json,delete,code}
#   wait.sh  briklab.wait.until
#
# This file sources them and re-exposes the legacy names (log_*, save_to_env,
# reload_env, load_env, load_versions, check_http) so existing callers keep
# working unchanged. New code should call the briklab.* functions directly.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# BRIKLAB_ROOT can be set before sourcing to override auto-detection.
# Does NOT set shell options (set -euo pipefail) - callers control their own.

[[ -n "${_BRIKLAB_COMMON_LOADED:-}" ]] && return 0
_BRIKLAB_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Root paths (transverse/env.sh respects these if already set).
# ---------------------------------------------------------------------------

if [[ -z "${BRIKLAB_ROOT:-}" ]]; then
    # Auto-detect: this file lives at scripts/lib/common.sh
    BRIKLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# Consumed cross-file by transverse/env.sh and by callers (briklab.sh), hence
# flagged unused here.
# shellcheck disable=SC2034
ENV_FILE="${BRIKLAB_ROOT}/.env"
# shellcheck disable=SC2034
VERSIONS_ENV_FILE="${BRIKLAB_ROOT}/versions.env"

# ---------------------------------------------------------------------------
# Transverse notion modules
# ---------------------------------------------------------------------------

_BRIKLAB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=transverse/log.sh
source "${_BRIKLAB_LIB_DIR}/transverse/log.sh"
# shellcheck source=transverse/env.sh
source "${_BRIKLAB_LIB_DIR}/transverse/env.sh"
# shellcheck source=transverse/http.sh
source "${_BRIKLAB_LIB_DIR}/transverse/http.sh"
# shellcheck source=transverse/wait.sh
source "${_BRIKLAB_LIB_DIR}/transverse/wait.sh"

# ---------------------------------------------------------------------------
# Legacy aliases (kept for backward compatibility)
# ---------------------------------------------------------------------------

log_info()  { briklab.log.info  "$@"; }
log_ok()    { briklab.log.ok    "$@"; }
log_warn()  { briklab.log.warn  "$@"; }
log_error() { briklab.log.error "$@"; }

save_to_env()   { briklab.env.save "$@"; }
reload_env()    { briklab.env.reload "$@"; }
load_env()      { briklab.env.reload "$@"; }
load_versions() { briklab.env.load_versions "$@"; }

# Check an HTTP endpoint returns the expected status code (default 200).
check_http() {
    local url="$1" expected="${2:-200}"
    [[ "$(briklab.http.code "$url")" == "$expected" ]]
}
