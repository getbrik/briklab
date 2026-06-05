#!/usr/bin/env bash
# Briklab recovery actions - the MUTATING counterparts to checks.sh predicates.
#
# Each briklab.recover.* function is idempotent: it heals one failure mode and
# returns 0 once the matching predicate passes again (or 1 if it cannot). They
# are what turns preflight from "verify and abort" into "heal, then run e2e".
#
# Layering:
#   checks.sh     pure predicates (is X ok?)        -- read-only
#   recovery.sh   THIS: make X ok                    -- mutating, idempotent
#   preflight.sh  --fix mode pairs each check with its recovery
#
# Token/port-forward recovery reuses the existing ensure_* from auth/*.sh; the
# k3d-node and argocd-controller recoveries are new (the failure mode that hung
# node-deploy-gitops: a NotReady node stranding the application-controller).
#
# Usage:
#   source "path/to/lib/recovery.sh"
#   briklab.recover.deploy_infra      # heal cluster + controller for a deploy run

[[ -n "${_BRIKLAB_RECOVERY_LOADED:-}" ]] && return 0
_BRIKLAB_RECOVERY_LOADED=1

_RECOVERY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_RECOVERY_DIR}/common.sh"
# shellcheck source=checks.sh
source "${_RECOVERY_DIR}/checks.sh"
# ensure_* token/port-forward repair (already idempotent)
# shellcheck source=auth/gitlab-pat.sh
source "${_RECOVERY_DIR}/auth/gitlab-pat.sh"
# shellcheck source=auth/gitea-pat.sh
source "${_RECOVERY_DIR}/auth/gitea-pat.sh"
# shellcheck source=auth/argocd-portfwd.sh
source "${_RECOVERY_DIR}/auth/argocd-portfwd.sh"
# shellcheck source=auth/argocd-token.sh
source "${_RECOVERY_DIR}/auth/argocd-token.sh"

# Poll loops delegate to briklab.wait.until (transverse SoT, sourced via common.sh).

# --- token / port-forward (thin wrappers over the existing ensure_*) ---

briklab.recover.gitlab_pat()      { briklab.auth.gitlab_pat; }
briklab.recover.gitea_pat()       { briklab.auth.gitea_pat; }
briklab.recover.argocd_portfwd()  { briklab.auth.argocd_portfwd; }
briklab.recover.argocd_token()    { briklab.auth.argocd_token; }

# --- k3d nodes ---

# Restart any NotReady k3d node container so its kubelet rejoins the cluster.
# k3d node names == their Docker container names (e.g. k3d-brik-agent-0).
briklab.recover.k3d_nodes() {
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl not found"; return 1; }
    briklab.check.k3d_nodes_ready && return 0

    local notready
    notready=$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk -F= '$2!="True"{print $1}')
    [[ -z "$notready" ]] && return 0

    local node
    for node in $notready; do
        log_warn "k3d node ${node} NotReady -- restarting its container..."
        docker restart "$node" >/dev/null 2>&1 || log_warn "  docker restart ${node} failed"
    done

    if briklab.wait.until 150 5 briklab.check.k3d_nodes_ready; then
        log_ok "k3d nodes Ready after restart"
        return 0
    fi
    log_error "k3d nodes still NotReady after recovery"
    return 1
}

# --- argocd application-controller ---

# Force-delete a stranded application-controller pod (one carrying a
# deletionTimestamp, stuck Terminating on a dead node) so the StatefulSet can
# reschedule it onto a healthy node. Only the stranded pod is removed; a healthy
# pod (no deletionTimestamp) is left untouched.
briklab.recover.argocd_controller() {
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl not found"; return 1; }
    briklab.check.argocd_controller_ready && return 0

    local stranded
    stranded=$(kubectl get pods -n argocd \
        -l app.kubernetes.io/name=argocd-application-controller \
        -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null)

    local pod
    for pod in $stranded; do
        log_warn "force-deleting stranded controller pod ${pod}..."
        kubectl delete pod -n argocd "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
    done

    if briklab.wait.until 120 5 briklab.check.argocd_controller_ready; then
        log_ok "argocd-application-controller Running after recovery"
        return 0
    fi
    log_error "argocd-application-controller still not ready after recovery"
    return 1
}

# Clear a wedged sync operation on an ArgoCD app (operation queued but never
# executed, e.g. left behind by a deploy that hit a dead controller).
# Args: app_name
briklab.recover.argocd_app_op() {
    local app="$1"
    command -v kubectl >/dev/null 2>&1 || return 1
    if kubectl get application "$app" -n argocd \
        -o jsonpath='{.operation}' 2>/dev/null | grep -q .; then
        log_warn "clearing wedged ArgoCD operation on ${app}..."
        kubectl -n argocd patch application "$app" --type merge \
            -p '{"operation":null}' >/dev/null 2>&1 || true
    fi
}

# --- orchestrator: heal everything a deploy/gitops run needs ---

# Bring the k3d cluster + ArgoCD controller back to a deploy-ready state.
# Order matters: recover the node first (so the controller's home node is Ready),
# then clear any stranded controller pod.
briklab.recover.deploy_infra() {
    local rc=0
    briklab.recover.k3d_nodes        || rc=1
    briklab.recover.argocd_controller || rc=1
    return $rc
}
