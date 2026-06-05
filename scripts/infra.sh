#!/usr/bin/env bash
# Briklab infra - lifecycle dispatcher (thin).
# Owns the local stack lifecycle: create / start / stop / clean / k3d / versions.
# Test, reset, setup, status, logs and preflight live in scripts/briklab.sh.
# Driven by the root Makefile (make init/start/stop/...) or invoked directly.
# Usage: ./scripts/infra.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# LIB_SETUP/COMPOSE_FILE are consumed by the sourced lib/cli/*.sh modules below.
# shellcheck disable=SC2034
LIB_SETUP="${SCRIPT_DIR}/lib/setup"
# shellcheck disable=SC2034
COMPOSE_FILE="${BRIKLAB_DIR}/docker-compose.yml"

# shellcheck source=lib/common.sh
BRIKLAB_ROOT="$BRIKLAB_DIR" source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/cli/prereqs.sh
source "${SCRIPT_DIR}/lib/cli/prereqs.sh"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"

# Lifecycle commands (cmd_init/start/stop/restart/clean/k3d_*/status/logs).
# cmd_init orchestrates cmd_setup + cmd_smoke_test, so setup.sh is sourced too.
# shellcheck source=lib/cli/lifecycle.sh
source "${SCRIPT_DIR}/lib/cli/lifecycle.sh"
# shellcheck source=lib/cli/setup.sh
source "${SCRIPT_DIR}/lib/cli/setup.sh"

# versions: regenerate (or --check) the artifacts derived from versions.yml.
cmd_versions() {
    if [[ "${1:-}" == "--check" ]]; then
        briklab.versions.check
    else
        briklab.versions.generate
    fi
}

# === HELP ===

cmd_help() {
    cat <<EOF
Briklab infra - local CI/CD stack lifecycle

Usage: ./scripts/infra.sh <command> [options]   (or: make <command>)

Lifecycle:
  init               First launch (start + setup + k3d + smoke-test)
  start              Start all containers
  stop               Stop all containers
  restart            Stop + start
  clean [--yes]      Delete all data and volumes (irreversible)

Kubernetes:
  k3d-start          Create k3d cluster + install ArgoCD
  k3d-stop           Destroy the k3d cluster

Versions:
  versions           Regenerate versions.env + Jenkins plugins + image lock
  versions --check    Fail if any generated artifact drifts from versions.yml

Testing and configuration live in scripts/briklab.sh:
  ./scripts/briklab.sh test --gitlab|--jenkins
  ./scripts/briklab.sh setup | status | logs <svc> | reset | preflight
EOF
}

# === DISPATCH ===

case "${1:-help}" in
    init)        cmd_init ;;
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart ;;
    clean)       cmd_clean "${@:2}" ;;
    k3d-start)   cmd_k3d_start ;;
    k3d-stop)    cmd_k3d_stop ;;
    versions)    cmd_versions "${@:2}" ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: ${1}"
        cmd_help
        exit 1
        ;;
esac
