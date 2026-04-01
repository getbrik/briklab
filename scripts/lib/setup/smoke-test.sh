#!/usr/bin/env bash
# Smoke tests to verify each briklab component
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

check() {
    local name="$1"
    local cmd="$2"

    if eval "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}  $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}  $name"
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    local name="$1"
    echo -e "  ${YELLOW}SKIP${NC}  $name (not running)"
    SKIP=$((SKIP + 1))
}

is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

echo ""
echo -e "${BLUE}=== Briklab - Smoke Tests ===${NC}"
echo ""

# === Docker ===
echo -e "${BLUE}Docker:${NC}"
check "Docker daemon" "docker info"
check "brik-net network" "docker network inspect brik-net"

# === GitLab ===
echo ""
echo -e "${BLUE}GitLab:${NC}"
if is_running "brik-gitlab"; then
    GITLAB_PORT="${GITLAB_HTTP_PORT:-8929}"
    check "GitLab HTTP" "curl -sf -o /dev/null http://localhost:${GITLAB_PORT}/users/sign_in"
    check "GitLab API v4" "test \$(curl -so /dev/null -w '%{http_code}' http://localhost:${GITLAB_PORT}/api/v4/version) -ne 000"
else
    skip "GitLab"
fi

# === GitLab Runner ===
echo ""
echo -e "${BLUE}GitLab Runner:${NC}"
if is_running "brik-runner"; then
    check "Runner container" "docker exec brik-runner gitlab-runner --version"

    # Check if the runner is registered
    if docker exec brik-runner cat /etc/gitlab-runner/config.toml 2>/dev/null | grep -q "url"; then
        echo -e "  ${GREEN}PASS${NC}  Runner registered"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}WARN${NC}  Runner not registered (run: ./scripts/briklab.sh setup)"
        SKIP=$((SKIP + 1))
    fi
else
    skip "GitLab Runner"
fi

# === Registry ===
echo ""
echo -e "${BLUE}Docker Registry:${NC}"
if is_running "brik-registry"; then
    REGISTRY_PORT="${REGISTRY_PORT:-5000}"
    check "Registry v2 API" "curl -sf http://localhost:${REGISTRY_PORT}/v2/"
    check "Registry catalog" "curl -sf http://localhost:${REGISTRY_PORT}/v2/_catalog"
else
    skip "Docker Registry"
fi

# === Gitea (Level 2) ===
echo ""
echo -e "${BLUE}Gitea:${NC}"
if is_running "brik-gitea"; then
    GITEA_PORT="${GITEA_HTTP_PORT:-3000}"
    check "Gitea HTTP" "curl -sf http://localhost:${GITEA_PORT}/"
    check "Gitea API" "curl -sf http://localhost:${GITEA_PORT}/api/v1/version"
else
    skip "Gitea"
fi

# === Jenkins (Level 2) ===
echo ""
echo -e "${BLUE}Jenkins:${NC}"
if is_running "brik-jenkins"; then
    JENKINS_PORT="${JENKINS_HTTP_PORT:-9090}"
    check "Jenkins HTTP" "curl -sf http://localhost:${JENKINS_PORT}/login"
else
    skip "Jenkins"
fi

# === k3d / ArgoCD ===
echo ""
echo -e "${BLUE}k3d / ArgoCD:${NC}"
if command -v k3d &>/dev/null && k3d cluster list 2>/dev/null | grep -q "brik"; then
    check "k3d cluster" "kubectl cluster-info"
    check "Nodes ready" "kubectl get nodes -o json | jq -e '.items[].status.conditions[] | select(.type==\"Ready\" and .status==\"True\")'"

    if kubectl get namespace argocd &>/dev/null; then
        check "ArgoCD namespace" "true"
        check "ArgoCD server" "kubectl get deployment argocd-server -n argocd -o json | jq -e '.status.readyReplicas >= 1'"
    else
        skip "ArgoCD"
    fi
else
    skip "k3d cluster"
fi

# === Summary ===
echo ""
echo -e "${BLUE}=== Summary ===${NC}"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Total: ${TOTAL}  |  ${GREEN}PASS: ${PASS}${NC}  |  ${RED}FAIL: ${FAIL}${NC}  |  ${YELLOW}SKIP: ${SKIP}${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some tests failed. Check logs: ./scripts/briklab.sh logs <service>${NC}"
    exit 1
else
    echo -e "${GREEN}All active tests passed.${NC}"
    exit 0
fi
