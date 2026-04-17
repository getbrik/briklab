#!/usr/bin/env bash
# Preflight checks for E2E tests.
#
# Validates and refreshes all tokens, ensures port-forwards are active,
# and verifies that all services are reachable. Designed to be run before
# E2E tests without needing to recreate the briklab infrastructure.
#
# Usage:
#   bash preflight.sh                  # Run all checks
#   source preflight.sh && preflight   # Use as a function
#
# What it does:
#   1. Loads .env
#   2. Checks Docker services (GitLab, Gitea, Jenkins, Nexus)
#   3. Checks k3d cluster and ArgoCD port-forward
#   4. Validates/refreshes GitLab PAT
#   5. Validates/refreshes Gitea PAT
#   6. Validates ArgoCD API token (regenerates if expired)
#   7. Reloads .env (picks up any regenerated tokens)
#   8. Propagates tokens to GitLab CI variables
#   9. Restarts Jenkins if its env is stale
#
# Exit code: 0 if all checks pass, 1 if any critical check fails.
set -euo pipefail

_PREFLIGHT_LOADED="${_PREFLIGHT_LOADED:-}"

# Resolve paths
PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$PREFLIGHT_DIR/../../.." && pwd)"

# shellcheck source=../common.sh
source "${PREFLIGHT_DIR}/../common.sh"
# shellcheck source=../auth/gitlab-pat.sh
source "${PREFLIGHT_DIR}/../auth/gitlab-pat.sh"
# shellcheck source=../auth/gitea-pat.sh
source "${PREFLIGHT_DIR}/../auth/gitea-pat.sh"
# shellcheck source=../auth/argocd-portfwd.sh
source "${PREFLIGHT_DIR}/../auth/argocd-portfwd.sh"
# shellcheck source=../auth/argocd-token.sh
source "${PREFLIGHT_DIR}/../auth/argocd-token.sh"

# ---------------------------------------------------------------------------
# 1. Docker services
# ---------------------------------------------------------------------------

check_docker_services() {
    log_info "Checking Docker services..."
    local failed=0

    for svc in brik-gitlab brik-gitea brik-jenkins brik-nexus; do
        if docker inspect --format='{{.State.Running}}' "$svc" 2>/dev/null | grep -q "true"; then
            log_ok "$svc running"
        else
            log_warn "$svc not running"
            failed=1
        fi
    done

    return $failed
}

# ---------------------------------------------------------------------------
# 2. k3d cluster + ArgoCD port-forward
# ---------------------------------------------------------------------------

check_k3d_and_argocd() {
    log_info "Checking k3d cluster..."

    if ! kubectl cluster-info &>/dev/null; then
        log_error "k3d cluster not reachable"
        return 1
    fi
    log_ok "k3d cluster reachable"

    # Check ArgoCD pods
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

    # Ensure port-forward is active
    ensure_argocd_port_forward
}

# ---------------------------------------------------------------------------
# 3. GitLab PAT
# ---------------------------------------------------------------------------

check_gitlab_pat() {
    log_info "Checking GitLab PAT..."
    ensure_gitlab_pat
}

# ---------------------------------------------------------------------------
# 4. Gitea PAT
# ---------------------------------------------------------------------------

check_gitea_pat() {
    log_info "Checking Gitea PAT..."
    ensure_gitea_pat
}

# ---------------------------------------------------------------------------
# 5. ArgoCD API token
# ---------------------------------------------------------------------------

check_argocd_token() {
    log_info "Checking ArgoCD API token..."
    ensure_argocd_token
}

# ---------------------------------------------------------------------------
# 6. Propagate tokens to CI platforms
# ---------------------------------------------------------------------------

propagate_to_gitlab() {
    log_info "Propagating tokens to GitLab CI variables..."
    local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"

    local group_id
    group_id=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${gitlab_url}/api/v4/groups?search=brik" 2>/dev/null | jq -r '.[0].id // empty') || true

    if [[ -z "$group_id" ]]; then
        log_warn "GitLab group 'brik' not found -- skipping CI variable propagation"
        return 0
    fi

    local -a vars_to_set=(
        "ARGOCD_SERVER:host.docker.internal:${ARGOCD_PORT:-9080}:false"
        "ARGOCD_AUTH_TOKEN:${ARGOCD_AUTH_TOKEN:-}:true"
    )

    local entry key val masked
    for entry in "${vars_to_set[@]}"; do
        key="${entry%%:*}"
        val="${entry#*:}"; val="${val%:*}"
        masked="${entry##*:}"
        [[ -z "$val" ]] && continue

        # Update or create
        local code
        code=$(curl -sf -o /dev/null -w "%{http_code}" --request PUT \
            --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
            "${gitlab_url}/api/v4/groups/${group_id}/variables/${key}" \
            --form "value=${val}" --form "masked=${masked}" 2>/dev/null || echo "000")

        if [[ "$code" != "200" ]]; then
            curl -sf --request POST \
                --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
                "${gitlab_url}/api/v4/groups/${group_id}/variables" \
                --form "key=${key}" --form "value=${val}" --form "masked=${masked}" \
                >/dev/null 2>&1 || true
        fi
    done

    log_ok "GitLab CI variables updated"
}

propagate_to_jenkins() {
    log_info "Checking Jenkins token propagation..."

    local jenkins_url="http://${JENKINS_HOSTNAME:-jenkins.briklab.test}:${JENKINS_HTTP_PORT:-9090}"
    if ! check_http "${jenkins_url}/login"; then
        log_warn "Jenkins not reachable -- skipping"
        return 0
    fi

    # Jenkins reads ARGOCD_AUTH_TOKEN from its container environment (docker-compose env).
    # Compare the token inside the container with the current .env value.
    local container_token
    container_token=$(docker exec brik-jenkins printenv ARGOCD_AUTH_TOKEN 2>/dev/null || echo "")

    if [[ -n "${ARGOCD_AUTH_TOKEN:-}" ]] && [[ "$container_token" == "$ARGOCD_AUTH_TOKEN" ]]; then
        log_ok "Jenkins tokens match .env"
        return 0
    fi

    log_warn "Jenkins tokens outdated -- restarting..."
    (cd "$PROJECT_ROOT" && docker compose up -d jenkins) 2>&1 | tail -3

    # Wait for Jenkins to be ready
    local i
    for i in $(seq 1 20); do
        if check_http "${jenkins_url}/login"; then
            log_ok "Jenkins restarted with updated tokens"
            return 0
        fi
        sleep 5
    done
    log_warn "Jenkins slow to start -- it may need a few more seconds"
}

# ---------------------------------------------------------------------------
# Main: preflight
# ---------------------------------------------------------------------------

preflight() {
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Briklab E2E Preflight${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    # Load .env
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

    # Tokens (may update .env)
    check_gitlab_pat || errors=$((errors + 1))
    check_gitea_pat || errors=$((errors + 1))
    check_argocd_token || errors=$((errors + 1))
    echo ""

    # Reload .env to pick up any regenerated tokens before propagation
    reload_env
    log_ok ".env reloaded"
    echo ""

    # Propagate fresh tokens to CI platforms
    propagate_to_gitlab || errors=$((errors + 1))
    propagate_to_jenkins || errors=$((errors + 1))
    echo ""

    # Summary
    echo -e "${BOLD}========================================${NC}"
    if [[ $errors -eq 0 ]]; then
        log_ok "All preflight checks passed -- .env is up to date"
    else
        log_error "${errors} check(s) failed"
    fi
    echo -e "${BOLD}========================================${NC}"

    return $errors
}

# Run directly if not sourced
if [[ "${_PREFLIGHT_LOADED}" != "1" ]]; then
    _PREFLIGHT_LOADED=1
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        preflight
        exit $?
    fi
fi
