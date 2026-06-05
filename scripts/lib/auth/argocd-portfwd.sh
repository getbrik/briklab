#!/usr/bin/env bash
# ArgoCD port-forward management - verify or restart kubectl port-forward.
#
# Usage:
#   source "path/to/auth/argocd-portfwd.sh"
#   briklab.auth.argocd_portfwd

[[ -n "${_BRIKLAB_ARGOCD_PORTFWD_LOADED:-}" ]] && return 0
_BRIKLAB_ARGOCD_PORTFWD_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
# shellcheck source=../checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/../checks.sh"

# Ensure ArgoCD port-forward is active on the configured port.
# Restarts it if not reachable.
briklab.auth.argocd_portfwd() {
    local port="${ARGOCD_PORT:-9080}"

    # Already active? (shared probe with verify/preflight)
    if briklab.check.argocd_portfwd; then
        log_ok "ArgoCD port-forward active on :${port}"
        return 0
    fi

    log_warn "ArgoCD port-forward not active, (re)starting..."

    # Kill any stale kubectl port-forward holding this port.
    pkill -f "port-forward.*${port}" 2>/dev/null || true
    sleep 1

    nohup kubectl port-forward svc/argocd-server -n argocd "${port}:443" &>/dev/null &

    # Wait for the port-forward to answer (same probe as checks/preflight).
    if briklab.wait.until 30 3 briklab.check.argocd_portfwd; then
        log_ok "ArgoCD port-forward ready on :${port}"
        return 0
    fi

    log_error "Could not establish ArgoCD port-forward on :${port} after 30s"
    return 1
}
