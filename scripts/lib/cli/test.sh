#!/usr/bin/env bash
# Briklab CLI - test command (run E2E scenarios on GitLab or Jenkins).
#
# Sourced by scripts/briklab.sh. Relies on the dispatcher's shared state:
#   vars:      SCRIPT_DIR, LIB_E2E
#   functions: check_prereqs, load_env, log_*, briklab.runner_images.*
# Sources lib/preflight.sh for the read-only readiness gate.
# Not meant to run standalone.

[[ -n "${_BRIKLAB_CLI_TEST_LOADED:-}" ]] && return 0
_BRIKLAB_CLI_TEST_LOADED=1

# shellcheck source=../preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"

cmd_test() {
    check_prereqs
    load_env
    briklab.runner_images.pull

    local platform=""          # gitlab or jenkins (required)
    local action=""            # (empty)=default, all, list, project, complete, groups
    local project=""
    local stub=""              # --stub: run every stage on the stub image fleet
    local no_preflight=""      # --no-preflight: skip the readiness gate
    local no_repair=""         # --no-repair: gate detects but does not self-heal
    local batch_args=()
    local group_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gitlab)    platform="gitlab"; shift ;;
            --jenkins)   platform="jenkins"; shift ;;
            --all)       action="all"; shift ;;
            --list)      action="list"; shift ;;
            --complete)  action="complete"; shift ;;
            --stub)      stub="true"; shift ;;
            --no-preflight) no_preflight="true"; shift ;;
            --no-repair) no_repair="true"; shift ;;
            --batch-size)
                batch_args=(--batch-size "${2:-}")
                if [[ -z "${2:-}" ]]; then
                    log_error "--batch-size requires a number"
                    exit 1
                fi
                shift 2
                ;;
            --groups)
                action="groups"
                group_args=(--groups "${2:-}")
                if [[ -z "${2:-}" ]]; then
                    log_error "--groups requires comma-separated group letters (e.g. A,D,H)"
                    exit 1
                fi
                shift 2
                ;;
            --parallel-groups)
                group_args+=(--parallel-groups)
                shift
                ;;
            --project)
                action="project"
                project="${2:-}"
                if [[ -z "$project" ]]; then
                    log_error "Usage: briklab.sh test --gitlab|--jenkins --project <name>"
                    exit 1
                fi
                shift 2
                ;;
            *) shift ;;
        esac
    done

    if [[ -z "$platform" ]]; then
        log_error "Platform required. Use --gitlab or --jenkins."
        log_info "Examples:"
        log_info "  briklab.sh test --gitlab"
        log_info "  briklab.sh test --jenkins --all"
        exit 1
    fi

    # Readiness gate before touching the lab. By default it self-heals (--fix):
    # a bad-state system (stale PAT, port-forward down, NotReady node, stranded
    # ArgoCD controller) is repaired, then re-verified, so the e2e run can
    # actually proceed. --no-repair makes it detect-only; --no-preflight skips it.
    # ArgoCD/cluster checks become blocking when a deploy/gitops scenario runs.
    if [[ -z "$no_preflight" ]]; then
        local preflight_args=("$platform")
        if [[ "$action" == "all" || "$project" == *deploy* || "$project" == *gitops* || "$project" == *rollback* ]]; then
            preflight_args+=(--with-deploy)
        fi
        [[ -z "$no_repair" ]] && preflight_args+=(--fix)
        if ! briklab.preflight.e2e "${preflight_args[@]}"; then
            log_error "Preflight failed after recovery -- aborting."
            log_info "Inspect/repair manually, or re-run with --no-preflight to override."
            exit 1
        fi
    fi

    if [[ "$platform" == "jenkins" ]]; then
        local suite="${LIB_E2E}/jenkins-suite.sh"
    else
        local suite="${LIB_E2E}/gitlab-suite.sh"
    fi

    # --stub: pin every stage to the stub image fleet on whatever scenario(s)
    # run. The suites read E2E_STUB and inject BRIK_RUNNER_CLASSES_FILE per
    # scenario, so any pipeline can run in stub mode without a dedicated row.
    if [[ -n "$stub" ]]; then
        briklab.runner_images.ensure_stub || \
            log_warn "Continuing -- the runner will fail if the stub image is truly absent"
        export E2E_STUB=true
        log_info "Stub mode: every stage runs on ${BRIKLAB_STUB_IMAGE}"
    fi

    case "$action" in
        list)     bash "$suite" --list ;;
        all)      bash "$suite" ${batch_args[@]+"${batch_args[@]}"} ;;
        complete) bash "$suite" --complete ${batch_args[@]+"${batch_args[@]}"} ;;
        project)  bash "$suite" --only "$project" ;;
        groups)   bash "$suite" ${group_args[@]+"${group_args[@]}"} ${batch_args[@]+"${batch_args[@]}"} ;;
        *)        bash "$suite" --only node-full ;;
    esac
}
