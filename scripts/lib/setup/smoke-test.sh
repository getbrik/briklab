#!/usr/bin/env bash
# Smoke tests to verify each briklab component
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

PASS=0
FAIL=0
SKIP=0

briklab.verify.smoke_check() {
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

briklab.verify.smoke_skip() {
    local name="$1"
    echo -e "  ${YELLOW}SKIP${NC}  $name (not running)"
    SKIP=$((SKIP + 1))
}

briklab.verify.smoke_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

echo ""
echo -e "${BLUE}=== Briklab - Smoke Tests ===${NC}"
echo ""

# === Docker ===
echo -e "${BLUE}Docker:${NC}"
briklab.verify.smoke_check "Docker daemon" "docker info"
briklab.verify.smoke_check "brik-net network" "docker network inspect brik-net"

# === GitLab ===
echo ""
echo -e "${BLUE}GitLab:${NC}"
if briklab.verify.smoke_running "brik-gitlab"; then
    GITLAB_PORT="${GITLAB_HTTP_PORT:-8929}"
    GITLAB_HOST="${GITLAB_HOSTNAME:-gitlab.briklab.test}"
    briklab.verify.smoke_check "GitLab HTTP" "curl -sf -o /dev/null http://${GITLAB_HOST}:${GITLAB_PORT}/users/sign_in"
    briklab.verify.smoke_check "GitLab API v4" "test \$(curl -so /dev/null -w '%{http_code}' http://${GITLAB_HOST}:${GITLAB_PORT}/api/v4/version) -ne 000"
else
    briklab.verify.smoke_skip "GitLab"
fi

# === GitLab Runner ===
echo ""
echo -e "${BLUE}GitLab Runner:${NC}"
if briklab.verify.smoke_running "brik-runner"; then
    briklab.verify.smoke_check "Runner container" "docker exec brik-runner gitlab-runner --version"

    # Check if the runner is registered
    if docker exec brik-runner cat /etc/gitlab-runner/config.toml 2>/dev/null | grep -q "url"; then
        echo -e "  ${GREEN}PASS${NC}  Runner registered"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}WARN${NC}  Runner not registered (run: ./scripts/briklab.sh setup)"
        SKIP=$((SKIP + 1))
    fi
else
    briklab.verify.smoke_skip "GitLab Runner"
fi

# === Nexus Docker Registry ===
echo ""
echo -e "${BLUE}Nexus Docker Registry:${NC}"
if briklab.verify.smoke_running "brik-nexus"; then
    NEXUS_DOCKER_PORT="${NEXUS_DOCKER_PORT:-8082}"
    NEXUS_HOST="${NEXUS_HOSTNAME:-nexus.briklab.test}"
    briklab.verify.smoke_check "Nexus Docker v2 API" "curl -sf -u admin:${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026} https://${NEXUS_HOST}:${NEXUS_DOCKER_PORT}/v2/"
else
    briklab.verify.smoke_skip "Nexus Docker Registry"
fi

# === Gitea ===
echo ""
echo -e "${BLUE}Gitea:${NC}"
if briklab.verify.smoke_running "brik-gitea"; then
    GITEA_PORT="${GITEA_HTTP_PORT:-3000}"
    GITEA_HOST="${GITEA_HOSTNAME:-gitea.briklab.test}"
    briklab.verify.smoke_check "Gitea HTTPS" "curl -sf https://${GITEA_HOST}:${GITEA_PORT}/"
    briklab.verify.smoke_check "Gitea API" "curl -sf https://${GITEA_HOST}:${GITEA_PORT}/api/v1/version"
else
    briklab.verify.smoke_skip "Gitea"
fi

# === Jenkins ===
echo ""
echo -e "${BLUE}Jenkins:${NC}"
if briklab.verify.smoke_running "brik-jenkins"; then
    JENKINS_PORT="${JENKINS_HTTP_PORT:-9090}"
    JENKINS_HOST="${JENKINS_HOSTNAME:-jenkins.briklab.test}"
    briklab.verify.smoke_check "Jenkins HTTP" "curl -sf http://${JENKINS_HOST}:${JENKINS_PORT}/login"
else
    briklab.verify.smoke_skip "Jenkins"
fi

# === Nexus ===
echo ""
echo -e "${BLUE}Nexus:${NC}"
if briklab.verify.smoke_running "brik-nexus"; then
    NEXUS_PORT="${NEXUS_HTTP_PORT:-8081}"
    NEXUS_HOST="${NEXUS_HOSTNAME:-nexus.briklab.test}"
    briklab.verify.smoke_check "Nexus HTTP" "curl -sf http://${NEXUS_HOST}:${NEXUS_PORT}/service/rest/v1/status"
    briklab.verify.smoke_check "Nexus repositories" "curl -sf -u admin:${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026} http://${NEXUS_HOST}:${NEXUS_PORT}/service/rest/v1/repositories"
else
    briklab.verify.smoke_skip "Nexus"
fi

# === k3d / ArgoCD ===
echo ""
echo -e "${BLUE}k3d / ArgoCD:${NC}"
if command -v k3d &>/dev/null && k3d cluster list 2>/dev/null | grep -q "brik"; then
    briklab.verify.smoke_check "k3d cluster" "kubectl cluster-info"
    briklab.verify.smoke_check "Nodes ready" "kubectl get nodes -o json | jq -e '.items[].status.conditions[] | select(.type==\"Ready\" and .status==\"True\")'"

    if kubectl get namespace argocd &>/dev/null; then
        briklab.verify.smoke_check "ArgoCD namespace" "true"
        briklab.verify.smoke_check "ArgoCD server" "kubectl get deployment argocd-server -n argocd -o json | jq -e '.status.readyReplicas >= 1'"
    else
        briklab.verify.smoke_skip "ArgoCD"
    fi
else
    briklab.verify.smoke_skip "k3d cluster"
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
