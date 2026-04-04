#!/usr/bin/env bash
# Briklab - Main CLI
# Usage: ./scripts/briklab.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_SETUP="${SCRIPT_DIR}/lib/setup"
LIB_E2E="${SCRIPT_DIR}/lib/e2e"
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

    # Ensure root password is set after GitLab becomes healthy
    if docker ps --format '{{.Names}}' | grep -q "^brik-gitlab$"; then
        _ensure_gitlab_password
    fi

    echo ""
    cmd_status
}

# Wait for GitLab to be healthy and set the root password.
# This ensures the documented password always works, even after a simple 'start'.
_ensure_gitlab_password() {
    local max_attempts=60
    local attempt=0

    log_info "Waiting for GitLab to be healthy..."
    while [[ $attempt -lt $max_attempts ]]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' brik-gitlab 2>/dev/null || echo "unknown")
        if [[ "$health" == "healthy" ]]; then
            break
        fi
        attempt=$((attempt + 1))
        printf "."
        sleep 5
    done
    echo ""

    if [[ $attempt -ge $max_attempts ]]; then
        log_warn "GitLab not healthy after $((max_attempts * 5))s - skipping password setup"
        return 0
    fi

    local password="${GITLAB_ROOT_PASSWORD:-changeme_gitlab_root}"
    log_info "Ensuring root password is set..."

    local result
    result=$(cat <<RUBY | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
user = User.find_by_username("root")
user.password = "${password}"
user.password_confirmation = "${password}"
user.password_automatically_set = false
user.password_expires_at = nil
if user.save
  puts "OK"
else
  puts "FAIL: #{user.errors.full_messages.join(', ')}"
end
RUBY
)

    if [[ "$result" == "OK" ]]; then
        log_ok "Root password configured"
    else
        log_warn "Password setup: ${result:-no output}"
    fi
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
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null | tr -d '[:space:]')
            health="${health:-none}"
            case "$health" in
                healthy)   echo -e "  ${GREEN}●${NC} ${container} (healthy)" ;;
                starting)  echo -e "  ${YELLOW}●${NC} ${container} (starting...)" ;;
                none)      echo -e "  ${GREEN}●${NC} ${container} (running)" ;;
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
        bash "${LIB_SETUP}/gitlab.sh"
    else
        log_warn "GitLab is not running - skipping"
    fi

    # Runner setup
    if docker ps --format '{{.Names}}' | grep -q "^brik-runner$"; then
        log_info "Registering runner..."
        bash "${LIB_SETUP}/runner.sh"
    else
        log_warn "Runner is not running - skipping"
    fi

    # Gitea setup (if level 2)
    if docker ps --format '{{.Names}}' | grep -q "^brik-gitea$"; then
        log_info "Configuring Gitea..."
        bash "${LIB_SETUP}/gitea.sh"
    fi

    # Jenkins setup (if level 2)
    if docker ps --format '{{.Names}}' | grep -q "^brik-jenkins$"; then
        log_info "Configuring Jenkins..."
        bash "${LIB_SETUP}/jenkins.sh"
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
    bash "${LIB_SETUP}/k3d.sh"
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
    bash "${LIB_SETUP}/smoke-test.sh"
}

cmd_test() {
    check_prereqs
    load_env

    local mode=""
    local project=""
    local jenkins_job=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)    mode="all"; shift ;;
            --list)   mode="list"; shift ;;
            --jenkins)
                mode="jenkins"
                jenkins_job="${2:-node-minimal}"
                if [[ "$jenkins_job" == --* ]]; then
                    jenkins_job="node-minimal"
                else
                    shift
                fi
                shift
                ;;
            --project)
                mode="project"
                project="${2:-}"
                if [[ -z "$project" ]]; then
                    log_error "Usage: briklab.sh test --project <name>"
                    exit 1
                fi
                shift 2
                ;;
            *) shift ;;
        esac
    done

    case "$mode" in
        list)
            bash "${LIB_E2E}/e2e-run-suite.sh" --list
            ;;
        all)
            bash "${LIB_E2E}/e2e-run-suite.sh"
            ;;
        project)
            bash "${LIB_E2E}/e2e-run-suite.sh" --only "$project"
            ;;
        jenkins)
            log_info "=== Jenkins E2E Test ==="
            echo ""
            log_info "Step 1/2 - Pushing repos to Gitea..."
            E2E_JENKINS_PROJECTS="$jenkins_job" bash "${LIB_E2E}/push-test-project-gitea.sh"
            echo ""
            log_info "Step 2/2 - Running Jenkins pipeline test..."
            E2E_JENKINS_JOB="$jenkins_job" bash "${LIB_E2E}/e2e-jenkins-test.sh"
            ;;
        *)
            # Default: run node-minimal scenario via the suite orchestrator
            bash "${LIB_E2E}/e2e-run-suite.sh" --only node-minimal
            ;;
    esac
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
Briklab - Local CI/CD test infrastructure for Brik

Usage: ./scripts/briklab.sh <command> [options]

Getting started:
  First time? Run 'init'. It does everything automatically:
  starts containers, configures GitLab + Runner, and runs smoke tests.

  Already initialized? Use 'start' to restart the containers.

Lifecycle:
  init [--full]      First launch (runs: start + setup + smoke-test)
  start [--full]     Start containers (+ set root password)
  stop               Stop all containers
  restart [--full]   Stop + start
  clean              Delete all data and volumes (irreversible)

Configuration:
  setup              Re-run GitLab/Runner/Jenkins configuration
                     (only needed if setup failed during init)
  smoke-test         Verify that each component is reachable

Testing:
  test               Push Brik repos to GitLab and run E2E pipeline (node-minimal)
  test --all         Run full E2E test suite (all scenarios)
  test --project X   Run a single E2E scenario by name
  test --jenkins [X] Push repos to Gitea and run Jenkins pipeline (default: node-minimal)
  test --list        List available E2E scenarios

Monitoring:
  status             Show container health and access URLs
  logs <service>     Tail logs (gitlab, runner, registry, gitea, jenkins)

Kubernetes (optional):
  k3d-start          Create k3d cluster + install ArgoCD
  k3d-stop           Destroy the k3d cluster

Options:
  --full             Also start Level 2 services (Gitea + Jenkins)
  help               Show this help

Typical workflow:
  ./scripts/briklab.sh init            # First time setup (5 min)
  ./scripts/briklab.sh test            # Run E2E pipeline test
  ./scripts/briklab.sh stop            # Done for the day
  ./scripts/briklab.sh start           # Next day, just start
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
    test)        cmd_test "${@:2}" ;;
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
