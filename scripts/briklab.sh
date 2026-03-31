#!/usr/bin/env bash
# Briklab - Main CLI
# Usage: ./scripts/briklab.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${BRIKLAB_DIR}/docker-compose.yml"
COMPOSE_LEVEL2="${BRIKLAB_DIR}/docker-compose.level2.yml"
ENV_FILE="${BRIKLAB_DIR}/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check prerequisites
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

# Load .env if present
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    else
        log_warn ".env not found - using default values"
        log_info "Copy .env.example to .env: cp .env.example .env"
    fi
}

# Compose args based on mode
compose_args() {
    local args=("-f" "$COMPOSE_FILE")
    if [[ "${1:-}" == "--full" ]]; then
        args+=("-f" "$COMPOSE_LEVEL2")
    fi
    echo "${args[@]}"
}

# === COMMANDS ===

cmd_start() {
    local mode="${1:-}"
    check_prereqs
    load_env

    # Level 1 first (creates brik-net network)
    log_info "Starting Level 1 (MVP)..."
    docker compose -f "$COMPOSE_FILE" up -d

    if [[ "$mode" == "--full" ]]; then
        log_info "Starting Level 2 (Gitea + Jenkins)..."
        docker compose -f "$COMPOSE_FILE" -f "$COMPOSE_LEVEL2" up -d
    fi

    log_ok "Containers started"
    log_info "GitLab may take 3-5 min on first start"
    echo ""
    cmd_status
}

cmd_stop() {
    load_env
    log_info "Stopping all containers..."
    docker compose -f "$COMPOSE_FILE" -f "$COMPOSE_LEVEL2" down 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    log_ok "Containers stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start "${1:-}"
}

cmd_status() {
    load_env
    echo ""
    echo -e "${BLUE}=== Briklab - Status ===${NC}"
    echo ""

    local gitlab_port="${GITLAB_HTTP_PORT:-8929}"
    local registry_port="${REGISTRY_PORT:-5000}"
    local gitea_port="${GITEA_HTTP_PORT:-3000}"
    local jenkins_port="${JENKINS_HTTP_PORT:-9090}"

    # Check each container
    for container in brik-gitlab brik-runner brik-registry brik-gitea brik-jenkins; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "n/a")
            case "$health" in
                healthy)   echo -e "  ${GREEN}●${NC} ${container} (healthy)" ;;
                starting)  echo -e "  ${YELLOW}●${NC} ${container} (starting...)" ;;
                *)         echo -e "  ${YELLOW}●${NC} ${container} (running, health: ${health})" ;;
            esac
        else
            echo -e "  ${RED}○${NC} ${container} (stopped)"
        fi
    done

    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    echo "  GitLab   : http://localhost:${gitlab_port}"
    echo "  Registry : http://localhost:${registry_port}/v2/_catalog"
    echo "  Gitea    : http://localhost:${gitea_port}"
    echo "  Jenkins  : http://localhost:${jenkins_port}"
    echo ""
}

cmd_logs() {
    local service="${1:-}"
    if [[ -z "$service" ]]; then
        log_error "Usage: briklab.sh logs <service>"
        log_info "Services: gitlab, gitlab-runner, registry, gitea, jenkins"
        exit 1
    fi

    local container="brik-${service}"
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        docker logs -f --tail 100 "$container"
    else
        log_error "Container '${container}' not found"
        exit 1
    fi
}

cmd_setup() {
    check_prereqs
    load_env

    log_info "Initial briklab configuration..."
    echo ""

    # GitLab setup
    if docker ps --format '{{.Names}}' | grep -q "^brik-gitlab$"; then
        log_info "Configuring GitLab..."
        bash "${SCRIPT_DIR}/setup-gitlab.sh"
    else
        log_warn "GitLab is not running - skipping"
    fi

    # Runner setup
    if docker ps --format '{{.Names}}' | grep -q "^brik-runner$"; then
        log_info "Registering runner..."
        bash "${SCRIPT_DIR}/setup-runner.sh"
    else
        log_warn "Runner is not running - skipping"
    fi

    # Jenkins setup (if level 2)
    if docker ps --format '{{.Names}}' | grep -q "^brik-jenkins$"; then
        log_info "Configuring Jenkins..."
        bash "${SCRIPT_DIR}/setup-jenkins.sh"
    fi

    echo ""
    log_ok "Configuration complete"
}

cmd_k3d_start() {
    check_prereqs

    if ! command -v k3d &>/dev/null; then
        log_error "k3d not installed: brew install k3d"
        exit 1
    fi

    log_info "Starting k3d cluster + ArgoCD..."
    bash "${SCRIPT_DIR}/setup-k3d.sh"
    log_ok "k3d cluster ready"
}

cmd_k3d_stop() {
    if ! command -v k3d &>/dev/null; then
        log_error "k3d not installed"
        exit 1
    fi

    log_info "Destroying k3d cluster..."
    k3d cluster delete brik 2>/dev/null || true
    log_ok "k3d cluster deleted"
}

cmd_clean() {
    echo -e "${RED}WARNING: This action deletes ALL persistent data.${NC}"
    echo -e "${RED}GitLab, Registry, Gitea, Jenkins volumes will be lost.${NC}"
    echo ""
    read -rp "Confirm deletion (type 'yes'): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Cancelled"
        exit 0
    fi

    cmd_stop
    log_info "Deleting data..."
    rm -rf "${BRIKLAB_DIR}/data"
    mkdir -p "${BRIKLAB_DIR}/data"
    log_ok "Data deleted"
}

cmd_smoke_test() {
    check_prereqs
    load_env
    log_info "Running smoke tests..."
    bash "${SCRIPT_DIR}/smoke-test.sh"
}

cmd_init() {
    local mode="${1:-}"

    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Briklab - Initialization       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    # 1. Prerequisites
    log_info "Step 1/5 - Checking prerequisites"
    check_prereqs
    log_ok "Prerequisites OK"

    # 2. .env file
    log_info "Step 2/5 - Preparing .env"
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "${BRIKLAB_DIR}/.env.example" "$ENV_FILE"
        log_ok ".env created from .env.example"
    else
        log_warn ".env already exists - keeping it"
    fi
    load_env

    # 3. Start containers
    log_info "Step 3/5 - Starting containers"
    cmd_start "$mode"

    # 4. Configuration (PAT, project, runner)
    log_info "Step 4/5 - Configuring GitLab + Runner"
    cmd_setup

    # 5. Smoke tests
    log_info "Step 5/5 - Verification"
    cmd_smoke_test

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Briklab ready - happy coding!      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    cmd_status
}

# === HELP ===

cmd_help() {
    cat <<EOF
Briklab - CLI

Usage: ./scripts/briklab.sh <command> [options]

Commands:
  init [--full]      Automated first launch (start + setup + smoke-test)
  start [--full]     Start the briklab (MVP or full)
  stop               Stop all containers
  restart [--full]   Restart
  status             Service status and URLs
  logs <service>     Service logs
  setup              Configuration (PAT, project, runner)
  k3d-start          Start k3d cluster + ArgoCD
  k3d-stop           Destroy the k3d cluster
  clean              Delete all data (irreversible)
  smoke-test         Verify each component
  help               Show this help

Examples:
  ./scripts/briklab.sh init            # Automated full first launch
  ./scripts/briklab.sh init --full     # Same with Gitea + Jenkins
  ./scripts/briklab.sh start           # MVP (GitLab + Runner + Registry)
  ./scripts/briklab.sh smoke-test      # Verification
EOF
}

# === DISPATCH ===

case "${1:-help}" in
    init)        cmd_init "${2:-}" ;;
    start)       cmd_start "${2:-}" ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart "${2:-}" ;;
    status)      cmd_status ;;
    logs)        cmd_logs "${2:-}" ;;
    setup)       cmd_setup ;;
    k3d-start)   cmd_k3d_start ;;
    k3d-stop)    cmd_k3d_stop ;;
    clean)       cmd_clean ;;
    smoke-test)  cmd_smoke_test ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: ${1}"
        cmd_help
        exit 1
        ;;
esac
