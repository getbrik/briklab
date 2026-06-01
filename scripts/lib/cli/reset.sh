#!/usr/bin/env bash
# Briklab CLI - reset command (clean test state between E2E runs).
#
# Sourced by scripts/briklab.sh. Relies on the dispatcher's shared state:
#   vars:      LIB_E2E
#   functions: check_prereqs, load_env, log_*
# cmd_reset sources lib/e2e/lib/reset.sh (e2e.reset.* helpers) on demand.
# Not meant to run standalone.

[[ -n "${_BRIKLAB_CLI_RESET_LOADED:-}" ]] && return 0
_BRIKLAB_CLI_RESET_LOADED=1

cmd_reset() {
    check_prereqs
    load_env

    # Source reset library
    source "${LIB_E2E}/lib/reset.sh"

    local what=""              # repos, k8s, argocd, artifacts, (empty)=all
    local only=""              # specific repo name
    local platform=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gitlab)    platform="gitlab"; shift ;;
            --jenkins)   platform="gitea"; shift ;;  # Jenkins uses Gitea repos
            --repos)     what="repos"; shift ;;
            --k8s)       what="k8s"; shift ;;
            --argocd)    what="argocd"; shift ;;
            --artifacts) what="artifacts"; shift ;;
            --only)
                only="${2:-}"
                if [[ -z "$only" ]]; then
                    log_error "--only requires a project name"
                    exit 1
                fi
                shift 2
                ;;
            *)
                log_error "Unknown reset option: $1"
                exit 1
                ;;
        esac
    done

    case "$what" in
        repos)
            if [[ -z "$platform" ]]; then
                log_error "--repos requires --gitlab or --jenkins"
                exit 1
            fi
            e2e.reset.all_repos "$platform" "$only"
            ;;
        k8s)
            e2e.reset.all_deploy_namespaces
            ;;
        argocd)
            e2e.reset.all_argocd_apps
            ;;
        artifacts)
            e2e.reset.nexus_artifacts
            e2e.reset.registry_images
            ;;
        "")
            # Full reset -- platform required
            if [[ -z "$platform" ]]; then
                log_error "Full reset requires --gitlab or --jenkins"
                log_info "Or use a targeted reset: --repos, --k8s, --argocd, --artifacts"
                exit 1
            fi
            e2e.reset.all "$platform"
            ;;
    esac
}
