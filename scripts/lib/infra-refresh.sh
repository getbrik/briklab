#!/usr/bin/env bash
# Infrastructure refresh for briklab.
#
# Validates and refreshes all tokens, ensures port-forwards are active, and
# propagates fresh tokens to the CI platforms -- without recreating the lab.
# It is the platform-agnostic composition of the recovery layer: where
# `preflight --fix` heals one platform's readiness, infra-refresh heals every
# token + port-forward and then pushes them outward to GitLab/Jenkins.
#
# Usage:
#   bash infra-refresh.sh                        # Run all checks
#   source infra-refresh.sh && infra_refresh     # Use as a function
#
# Layering: depends directly on recovery.sh (briklab.recover.*), which already
# aggregates checks.sh predicates and the auth/* token helpers. No dependency
# on the E2E layer.
#
# Exit code: 0 if all checks pass, 1 if any critical check fails.
set -euo pipefail

# Guard against double-sourcing (harmless no-op when executed directly).
[[ -n "${_BRIKLAB_INFRA_REFRESH_LOADED:-}" ]] && return 0
_BRIKLAB_INFRA_REFRESH_LOADED=1

INFRA_REFRESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# recovery.sh transitively provides common.sh (log/env/http/wait), checks.sh
# (briklab.check.*) and the auth/* token helpers (briklab.auth.* via
# briklab.recover.*). Sourcing it here keeps infra-refresh in the orchestration
# layer instead of reaching down through e2e/lib/auth.sh.
# shellcheck source=recovery.sh
source "${INFRA_REFRESH_DIR}/recovery.sh"

# ---------------------------------------------------------------------------
# Docker services
# ---------------------------------------------------------------------------

check_docker_services() {
    log_info "Checking Docker services..."
    local failed=0

    for svc in brik-gitlab brik-gitea brik-jenkins brik-nexus; do
        if briklab.check.container_running "$svc"; then
            log_ok "$svc running"
        else
            log_warn "$svc not running"
            failed=1
        fi
    done

    return $failed
}

# ---------------------------------------------------------------------------
# k3d cluster + ArgoCD port-forward
# ---------------------------------------------------------------------------

check_k3d_and_argocd() {
    log_info "Checking k3d cluster..."

    if ! kubectl cluster-info &>/dev/null; then
        log_error "k3d cluster not reachable"
        return 1
    fi
    log_ok "k3d cluster reachable"

    local ready
    ready=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$ready" != "True" ]]; then
        log_warn "ArgoCD server pod not ready, waiting..."
        kubectl wait --for=condition=ready --timeout=60s pod \
            -l app.kubernetes.io/name=argocd-server -n argocd 2>/dev/null || {
            log_error "ArgoCD server pod not ready after 60s"
            return 1
        }
    fi
    log_ok "ArgoCD server pod ready"

    briklab.recover.argocd_portfwd
}

# ---------------------------------------------------------------------------
# Main: infra_refresh
# ---------------------------------------------------------------------------

infra_refresh() {
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Briklab Infrastructure Refresh${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env not found at ${ENV_FILE}"
        return 1
    fi
    reload_env

    local errors=0

    # Docker services
    check_docker_services || errors=$((errors + 1))
    echo ""

    # k3d + port-forward
    check_k3d_and_argocd || errors=$((errors + 1))
    echo ""

    # Tokens (may update .env) -- reuse the recovery layer's idempotent heals.
    log_info "Checking GitLab PAT..."
    briklab.recover.gitlab_pat || errors=$((errors + 1))
    log_info "Checking Gitea PAT..."
    briklab.recover.gitea_pat || errors=$((errors + 1))
    log_info "Checking ArgoCD API token..."
    briklab.recover.argocd_token || errors=$((errors + 1))
    echo ""

    # Reload .env to pick up any regenerated tokens before propagation
    reload_env
    log_ok ".env reloaded"
    echo ""

    # Propagate fresh tokens to CI platforms
    log_info "Propagating tokens to GitLab CI variables..."
    briklab.recover.gitlab_ci_vars || errors=$((errors + 1))
    log_info "Checking Jenkins token propagation..."
    briklab.recover.jenkins_token || errors=$((errors + 1))
    echo ""

    # Summary
    echo -e "${BOLD}========================================${NC}"
    if [[ $errors -eq 0 ]]; then
        log_ok "All checks passed -- .env is up to date"
    else
        log_error "${errors} check(s) failed"
    fi
    echo -e "${BOLD}========================================${NC}"

    return $errors
}

# Run directly if executed (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    infra_refresh
    exit $?
fi
