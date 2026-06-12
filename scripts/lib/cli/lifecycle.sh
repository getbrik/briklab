#!/usr/bin/env bash
# Briklab CLI - lifecycle commands (start/stop/restart/status/logs/clean/k3d/init).
#
# Sourced by scripts/briklab.sh. Relies on the dispatcher's shared state:
#   vars:      SCRIPT_DIR, BRIKLAB_DIR, COMPOSE_FILE, LIB_SETUP, ENV_FILE, colors
#   functions: check_prereqs, load_env, log_*, reload_env, cmd_status (status used
#              by start), and cmd_setup/cmd_smoke_test/cmd_k3d_start (init only).
# Not meant to run standalone.

[[ -n "${_BRIKLAB_CLI_LIFECYCLE_LOADED:-}" ]] && return 0
_BRIKLAB_CLI_LIFECYCLE_LOADED=1

cmd_start() {
    check_prereqs
    load_env
    load_versions

    # Pre-create bind-mount files/dirs so Docker doesn't create them as directories
    mkdir -p "${BRIKLAB_DIR}/data/ssh-target"
    touch "${BRIKLAB_DIR}/data/ssh-target/authorized_keys"
    mkdir -p "${BRIKLAB_DIR}/data/gitlab-runner"
    mkdir -p "${BRIKLAB_DIR}/data/k3d"
    [[ -d "${BRIKLAB_DIR}/data/k3d/kubeconfig" ]] && rm -rf "${BRIKLAB_DIR}/data/k3d/kubeconfig"
    touch "${BRIKLAB_DIR}/data/k3d/kubeconfig"

    # The TLS services mount their certificates at boot (Gitea crashes on a
    # missing CERT_FILE), so the lab CA must exist BEFORE compose up -- the
    # setup pass that follows init's start is too late on a fresh lab.
    bash "${LIB_SETUP}/ca.sh"

    log_info "Starting containers..."
    docker compose -f "$COMPOSE_FILE" up -d

    log_ok "Containers started"
    cmd_status
}

cmd_stop() {
    load_env
    load_versions
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
    echo "  Gitea    : https://${gitea_host}:${gitea_port}"
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

    # 6. Token convergence: setup seeds the GitLab CI variables BEFORE Gitea
    # regenerates its PAT and before k3d generates the ArgoCD token, so a
    # fresh init must re-propagate the final values to the CI platforms.
    log_info "Step 6 -- Token propagation"
    bash "${SCRIPT_DIR}/lib/infra-refresh.sh"

    # 7. Smoke test
    log_info "Step 7 -- Verification"
    cmd_smoke_test

    cmd_status
}
