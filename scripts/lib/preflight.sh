#!/usr/bin/env bash
# Briklab E2E preflight - "is the system ready to run E2E?" gate.
#
# Composes the pure predicates in checks.sh into a platform-aware gate. By
# default it is READ-ONLY (verify and report). With --fix it becomes
# heal-then-verify: each failed check runs its matching recovery (recovery.sh),
# then re-checks -- so `test` can get the lab into a good state and proceed
# instead of just aborting.
#
# Separation of concerns:
#   checks.sh        pure probes (no output)        -- read-only
#   recovery.sh      briklab.recover.* (mutating)   -- loaded only with --fix
#   infra-refresh.sh standalone token/propagate repair
#   preflight.sh     THIS - the gate (read-only, or --fix to self-heal)
#
# Usage:
#   bash preflight.sh gitlab [--with-deploy] [--fix]
#   source preflight.sh && briklab.preflight.e2e gitlab --with-deploy --fix
#
# Exit / return code: number of HARD failures remaining (0 = ready).
[[ -n "${_BRIKLAB_PREFLIGHT_LOADED:-}" ]] && return 0
_BRIKLAB_PREFLIGHT_LOADED=1

_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_PREFLIGHT_DIR}/common.sh"
# shellcheck source=checks.sh
source "${_PREFLIGHT_DIR}/checks.sh"

# Run one check and report. With --fix (_PREFLIGHT_FIX=true) and a recovery
# function, a failed check triggers recovery then a single re-check.
# Args: severity(hard|soft) recover_fn("-" = none) label predicate_fn [pred_args...]
_preflight_check() {
    local severity="$1" recover_fn="$2" label="$3"; shift 3
    if "$@"; then
        log_ok "$label"
        return 0
    fi
    if [[ "${_PREFLIGHT_FIX:-}" == "true" && "$recover_fn" != "-" ]]; then
        log_warn "$label -- attempting recovery (${recover_fn})..."
        "$recover_fn" || true
        if "$@"; then
            log_ok "$label (recovered)"
            return 0
        fi
    fi
    if [[ "$severity" == "hard" ]]; then
        log_error "$label"
        _PREFLIGHT_HARD_FAILS=$((_PREFLIGHT_HARD_FAILS + 1))
    else
        log_warn "$label (non-blocking)"
    fi
    return 1
}

# E2E readiness gate.
# Args: platform ("gitlab" | "jenkins"), then optional flags:
#   --with-deploy   promote ArgoCD/cluster checks from soft to hard
#   --fix           heal failed checks via recovery.sh, then re-verify
# Returns: number of hard failures remaining (0 = ready).
briklab.preflight.e2e() {
    local platform="${1:-}"; shift || true
    local argocd_severity="soft"
    _PREFLIGHT_FIX=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-deploy) argocd_severity="hard"; shift ;;
            --fix)         _PREFLIGHT_FIX="true"; shift ;;
            *) log_warn "preflight: ignoring unknown flag '$1'"; shift ;;
        esac
    done

    if [[ "$platform" != "gitlab" && "$platform" != "jenkins" ]]; then
        log_error "preflight: platform must be 'gitlab' or 'jenkins' (got '${platform:-}')"
        return 1
    fi

    # Load the mutating recovery layer only when actually healing.
    if [[ "$_PREFLIGHT_FIX" == "true" ]]; then
        # shellcheck source=recovery.sh
        source "${_PREFLIGHT_DIR}/recovery.sh"
    fi

    _PREFLIGHT_HARD_FAILS=0
    echo ""
    echo -e "${BOLD}=== Briklab E2E preflight (${platform}${_PREFLIGHT_FIX:+, --fix}) ===${NC}"
    echo ""

    # 1. Docker daemon (no auto-recovery)
    _preflight_check hard "-" "Docker daemon reachable" briklab.check.docker

    # 2. Platform containers + shared services (no auto-recovery: run 'start')
    local containers
    if [[ "$platform" == "gitlab" ]]; then
        containers=(brik-gitlab brik-runner brik-nexus)
    else
        containers=(brik-jenkins brik-gitea brik-nexus)
    fi
    local c
    for c in "${containers[@]}"; do
        _preflight_check hard "-" "Container ${c} running" briklab.check.container_running "$c"
    done

    # 3. VCS PAT (recover by regenerating the token)
    if [[ "$platform" == "gitlab" ]]; then
        _preflight_check hard briklab.recover.gitlab_pat "GitLab PAT valid" briklab.check.gitlab_pat
    else
        _preflight_check hard briklab.recover.gitea_pat "Gitea PAT valid" briklab.check.gitea_pat
    fi

    # 4. Brik source push target reachable (suite re-pushes; no recovery needed)
    local vcs="gitlab"; [[ "$platform" == "jenkins" ]] && vcs="gitea"
    _preflight_check soft "-" "Brik source repo present in lab" briklab.check.brik_source_reachable "$vcs"

    # 5. Nexus (no auto-recovery: run 'setup')
    _preflight_check hard "-" "Nexus auth + reachable" briklab.check.nexus_auth

    # 6. ArgoCD + cluster (deploy/gitops). Soft unless --with-deploy.
    # API reachability + token are not enough: a NotReady k3d node can strand the
    # application-controller (which executes syncs) while the API still answers,
    # making deploys hang. So we also assert cluster + controller health -- and
    # recover them under --fix (restart the node, reschedule the controller).
    _preflight_check "$argocd_severity" briklab.recover.argocd_portfwd \
        "ArgoCD port-forward active" briklab.check.argocd_portfwd
    _preflight_check "$argocd_severity" briklab.recover.argocd_token \
        "ArgoCD API token valid" briklab.check.argocd_token
    _preflight_check "$argocd_severity" briklab.recover.k3d_nodes \
        "k3d nodes all Ready" briklab.check.k3d_nodes_ready
    _preflight_check "$argocd_severity" briklab.recover.argocd_controller \
        "ArgoCD application-controller Running" briklab.check.argocd_controller_ready

    # Summary
    echo ""
    if [[ $_PREFLIGHT_HARD_FAILS -eq 0 ]]; then
        log_ok "Preflight passed -- system ready for E2E"
    else
        log_error "Preflight: ${_PREFLIGHT_HARD_FAILS} blocking check(s) failed"
        if [[ "$_PREFLIGHT_FIX" != "true" ]]; then
            log_info "Retry with self-healing:    ./scripts/briklab.sh preflight --${platform} --fix"
        fi
        log_info "Repair tokens/port-forward: ./scripts/briklab.sh infra-refresh"
        log_info "Reconfigure / start:        ./scripts/briklab.sh setup | start"
    fi
    echo ""
    return "$_PREFLIGHT_HARD_FAILS"
}

# Run directly (not sourced): load .env, then gate. Flags after the platform
# (e.g. --with-deploy --fix) are forwarded.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    reload_env
    briklab.preflight.e2e "$@"
    exit $?
fi
