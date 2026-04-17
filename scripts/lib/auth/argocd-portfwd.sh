#!/usr/bin/env bash
# ArgoCD port-forward management - verify or restart kubectl port-forward.
#
# Usage:
#   source "path/to/auth/argocd-portfwd.sh"
#   ensure_argocd_port_forward

[[ -n "${_BRIKLAB_ARGOCD_PORTFWD_LOADED:-}" ]] && return 0
_BRIKLAB_ARGOCD_PORTFWD_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# Ensure ArgoCD port-forward is active on the configured port.
# Restarts it if not reachable.
ensure_argocd_port_forward() {
    local port="${ARGOCD_PORT:-9080}"
    local max_attempts=10
    local wait_sec=3
    local attempt=0

    # Already active?
    if curl -sk -o /dev/null -w "%{http_code}" "https://localhost:${port}/api/version" 2>/dev/null | grep -q "200"; then
        log_ok "ArgoCD port-forward active on :${port}"
        return 0
    fi

    log_warn "ArgoCD port-forward not active, (re)starting..."

    # Kill stale port-forward
    kill $(lsof -t -i:"${port}") 2>/dev/null || true
    sleep 1

    nohup kubectl port-forward svc/argocd-server -n argocd "${port}:443" &>/dev/null &

    # Wait for port-forward to become ready
    while [[ $attempt -lt $max_attempts ]]; do
        sleep "$wait_sec"
        attempt=$((attempt + 1))
        if curl -sk -o /dev/null -w "%{http_code}" "https://localhost:${port}/api/version" 2>/dev/null | grep -q "200"; then
            log_ok "ArgoCD port-forward ready on :${port} (attempt ${attempt}/${max_attempts})"
            return 0
        fi
        log_info "Waiting for port-forward... (${attempt}/${max_attempts})"
    done

    log_error "Could not establish ArgoCD port-forward on :${port} after ${max_attempts} attempts"
    return 1
}
