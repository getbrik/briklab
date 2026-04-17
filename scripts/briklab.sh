#!/usr/bin/env bash
# Briklab - Main CLI
# Usage: ./scripts/briklab.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_SETUP="${SCRIPT_DIR}/lib/setup"
LIB_E2E="${SCRIPT_DIR}/lib/e2e"
COMPOSE_FILE="${BRIKLAB_DIR}/docker-compose.yml"

# shellcheck source=lib/common.sh
BRIKLAB_ROOT="$BRIKLAB_DIR" source "${SCRIPT_DIR}/lib/common.sh"

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

# Load .env if present (overrides common.sh load_env with a warning)
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        reload_env
    else
        log_warn ".env not found - using default values"
        log_info "Copy .env.example to .env: cp .env.example .env"
    fi
}

# === HELPERS ===

# Reload Jenkins CasC configuration without a full restart.
# Use when only CasC YAML changed (e.g. new job definitions).
# For env var changes (e.g. BRIK_PUBLISH_NPM_TOKEN), a full restart is needed.
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

    # Pre-create bind-mount files/dirs so Docker doesn't create them as directories
    mkdir -p "${BRIKLAB_DIR}/data/ssh-target"
    touch "${BRIKLAB_DIR}/data/ssh-target/authorized_keys"
    mkdir -p "${BRIKLAB_DIR}/data/gitlab-runner"
    mkdir -p "${BRIKLAB_DIR}/data/k3d"
    [[ -d "${BRIKLAB_DIR}/data/k3d/kubeconfig" ]] && rm -rf "${BRIKLAB_DIR}/data/k3d/kubeconfig"
    touch "${BRIKLAB_DIR}/data/k3d/kubeconfig"

    log_info "Starting containers..."
    docker compose -f "$COMPOSE_FILE" up -d

    log_ok "Containers started"
    cmd_status
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
    local gitea_port="${GITEA_HTTP_PORT:-3000}"
    local jenkins_port="${JENKINS_HTTP_PORT:-9090}"
    local nexus_port="${NEXUS_HTTP_PORT:-8081}"
    local gitlab_host="${GITLAB_HOSTNAME:-gitlab.briklab.test}"
    local gitea_host="${GITEA_HOSTNAME:-gitea.briklab.test}"
    local jenkins_host="${JENKINS_HOSTNAME:-jenkins.briklab.test}"
    local nexus_host="${NEXUS_HOSTNAME:-nexus.briklab.test}"

    # Check each container
    local health=""
    for container in brik-gitlab brik-runner brik-gitea brik-jenkins brik-nexus; do
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
    echo "  Gitea    : http://${gitea_host}:${gitea_port}"
    echo "  Jenkins  : http://${jenkins_host}:${jenkins_port}"
    echo "  Nexus    : http://${nexus_host}:${nexus_port}"
    echo ""
}

cmd_logs() {
    local service="${1:-}"
    if [[ -z "$service" ]]; then
        log_error "Usage: briklab.sh logs <service>"
        log_info "Services: gitlab, gitlab-runner, gitea, jenkins, nexus, ssh-target"
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
    # shellcheck source=lib/verify.sh
    source "${SCRIPT_DIR}/lib/verify.sh"

    local errors=0

    # 1. GitLab
    _run_setup "GitLab" "gitlab.sh" "brik-gitlab" && {
        load_env
        verify_gitlab_pat || ((errors++)) || true
        verify_env_set "GITLAB_RUNNER_TOKEN" || ((errors++)) || true
    }

    # 2. Runner
    _run_setup "Runner" "runner.sh" "brik-runner" && {
        verify_cmd "Runner config" "docker exec brik-runner grep -q url /etc/gitlab-runner/config.toml" || ((errors++)) || true
    }

    # 3. Gitea
    _run_setup "Gitea" "gitea.sh" "brik-gitea" && {
        load_env
        verify_gitea_pat || ((errors++)) || true
    }

    # 4. Jenkins
    _run_setup "Jenkins" "jenkins.sh" "brik-jenkins" && {
        verify_http "Jenkins login" "http://${JENKINS_HOSTNAME:-localhost}:${JENKINS_HTTP_PORT:-9090}/login" || ((errors++)) || true
    }

    # 5. Nexus
    _run_setup "Nexus" "nexus.sh" "brik-nexus" && {
        load_env
        verify_nexus_auth || ((errors++)) || true
        verify_env_set "NEXUS_NPM_TOKEN" || ((errors++)) || true
    }

    # 6. SSH target
    _run_setup "SSH target" "ssh-target.sh" "brik-ssh-target" && {
        verify_ssh_connection || ((errors++)) || true
    }

    # 7. Restart Jenkins (to pick up Nexus env vars)
    if docker ps --format '{{.Names}}' | grep -q "^brik-jenkins$"; then
        log_info "Restarting Jenkins..."
        docker restart brik-jenkins >/dev/null
        _wait_for_http "Jenkins" "http://${JENKINS_HOSTNAME:-localhost}:${JENKINS_HTTP_PORT:-9090}/login" 120
    fi

    # Summary
    if [[ $errors -eq 0 ]]; then
        log_ok "Setup complete -- all verifications passed"
    else
        log_error "Setup complete -- ${errors} verification(s) failed"
        return 1
    fi
}

# Launch a setup script if its container is running
_run_setup() {
    local name="$1" script="$2" container="$3"
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_info "Configuring ${name}..."
        bash "${LIB_SETUP}/${script}"
    else
        log_warn "${name} not running -- skipping"
        return 1
    fi
}

# Wait for an HTTP endpoint to respond
_wait_for_http() {
    local name="$1" url="$2" timeout="${3:-60}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf -o /dev/null "$url" 2>/dev/null; then
            log_ok "${name} ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_warn "${name} not ready after ${timeout}s"
    return 1
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
    if [[ "${1:-}" != "--yes" ]]; then
        echo -e "${RED}WARNING: This action deletes ALL persistent data.${NC}"
        echo -e "${RED}GitLab, Gitea, Jenkins, Nexus volumes will be lost.${NC}"
        echo ""
        read -rp "Confirm deletion (type 'yes'): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Cancelled"
            exit 0
        fi
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
    local batch_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gitlab)    platform="gitlab"; shift ;;
            --jenkins)   platform="jenkins"; shift ;;
            --all)       action="all"; shift ;;
            --list)      action="list"; shift ;;
            --complete)  action="complete"; shift ;;
            --batch-size)
                batch_args=(--batch-size "${2:-}")
                if [[ -z "${2:-}" ]]; then
                    log_error "--batch-size requires a number"
                    exit 1
                fi
                shift 2
                ;;
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
            all)      bash "$suite" ${batch_args[@]+"${batch_args[@]}"} ;;
            complete) bash "$suite" --complete ${batch_args[@]+"${batch_args[@]}"} ;;
            project)  bash "$suite" --only "$project" ;;
            *)        bash "$suite" --only node-minimal ;;
        esac
    else
        local suite="${LIB_E2E}/e2e-gitlab-suite.sh"
        case "$action" in
            list)     bash "$suite" --list ;;
            all)      bash "$suite" ${batch_args[@]+"${batch_args[@]}"} ;;
            complete) bash "$suite" --complete ${batch_args[@]+"${batch_args[@]}"} ;;
            project)  bash "$suite" --only "$project" ;;
            *)        bash "$suite" --only node-minimal ;;
        esac
    fi
}

cmd_init() {
    # 1. Prerequisites
    log_info "Step 1 -- Prerequisites"
    check_prereqs
    log_ok "Prerequisites OK"

    # 2. .env
    log_info "Step 2 -- Environment"
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "${BRIKLAB_DIR}/.env.example" "$ENV_FILE"
        log_ok ".env created"
    fi
    load_env

    # 3. Start containers
    log_info "Step 3 -- Starting containers"
    cmd_start

    # 4. Setup
    log_info "Step 4 -- Configuring services"
    cmd_setup

    # 5. k3d (if installed)
    if command -v k3d &>/dev/null; then
        log_info "Step 5 -- k3d cluster + ArgoCD"
        cmd_k3d_start
    else
        log_warn "Step 5 -- k3d not installed, skipping"
    fi

    # 6. Smoke test
    log_info "Step 6 -- Verification"
    cmd_smoke_test

    cmd_status
}

# === HELP ===

cmd_help() {
    cat <<EOF
Briklab - Local CI/CD test infrastructure for Brik

Usage: ./scripts/briklab.sh <command> [options]

Getting started:
  First time? Run 'init'. It does everything automatically:
  starts all containers, configures services, sets up k3d, and runs smoke tests.

  Already initialized? Use 'start' to restart the containers.

Lifecycle:
  init               First launch (start + setup + k3d + smoke-test)
  start              Start all containers
  stop               Stop all containers
  restart            Stop + start
  clean              Delete all data and volumes (irreversible)

Configuration:
  setup              Re-run GitLab/Runner/Gitea/Jenkins/Nexus/SSH configuration
                     with verification (only needed if setup failed during init)
  smoke-test         Verify that each component is reachable
  preflight          Validate tokens, port-forwards, propagate to CI platforms

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
  --batch-size N             Run scenarios in parallel batches of N

Monitoring:
  status             Show container health and access URLs
  logs <service>     Tail logs (gitlab, runner, gitea, jenkins, nexus, ssh-target)

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
    clean)       cmd_clean "${@:2}" ;;
    smoke-test)  cmd_smoke_test ;;
    preflight)   bash "${LIB_E2E}/preflight.sh" ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: ${1}"
        cmd_help
        exit 1
        ;;
esac
