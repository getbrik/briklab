#!/usr/bin/env bash
# Briklab shared library - colors, logging, env helpers.
# Source this file from any briklab script instead of duplicating these functions.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# BRIKLAB_ROOT can be set before sourcing to override auto-detection.
# Does NOT set shell options (set -euo pipefail) - callers control their own.

[[ -n "${_BRIKLAB_COMMON_LOADED:-}" ]] && return 0
_BRIKLAB_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Root paths
# ---------------------------------------------------------------------------

if [[ -z "${BRIKLAB_ROOT:-}" ]]; then
    # Auto-detect: this file lives at scripts/lib/common.sh
    BRIKLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
ENV_FILE="${BRIKLAB_ROOT}/.env"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

# Save or update a key=value pair in .env
save_to_env() {
    local key="$1" value="$2"
    [[ ! -f "$ENV_FILE" ]] && return
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# Reload .env into current shell (exports all variables)
reload_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    fi
}

# Alias for reload_env
load_env() { reload_env; }

# Check HTTP endpoint returns expected status code
check_http() {
    local url="$1" expected="${2:-200}"
    local code
    code=$(curl -sf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    [[ "$code" == "$expected" ]]
}
