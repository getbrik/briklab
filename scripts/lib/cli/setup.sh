#!/usr/bin/env bash
# Briklab CLI - service configuration commands (setup, smoke-test).
#
# Sourced by scripts/briklab.sh. Relies on the dispatcher's shared state:
#   vars:      SCRIPT_DIR, LIB_SETUP
#   functions: check_prereqs, load_env, log_*, reload_env
# cmd_setup sources lib/infra-verify.sh (verify_* helpers) on demand.
# Not meant to run standalone.

[[ -n "${_BRIKLAB_CLI_SETUP_LOADED:-}" ]] && return 0
_BRIKLAB_CLI_SETUP_LOADED=1

cmd_setup() {
    check_prereqs
    load_env
    # shellcheck source=../infra-verify.sh
    source "${SCRIPT_DIR}/lib/infra-verify.sh"

    local errors=0

    # 1. GitLab
    _run_setup "GitLab" "gitlab.sh" "brik-gitlab" && {
        load_env
        verify_gitlab_pat || ((errors++)) || true
        verify_env_set "GITLAB_RUNNER_TOKEN" || ((errors++)) || true
    }

    # 2. Runner
    _run_setup "Runner" "runner.sh" "brik-runner" && {
        verify_cmd "Runner config" "docker exec brik-runner grep -q url /etc/gitlab-runner/config.toml" || ((errors++)) || true
    }

    # 3. Gitea
    _run_setup "Gitea" "gitea.sh" "brik-gitea" && {
        load_env
        verify_gitea_pat || ((errors++)) || true
    }

    # 4. Jenkins
    _run_setup "Jenkins" "jenkins.sh" "brik-jenkins" && {
        verify_http "Jenkins login" "http://${JENKINS_HOSTNAME:-localhost}:${JENKINS_HTTP_PORT:-9090}/login" || ((errors++)) || true
    }

    # 5. Nexus
    _run_setup "Nexus" "nexus.sh" "brik-nexus" && {
        load_env
        verify_nexus_auth || ((errors++)) || true
        verify_env_set "NEXUS_NPM_TOKEN" || ((errors++)) || true
    }

    # 6. SSH target
    _run_setup "SSH target" "ssh-target.sh" "brik-ssh-target" && {
        verify_ssh_connection || ((errors++)) || true
    }

    # 7. Restart Jenkins (to pick up Nexus env vars)
    if docker ps --format '{{.Names}}' | grep -q "^brik-jenkins$"; then
        log_info "Restarting Jenkins..."
        docker restart brik-jenkins >/dev/null
        _wait_for_http "Jenkins" "http://${JENKINS_HOSTNAME:-localhost}:${JENKINS_HTTP_PORT:-9090}/login" 120
    fi

    # Summary
    if [[ $errors -eq 0 ]]; then
        log_ok "Setup complete -- all verifications passed"
    else
        log_error "Setup complete -- ${errors} verification(s) failed"
        return 1
    fi
}

# Launch a setup script if its container is running
_run_setup() {
    local name="$1" script="$2" container="$3"
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_info "Configuring ${name}..."
        bash "${LIB_SETUP}/${script}"
    else
        log_warn "${name} not running -- skipping"
        return 1
    fi
}

# Wait for an HTTP endpoint to respond
_wait_for_http() {
    local name="$1" url="$2" timeout="${3:-60}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf -o /dev/null "$url" 2>/dev/null; then
            log_ok "${name} ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_warn "${name} not ready after ${timeout}s"
    return 1
}

cmd_smoke_test() {
    check_prereqs
    load_env
    log_info "Running smoke tests..."
    bash "${LIB_SETUP}/smoke-test.sh"
}
