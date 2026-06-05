#!/usr/bin/env bash
# infra-verify.sh - Reusable verification functions for briklab
# Source this file, then call verify_* functions.
# Each function returns 0 on success, 1 on failure, and logs the result.

[[ -n "${_BRIKLAB_INFRA_VERIFY_LOADED:-}" ]] && return 0
_BRIKLAB_INFRA_VERIFY_LOADED=1

# Single source of probe truth (pure predicates).
# shellcheck source=checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/checks.sh"

# Counters for summary
VERIFY_PASS=0
VERIFY_FAIL=0

# Colors (reuse from parent if already set)
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${NC:=\033[0m}"

briklab.verify._ok() {
    echo -e "  ${GREEN}[OK]${NC}    $1"
    VERIFY_PASS=$((VERIFY_PASS + 1))
}

briklab.verify._fail() {
    echo -e "  ${RED}[FAIL]${NC}  $1"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
}

# --- Container checks ---

briklab.verify.container_running() {
    local name="$1"
    if briklab.check.container_running "$name"; then
        briklab.verify._ok "$name is running"
        return 0
    fi
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    briklab.verify._fail "$name is not running (status: $status)"
    return 1
}

briklab.verify.container_healthy() {
    local name="$1"
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "unknown")
    if [[ "$health" == "healthy" ]]; then
        briklab.verify._ok "$name is healthy"
        return 0
    fi
    briklab.verify._fail "$name is not healthy (health: $health)"
    return 1
}

# --- HTTP checks ---

briklab.verify.http() {
    local desc="$1" url="$2" expected="${3:-200}"
    local code
    code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "$expected" ]]; then
        briklab.verify._ok "$desc (HTTP $code)"
        return 0
    fi
    briklab.verify._fail "$desc (HTTP $code, expected $expected)"
    return 1
}

# --- Environment checks ---

briklab.verify.env_set() {
    local var_name="$1"
    if [[ -n "${!var_name:-}" ]]; then
        briklab.verify._ok "$var_name is set"
        return 0
    fi
    briklab.verify._fail "$var_name is empty or unset"
    return 1
}

# --- File checks ---

briklab.verify.file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        briklab.verify._ok "File exists: $path"
        return 0
    fi
    briklab.verify._fail "File missing: $path"
    return 1
}

# --- Command checks ---

# Args: $1 = description, then the command and its arguments to run.
briklab.verify.cmd() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        briklab.verify._ok "$desc"
        return 0
    fi
    briklab.verify._fail "$desc"
    return 1
}

# --- Service-specific checks ---

# Service-specific verifies are thin presentation wrappers over the pure
# predicates in checks.sh -- the probe logic lives there once.

briklab.verify.gitlab_pat() {
    if briklab.check.gitlab_pat; then
        briklab.verify._ok "GitLab PAT valid"
        return 0
    fi
    briklab.verify._fail "GitLab PAT invalid"
    return 1
}

briklab.verify.gitea_pat() {
    if briklab.check.gitea_pat; then
        briklab.verify._ok "Gitea PAT valid"
        return 0
    fi
    briklab.verify._fail "Gitea PAT invalid"
    return 1
}

briklab.verify.nexus_auth() {
    if briklab.check.nexus_auth; then
        briklab.verify._ok "Nexus admin auth"
        return 0
    fi
    briklab.verify._fail "Nexus admin auth failed"
    return 1
}

briklab.verify.ssh_connection() {
    local port="${SSH_TARGET_PORT:-2223}"
    if briklab.check.ssh; then
        briklab.verify._ok "SSH connection to deploy@localhost:$port"
        return 0
    fi
    briklab.verify._fail "SSH connection to deploy@localhost:$port"
    return 1
}

briklab.verify.argocd_portfwd() {
    if briklab.check.argocd_portfwd; then
        briklab.verify._ok "ArgoCD port-forward active on :${ARGOCD_PORT:-9080}"
        return 0
    fi
    briklab.verify._fail "ArgoCD port-forward not reachable on :${ARGOCD_PORT:-9080}"
    return 1
}

briklab.verify.argocd_token() {
    if briklab.check.argocd_token; then
        briklab.verify._ok "ArgoCD API token valid"
        return 0
    fi
    briklab.verify._fail "ArgoCD API token invalid or unset"
    return 1
}

briklab.verify.k3d_cluster() {
    if ! command -v k3d &>/dev/null; then
        briklab.verify._fail "k3d not installed"
        return 1
    fi
    if ! k3d cluster list 2>/dev/null | grep -q brik; then
        briklab.verify._fail "k3d cluster 'brik' not found"
        return 1
    fi
    if kubectl get nodes -o json 2>/dev/null | jq -e '.items[].status.conditions[] | select(.type=="Ready" and .status=="True")' &>/dev/null; then
        briklab.verify._ok "k3d cluster 'brik' ready"
        return 0
    fi
    briklab.verify._fail "k3d cluster 'brik' nodes not ready"
    return 1
}
