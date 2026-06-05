#!/usr/bin/env bash
# Briklab state predicates - the SINGLE source of "is X reachable/valid?" truth.
#
# Each function is a PURE predicate: it returns 0 (true) or 1 (false) and prints
# NOTHING. Presentation lives in the callers:
#   - infra-verify.sh  wraps these with briklab.verify._ok/briklab.verify._fail (+ counters)
#   - auth/*.sh        wraps these as the fast-path of the mutating ensure_*
#   - preflight.sh     composes these into the read-only E2E gate
#
# Before this module each probe was implemented 2-3 times (once in verify_*,
# once inside every ensure_* fast-path). Centralising them here removes that
# drift: change the probe once, every wrapper follows.
#
# Usage:
#   source "path/to/lib/checks.sh"
#   briklab.check.gitlab_pat && echo "valid"
#
# Reads host/port/token vars from the environment (load .env via reload_env first).

[[ -n "${_BRIKLAB_CHECKS_LOADED:-}" ]] && return 0
_BRIKLAB_CHECKS_LOADED=1

# ---------------------------------------------------------------------------
# Internal helper: HTTP status code for a request, "000" on any failure.
# Args: pass curl arguments (URL last). Never fails (returns code on stdout).
# ---------------------------------------------------------------------------
_briklab_http_code() {
    curl -so /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
# Container predicates
# ---------------------------------------------------------------------------

# True if the named container is running.
briklab.check.container_running() {
    local name="$1"
    [[ "$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null)" == "running" ]]
}

# True if the Docker daemon is reachable.
briklab.check.docker() {
    docker info >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# VCS PAT predicates
# ---------------------------------------------------------------------------

# True if GITLAB_PAT authenticates against the GitLab API.
briklab.check.gitlab_pat() {
    [[ -n "${GITLAB_PAT:-}" ]] || return 1
    local url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
    [[ "$(_briklab_http_code -H "PRIVATE-TOKEN: ${GITLAB_PAT}" "${url}/api/v4/user")" == "200" ]]
}

# True if GITEA_PAT authenticates against the Gitea API.
briklab.check.gitea_pat() {
    [[ -n "${GITEA_PAT:-}" ]] || return 1
    local url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
    [[ "$(_briklab_http_code -H "Authorization: token ${GITEA_PAT}" "${url}/api/v1/user")" == "200" ]]
}

# ---------------------------------------------------------------------------
# Nexus predicate
# ---------------------------------------------------------------------------

# True if the Nexus admin credentials authenticate against the status endpoint.
briklab.check.nexus_auth() {
    local url="http://${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_HTTP_PORT:-8081}"
    local pass="${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}"
    [[ "$(_briklab_http_code -u "admin:${pass}" "${url}/service/rest/v1/status")" == "200" ]]
}

# ---------------------------------------------------------------------------
# ArgoCD predicates
# ---------------------------------------------------------------------------

# True if the ArgoCD API is reachable through the host port-forward.
briklab.check.argocd_portfwd() {
    local port="${ARGOCD_PORT:-9080}"
    [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        "https://localhost:${port}/api/version" 2>/dev/null || echo 000)" == "200" ]]
}

# True if ARGOCD_AUTH_TOKEN is accepted by the ArgoCD API.
briklab.check.argocd_token() {
    [[ -n "${ARGOCD_AUTH_TOKEN:-}" ]] || return 1
    local port="${ARGOCD_PORT:-9080}"
    [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
        "https://localhost:${port}/api/v1/account/brik" 2>/dev/null || echo 000)" == "200" ]]
}

# ---------------------------------------------------------------------------
# Kubernetes / ArgoCD controller health predicates
# ---------------------------------------------------------------------------

# True only if EVERY k3d node reports Ready=True. A single NotReady node strands
# the pods scheduled on it (e.g. the argocd-application-controller StatefulSet),
# which silently breaks deploys while the ArgoCD API still answers.
briklab.check.k3d_nodes_ready() {
    command -v kubectl >/dev/null 2>&1 || return 1
    local statuses
    statuses=$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null)
    [[ -n "$statuses" ]] || return 1        # no nodes / cluster unreachable
    ! grep -qv '^True$' <<< "$statuses"      # true only if every line is exactly True
}

# True if a functional argocd-application-controller pod exists (Running + Ready
# AND not marked for deletion). The controller EXECUTES sync operations; a pod
# stranded Terminating on a dead node still reports ready=true, so we must
# exclude any pod carrying a deletionTimestamp.
briklab.check.argocd_controller_ready() {
    command -v kubectl >/dev/null 2>&1 || return 1
    kubectl get pods -n argocd \
        -l app.kubernetes.io/name=argocd-application-controller \
        -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}' \
        2>/dev/null | grep -q '^|true$'
}

# ---------------------------------------------------------------------------
# SSH predicate
# ---------------------------------------------------------------------------

# True if the deploy SSH key authenticates against the ssh-target container.
briklab.check.ssh() {
    local key="${BRIKLAB_ROOT:-.}/data/ssh-target/deploy_key"
    local port="${SSH_TARGET_PORT:-2223}"
    [[ -f "$key" ]] || return 1
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -i "$key" -p "$port" deploy@localhost echo ok >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Brik source predicate
# ---------------------------------------------------------------------------

# True if the brik/brik source repo exists in the lab VCS (push target valid).
# Args: platform ("gitlab" | "gitea")
# The suite re-pushes brik on every run, so this is a push-target reachability
# check, not a freshness assertion.
briklab.check.brik_source_reachable() {
    local platform="$1"
    if [[ "$platform" == "gitlab" ]]; then
        local url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
        [[ "$(_briklab_http_code -H "PRIVATE-TOKEN: ${GITLAB_PAT:-}" \
            "${url}/api/v4/projects/brik%2Fbrik")" == "200" ]]
    else
        local url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
        [[ "$(_briklab_http_code -H "Authorization: token ${GITEA_PAT:-}" \
            "${url}/api/v1/repos/${GITEA_ADMIN_USER:-brik}/brik")" == "200" ]]
    fi
}
