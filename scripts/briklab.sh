#!/usr/bin/env bash
# Briklab - Main CLI (thin dispatcher).
# Commands live in lib/cli/*.sh; shared helpers in lib/*.sh.
# Usage: ./scripts/briklab.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# LIB_SETUP/LIB_E2E/COMPOSE_FILE are consumed by the sourced lib/cli/*.sh
# modules below, not in this file -- hence the shellcheck exemption.
# shellcheck disable=SC2034
LIB_SETUP="${SCRIPT_DIR}/lib/setup"
# shellcheck disable=SC2034
LIB_E2E="${SCRIPT_DIR}/lib/e2e"
# shellcheck disable=SC2034
COMPOSE_FILE="${BRIKLAB_DIR}/docker-compose.yml"

# shellcheck source=lib/common.sh
BRIKLAB_ROOT="$BRIKLAB_DIR" source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/runner-images.sh
source "${SCRIPT_DIR}/lib/runner-images.sh"

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

# CLI command modules. Sourced AFTER the shared helpers above so their cmd_*
# functions resolve check_prereqs/load_env/log_*/SCRIPT_DIR/... at call time.
# shellcheck source=lib/cli/lifecycle.sh
source "${SCRIPT_DIR}/lib/cli/lifecycle.sh"
# shellcheck source=lib/cli/setup.sh
source "${SCRIPT_DIR}/lib/cli/setup.sh"
# shellcheck source=lib/cli/reset.sh
source "${SCRIPT_DIR}/lib/cli/reset.sh"
# shellcheck source=lib/cli/test.sh
source "${SCRIPT_DIR}/lib/cli/test.sh"

# preflight: E2E readiness gate (lib/preflight.sh is sourced by lib/cli/test.sh
# above, so briklab.preflight.e2e is already defined). Accepts --gitlab/--jenkins
# (like test) and forwards --with-deploy / --fix.
cmd_preflight() {
    check_prereqs
    load_env
    local platform="" rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gitlab)  platform="gitlab"; shift ;;
            --jenkins) platform="jenkins"; shift ;;
            *)         rest+=("$1"); shift ;;
        esac
    done
    if [[ -z "$platform" ]]; then
        log_error "Platform required. Use --gitlab or --jenkins."
        log_info "Examples: briklab.sh preflight --gitlab --with-deploy [--fix]"
        exit 1
    fi
    briklab.preflight.e2e "$platform" ${rest[@]+"${rest[@]}"}
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
  infra-refresh      Validate tokens, port-forwards, propagate to CI platforms
  preflight --gitlab|--jenkins [--with-deploy] [--fix]
                     Readiness gate (PAT, Nexus, ArgoCD, k3d node + controller).
                     --fix self-heals (regenerate token, restart NotReady node,
                     reschedule stranded controller), then re-verifies.

Testing (--gitlab or --jenkins required):
  test --gitlab              Run node-full on GitLab (default scenario)
  test --gitlab --all        Run full GitLab E2E suite
  test --gitlab --complete   Run only *-complete scenarios
  test --gitlab --project X  Run a single GitLab scenario
  test --gitlab --list       List available GitLab scenarios
  test --jenkins             Run node-full on Jenkins (default scenario)
  test --jenkins --all       Run full Jenkins E2E suite
  test --jenkins --complete  Run only *-complete scenarios
  test --jenkins --project X Run a single Jenkins scenario
  test --jenkins --list      List available Jenkins scenarios
  --stub                     Pin every stage to the stub image (any scenario)
  test self-heals the lab before running (preflight --fix). Opt out with:
  --no-repair                Detect issues but do not auto-heal
  --no-preflight             Skip the readiness gate entirely
  --batch-size N             Run scenarios in parallel batches of N
  --groups A,D,H             Run only scenarios in specified groups
  --parallel-groups          Auto-batch independent groups in parallel
Groups: B=full, C=complete, D=scan/cve, F=gitops, G=workflow, I=plan

Stub mode example:
  test --gitlab --project node-full --stub   Full workflow on the stub image

Reset (clean test state between runs):
  reset --gitlab             Full reset (repos + k8s + ArgoCD + artifacts)
  reset --jenkins            Full reset (repos + k8s + ArgoCD + artifacts)
  reset --gitlab --repos     Reset all GitLab repos to baseline
  reset --jenkins --repos    Reset all Jenkins/Gitea repos to baseline
  reset --gitlab --repos --only <name>  Reset a single repo
  reset --k8s                Clean all E2E k8s namespaces
  reset --argocd             Delete all E2E ArgoCD apps
  reset --artifacts          Clean Nexus + Docker registry artifacts

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
    reset)       cmd_reset "${@:2}" ;;
    preflight)   cmd_preflight "${@:2}" ;;
    k3d-start)   cmd_k3d_start ;;
    k3d-stop)    cmd_k3d_stop ;;
    clean)       cmd_clean "${@:2}" ;;
    smoke-test)  cmd_smoke_test ;;
    infra-refresh) bash "${SCRIPT_DIR}/lib/infra-refresh.sh" ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: ${1}"
        cmd_help
        exit 1
        ;;
esac
