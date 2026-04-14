#!/usr/bin/env bash
# verify.sh - Reusable verification functions for briklab
# Source this file, then call verify_* functions.
# Each function returns 0 on success, 1 on failure, and logs the result.

# Counters for summary
VERIFY_PASS=0
VERIFY_FAIL=0

# Colors (reuse from parent if already set)
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${NC:=\033[0m}"

_verify_ok() {
    echo -e "  ${GREEN}[OK]${NC}    $1"
    VERIFY_PASS=$((VERIFY_PASS + 1))
}

_verify_fail() {
    echo -e "  ${RED}[FAIL]${NC}  $1"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
}

# --- Container checks ---

verify_container_running() {
    local name="$1"
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    if [[ "$status" == "running" ]]; then
        _verify_ok "$name is running"
        return 0
    fi
    _verify_fail "$name is not running (status: $status)"
    return 1
}

verify_container_healthy() {
    local name="$1"
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "unknown")
    if [[ "$health" == "healthy" ]]; then
        _verify_ok "$name is healthy"
        return 0
    fi
    _verify_fail "$name is not healthy (health: $health)"
    return 1
}

# --- HTTP checks ---

verify_http() {
    local desc="$1" url="$2" expected="${3:-200}"
    local code
    code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "$expected" ]]; then
        _verify_ok "$desc (HTTP $code)"
        return 0
    fi
    _verify_fail "$desc (HTTP $code, expected $expected)"
    return 1
}

# --- Environment checks ---

verify_env_set() {
    local var_name="$1"
    if [[ -n "${!var_name:-}" ]]; then
        _verify_ok "$var_name is set"
        return 0
    fi
    _verify_fail "$var_name is empty or unset"
    return 1
}

# --- File checks ---

verify_file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        _verify_ok "File exists: $path"
        return 0
    fi
    _verify_fail "File missing: $path"
    return 1
}

# --- Command checks ---

verify_cmd() {
    local desc="$1" cmd="$2"
    if eval "$cmd" &>/dev/null; then
        _verify_ok "$desc"
        return 0
    fi
    _verify_fail "$desc"
    return 1
}

# --- Service-specific checks ---

verify_gitlab_pat() {
    local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
    local code
    code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 \
        "${gitlab_url}/api/v4/user?private_token=${GITLAB_PAT:-}" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        _verify_ok "GitLab PAT valid"
        return 0
    fi
    _verify_fail "GitLab PAT invalid (HTTP $code)"
    return 1
}

verify_gitea_pat() {
    local gitea_url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
    if curl -sf -H "Authorization: token ${GITEA_PAT:-}" \
        "${gitea_url}/api/v1/user" &>/dev/null; then
        _verify_ok "Gitea PAT valid"
        return 0
    fi
    _verify_fail "Gitea PAT invalid"
    return 1
}

verify_nexus_auth() {
    local nexus_url="http://${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_HTTP_PORT:-8081}"
    local nexus_pass="${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}"
    if curl -sf -u "admin:${nexus_pass}" \
        "${nexus_url}/service/rest/v1/status" &>/dev/null; then
        _verify_ok "Nexus admin auth"
        return 0
    fi
    _verify_fail "Nexus admin auth failed"
    return 1
}

verify_ssh_connection() {
    local key_file="${BRIKLAB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/data/ssh-target/deploy_key"
    local port="${SSH_TARGET_PORT:-2223}"
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -i "$key_file" -p "$port" deploy@localhost echo ok &>/dev/null; then
        _verify_ok "SSH connection to deploy@localhost:$port"
        return 0
    fi
    _verify_fail "SSH connection to deploy@localhost:$port"
    return 1
}

verify_k3d_cluster() {
    if ! command -v k3d &>/dev/null; then
        _verify_fail "k3d not installed"
        return 1
    fi
    if ! k3d cluster list 2>/dev/null | grep -q brik; then
        _verify_fail "k3d cluster 'brik' not found"
        return 1
    fi
    if kubectl get nodes -o json 2>/dev/null | jq -e '.items[].status.conditions[] | select(.type=="Ready" and .status=="True")' &>/dev/null; then
        _verify_ok "k3d cluster 'brik' ready"
        return 0
    fi
    _verify_fail "k3d cluster 'brik' nodes not ready"
    return 1
}
