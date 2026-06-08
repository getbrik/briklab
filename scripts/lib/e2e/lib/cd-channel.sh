#!/usr/bin/env bash
# E2E CD channel keystone library -- platform-agnostic CI -> CD flow.
#
# Proves the decoupled pipeline: CI builds and publishes one immutable image,
# then CD resolves that version to a digest and deploys the pinned digest, which
# a GitOps controller reconciles. The SAME flow runs on every orchestrator; only
# the trigger mechanics differ, supplied by the caller as callbacks (the pattern
# used by lib/rollback.sh).
#
# The calling script must define:
#   _cd_channel_seed_ci              -> run the CI flow that publishes the
#                                       artifact; return 0 on success
#   _cd_channel_deploy <ver> <env>   -> trigger the CD flow for (version,
#                                       environment); return 0 on success
#
# Then call:
#   e2e.cd_channel.run <platform> <argocd_app> <environment> <version> <timeout>
#
# Depends on: common.sh (log_*), lib/argocd.sh

[[ -n "${_E2E_CD_CHANNEL_LOADED:-}" ]] && return 0
_E2E_CD_CHANNEL_LOADED=1

_E2E_CD_CHANNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=argocd.sh
source "${_E2E_CD_CHANNEL_DIR}/argocd.sh"

# e2e.cd_channel.run - run the shared keystone flow.
# Args: platform argocd_app environment version timeout
e2e.cd_channel.run() {
    local platform="$1" app="$2" environment="$3" version="$4" timeout="${5:-900}"

    echo ""
    log_info "=== Brik E2E ${platform^} CD channel keystone ==="
    log_info "version=${version}  environment=${environment}  argocd_app=${app}"
    echo ""

    e2e.argocd.ensure_port_forward || \
        log_warn "ArgoCD port-forward not established -- the assert may fail"

    # --- Step 1: CI publishes the immutable artifact -----------------------
    log_info "--- Step 1: CI seed (build + publish the artifact) ---"
    if ! _cd_channel_seed_ci; then
        log_error "CI seed failed"
        return 1
    fi
    log_ok "artifact published to the release channel"

    # --- Step 2: CD deploys that version (digest-pinned) -------------------
    log_info "--- Step 2: CD deploy ${version} -> ${environment} ---"
    if ! _cd_channel_deploy "$version" "$environment"; then
        log_error "CD deploy failed"
        return 1
    fi
    log_ok "CD flow succeeded"

    # --- Step 3: assert the live digest (shared, identical everywhere) -----
    log_info "--- Step 3: assert the deployed digest via ArgoCD (${app}) ---"
    if ! e2e.argocd.assert_synced "$app" "$timeout"; then
        log_error "ArgoCD app '${app}' did not reach Synced+Healthy"
        return 1
    fi

    local image
    image="$(e2e.argocd.get_app_image "$app")"
    log_info "deployed image: ${image:-<none>}"
    case "$image" in
        *@sha256:*)
            log_ok "=== ${platform^^} CD CHANNEL KEYSTONE PASSED (digest-pinned) ==="
            return 0
            ;;
        *)
            log_error "deployed image is NOT digest-pinned: ${image:-<empty>}"
            return 1
            ;;
    esac
}
