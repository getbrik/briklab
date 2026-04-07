#!/usr/bin/env bash
# Briklab - Main CLI
# Usage: ./scripts/briklab.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_SETUP="${SCRIPT_DIR}/lib/setup"
LIB_E2E="${SCRIPT_DIR}/lib/e2e"
COMPOSE_FILE="${BRIKLAB_DIR}/docker-compose.yml"
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

# === HELPERS ===

# Reload Jenkins CasC configuration without a full restart.
# Use when only CasC YAML changed (e.g. new job definitions).
# For env var changes (e.g. NEXUS_NPM_TOKEN), a full restart is needed.
jenkins_reload_casc() {
    local jenkins_url="http://${JENKINS_HOSTNAME:-localhost}:${JENKINS_HTTP_PORT:-9090}"
    local crumb
    crumb=$(curl -sf -u "admin:${JENKINS_ADMIN_PASSWORD:-changeme_jenkins}" \
        "${jenkins_url}/crumbIssuer/api/json" | jq -r '.crumb') || {
        log_error "Failed to get Jenkins crumb - is Jenkins running?"
        return 1
    }
    curl -sf -X POST -u "admin:${JENKINS_ADMIN_PASSWORD:-changeme_jenkins}" \
        -H "Jenkins-Crumb: ${crumb}" \
        "${jenkins_url}/configuration-as-code/reload" || {
        log_error "Failed to reload Jenkins CasC"
        return 1
    }
    log_ok "Jenkins CasC reloaded"
}

# === COMMANDS ===

cmd_start() {
    check_prereqs
    load_env

    log_info "Starting all containers..."
    docker compose -f "$COMPOSE_FILE" up -d

    log_ok "Containers started"
    log_info "GitLab takes 3-5 min, Nexus 2-3 min on first start"

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
    local health=""

    log_info "Waiting for GitLab to be healthy..."
    while [[ $attempt -lt $max_attempts ]]; do
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

    local password="${GITLAB_ROOT_PASSWORD:-Brik-Gitlab-2026!}"
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
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    log_ok "Containers stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    load_env
    echo ""
    echo -e "${BLUE}=== Briklab - Status ===${NC}"
    echo ""

    local gitlab_port="${GITLAB_HTTP_PORT:-8929}"
    local registry_port="${REGISTRY_PORT:-5050}"
    local gitea_port="${GITEA_HTTP_PORT:-3000}"
    local jenkins_port="${JENKINS_HTTP_PORT:-9090}"
    local nexus_port="${NEXUS_HTTP_PORT:-8081}"
    local gitlab_host="${GITLAB_HOSTNAME:-gitlab.briklab.test}"
    local registry_host="${REGISTRY_HOSTNAME:-registry.briklab.test}"
    local gitea_host="${GITEA_HOSTNAME:-gitea.briklab.test}"
    local jenkins_host="${JENKINS_HOSTNAME:-jenkins.briklab.test}"
    local nexus_host="${NEXUS_HOSTNAME:-nexus.briklab.test}"

    # Check each container
    local health=""
    for container in brik-gitlab brik-runner brik-registry brik-gitea brik-jenkins brik-nexus; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
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
    echo "  GitLab   : http://${gitlab_host}:${gitlab_port}"
    echo "  Registry : http://${registry_host}:${registry_port}/v2/_catalog"
    echo "  Gitea    : http://${gitea_host}:${gitea_port}"
    echo "  Jenkins  : http://${jenkins_host}:${jenkins_port}"
    echo "  Nexus    : http://${nexus_host}:${nexus_port}"
    echo ""
}

cmd_logs() {
    local service="${1:-}"
    if [[ -z "$service" ]]; then
        log_error "Usage: briklab.sh logs <service>"
        log_info "Services: gitlab, gitlab-runner, registry, gitea, jenkins, nexus"
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

    # Gitea setup
    if docker ps --format '{{.Names}}' | grep -q "^brik-gitea$"; then
        log_info "Configuring Gitea..."
        bash "${LIB_SETUP}/gitea.sh"
    fi

    # Jenkins setup
    if docker ps --format '{{.Names}}' | grep -q "^brik-jenkins$"; then
        log_info "Configuring Jenkins..."
        bash "${LIB_SETUP}/jenkins.sh"
    fi

    # Nexus setup
    if docker ps --format '{{.Names}}' | grep -q "^brik-nexus$"; then
        log_info "Configuring Nexus..."
        bash "${LIB_SETUP}/nexus.sh"
    fi

    # After Nexus setup, restart Jenkins to pick up new env vars (.env may have changed)
    if docker ps --format '{{.Names}}' | grep -q "^brik-jenkins$" \
       && docker ps --format '{{.Names}}' | grep -q "^brik-nexus$"; then
        log_info "Restarting Jenkins to pick up Nexus credentials..."
        docker restart brik-jenkins
        local jenkins_url="http://${JENKINS_HOSTNAME:-localhost}:${JENKINS_HTTP_PORT:-9090}"
        local attempts=0
        while [[ $attempts -lt 60 ]]; do
            if curl -sf "${jenkins_url}/login" -o /dev/null 2>/dev/null; then
                break
            fi
            attempts=$((attempts + 1))
            sleep 2
        done
        if [[ $attempts -ge 60 ]]; then
            log_warn "Jenkins did not become ready after restart"
        else
            log_ok "Jenkins restarted and ready"
        fi
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
    echo -e "${RED}GitLab, Registry, Gitea, Jenkins, Nexus volumes will be lost.${NC}"
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

    local platform=""          # gitlab or jenkins (required)
    local action=""            # (empty)=default, all, list, project, complete
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gitlab)    platform="gitlab"; shift ;;
            --jenkins)   platform="jenkins"; shift ;;
            --all)       action="all"; shift ;;
            --list)      action="list"; shift ;;
            --complete)  action="complete"; shift ;;
            --project)
                action="project"
                project="${2:-}"
                if [[ -z "$project" ]]; then
                    log_error "Usage: briklab.sh test --gitlab|--jenkins --project <name>"
                    exit 1
                fi
                shift 2
                ;;
            *) shift ;;
        esac
    done

    if [[ -z "$platform" ]]; then
        log_error "Platform required. Use --gitlab or --jenkins."
        log_info "Examples:"
        log_info "  briklab.sh test --gitlab"
        log_info "  briklab.sh test --jenkins --all"
        exit 1
    fi

    if [[ "$platform" == "jenkins" ]]; then
        local suite="${LIB_E2E}/e2e-jenkins-suite.sh"
        case "$action" in
            list)     bash "$suite" --list ;;
            all)      bash "$suite" ;;
            complete) bash "$suite" --complete ;;
            project)  bash "$suite" --only "$project" ;;
            *)        bash "$suite" --only node-minimal ;;
        esac
    else
        local suite="${LIB_E2E}/e2e-gitlab-suite.sh"
        case "$action" in
            list)     bash "$suite" --list ;;
            all)      bash "$suite" ;;
            complete) bash "$suite" --complete ;;
            project)  bash "$suite" --only "$project" ;;
            *)        bash "$suite" --only node-minimal ;;
        esac
    fi
}

cmd_init() {
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
    cmd_start

    # 4. Configuration
    log_info "Step 4/5 - Configuring services"
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
  starts all containers, configures services, and runs smoke tests.

  Already initialized? Use 'start' to restart the containers.

Lifecycle:
  init               First launch (start + setup + smoke-test)
  start              Start all containers (+ set root password)
  stop               Stop all containers
  restart            Stop + start
  clean              Delete all data and volumes (irreversible)

Configuration:
  setup              Re-run GitLab/Runner/Gitea/Jenkins/Nexus configuration
                     (only needed if setup failed during init)
  smoke-test         Verify that each component is reachable

Testing (--gitlab or --jenkins required):
  test --gitlab              Run node-minimal on GitLab
  test --gitlab --all        Run full GitLab E2E suite
  test --gitlab --complete   Run only *-complete scenarios
  test --gitlab --project X  Run a single GitLab scenario
  test --gitlab --list       List available GitLab scenarios
  test --jenkins             Run node-minimal on Jenkins
  test --jenkins --all       Run full Jenkins E2E suite
  test --jenkins --complete  Run only *-complete scenarios
  test --jenkins --project X Run a single Jenkins scenario
  test --jenkins --list      List available Jenkins scenarios

Monitoring:
  status             Show container health and access URLs
  logs <service>     Tail logs (gitlab, runner, registry, gitea, jenkins, nexus)

Kubernetes (optional):
  k3d-start          Create k3d cluster + install ArgoCD
  k3d-stop           Destroy the k3d cluster

Typical workflow:
  ./scripts/briklab.sh init                  # First time setup (~5 min)
  ./scripts/briklab.sh test --gitlab         # Run GitLab E2E test
  ./scripts/briklab.sh test --jenkins        # Run Jenkins E2E test
  ./scripts/briklab.sh stop                  # Done for the day
  ./scripts/briklab.sh start                 # Next day, just start
EOF
}

# === DISPATCH ===

case "${1:-help}" in
    init)        cmd_init ;;
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart ;;
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
