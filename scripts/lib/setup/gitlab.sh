#!/usr/bin/env bash
# GitLab CE configuration via API
# Creates PAT, brik-test project, brik group with Nexus CI/CD variables, and retrieves runner token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/gitlab-pat.sh
source "${SCRIPT_DIR}/../auth/gitlab-pat.sh"
reload_env

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PASSWORD="${GITLAB_ROOT_PASSWORD:-Brik-Gtlb-2026}"

# Wait for GitLab to be ready
wait_for_gitlab() {
    log_info "Waiting for GitLab (may take a few minutes)..."
    local max_attempts=60
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf -o /dev/null "${GITLAB_URL}/users/sign_in"; then
            log_ok "GitLab is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        printf "."
        sleep 5
    done
    echo ""
    log_error "GitLab is not ready after $((max_attempts * 5))s"
    exit 1
}

# Configure root password and disable forced password change on first login
setup_root_password() {
    local password="${GITLAB_ROOT_PASSWORD:-Brik-Gtlb-2026}"
    log_info "Configuring root password..."

    local result
    result=$(cat <<RUBY | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
user = User.find_by_username("root")
user.password = "${password}"
user.password_confirmation = "${password}"
user.password_automatically_set = false
user.password_expires_at = nil
if user.save(validate: false)
  puts "OK"
else
  puts "FAIL: #{user.errors.full_messages.join(', ')}"
end
RUBY
)

    if [[ "$result" == "OK" ]]; then
        log_ok "Root password configured"
    else
        log_error "Password configuration failed: ${result}"
        exit 1
    fi
}

# Ensure a valid Personal Access Token exists.
# Delegates to the shared auth library.
create_pat() {
    log_info "Checking Personal Access Token..."
    ensure_gitlab_pat
}

# Create a test project
create_test_project() {
    log_info "Creating brik-test project..."

    local pat="${GITLAB_PAT:-}"
    if [[ -z "$pat" ]]; then
        pat=$(grep "^GITLAB_PAT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    fi
    if [[ -z "$pat" ]]; then
        log_warn "GITLAB_PAT not set - project not created"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${pat}" \
        "${GITLAB_URL}/api/v4/projects" \
        -d "name=brik-test&visibility=public&initialize_with_readme=true")

    case "$http_code" in
        201) log_ok "Project 'brik-test' created" ;;
        400) log_warn "Project 'brik-test' already exists" ;;
        *)   log_warn "Unexpected response (HTTP ${http_code})" ;;
    esac
}

# Create the 'brik' group for E2E test projects
create_brik_group() {
    log_info "Creating 'brik' group..."

    local pat="${GITLAB_PAT:-}"
    if [[ -z "$pat" ]]; then
        log_warn "GITLAB_PAT not set - group not created"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${pat}" \
        "${GITLAB_URL}/api/v4/groups" \
        -d "name=brik&path=brik&visibility=public")

    case "$http_code" in
        201) log_ok "Group 'brik' created" ;;
        400) log_info "Group 'brik' already exists" ;;
        *)   log_warn "Group creation returned HTTP ${http_code}" ;;
    esac
}

# Set a CI/CD variable on the 'brik' group (create or update)
_set_group_variable() {
    local group_path="brik"
    local key="$1"
    local value="$2"
    local masked="${3:-true}"

    local pat="${GITLAB_PAT:-}"

    # Try to create first
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${pat}" \
        "${GITLAB_URL}/api/v4/groups/${group_path}/variables" \
        --data-urlencode "key=${key}" \
        --data-urlencode "value=${value}" \
        -d "protected=false&masked=${masked}&variable_type=env_var")

    case "$http_code" in
        201) return 0 ;;
        400|409)
            # Already exists - update it
            curl -s -o /dev/null \
                -X PUT \
                -H "PRIVATE-TOKEN: ${pat}" \
                "${GITLAB_URL}/api/v4/groups/${group_path}/variables/${key}" \
                --data-urlencode "value=${value}" \
                -d "protected=false&masked=${masked}&variable_type=env_var"
            return 0
            ;;
        *)
            log_warn "Variable '${key}' creation returned HTTP ${http_code}"
            return 1
            ;;
    esac
}

# Configure Nexus CI/CD variables on the 'brik' group
setup_nexus_ci_variables() {
    log_info "Configuring Nexus CI/CD variables on 'brik' group..."

    local pat="${GITLAB_PAT:-}"
    if [[ -z "$pat" ]]; then
        log_warn "GITLAB_PAT not set - Nexus variables not configured"
        return 0
    fi

    local nexus_password="${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}"
    local auth_token_b64
    auth_token_b64=$(printf 'admin:%s' "$nexus_password" | base64)

    local count=0
    local total=14

    # Docker registry credentials (all 5 stacks)
    _set_group_variable "BRIK_PUBLISH_DOCKER_USER" "admin" "false" && count=$((count + 1))
    _set_group_variable "BRIK_PUBLISH_DOCKER_PASSWORD" "$nexus_password" "true" && count=$((count + 1))

    # npm (node-complete)
    _set_group_variable "BRIK_PUBLISH_NPM_TOKEN" "$auth_token_b64" "true" && count=$((count + 1))

    # PyPI (python-complete) - format admin:password for basic auth
    _set_group_variable "BRIK_PUBLISH_PYPI_TOKEN" "admin:${nexus_password}" "true" && count=$((count + 1))

    # Maven (java-complete)
    _set_group_variable "BRIK_PUBLISH_MAVEN_USER" "admin" "false" && count=$((count + 1))
    _set_group_variable "BRIK_PUBLISH_MAVEN_PASSWORD" "$nexus_password" "true" && count=$((count + 1))

    # Cargo (rust-complete) - Basic auth token for Nexus Cargo registry
    # masked=false because GitLab cannot mask values containing spaces ("Basic ...")
    _set_group_variable "BRIK_PUBLISH_CARGO_TOKEN" "Basic ${auth_token_b64}" "false" && count=$((count + 1))

    # NuGet (dotnet-complete) - format admin:password for basic auth
    _set_group_variable "BRIK_PUBLISH_NUGET_TOKEN" "admin:${nexus_password}" "true" && count=$((count + 1))

    # Brik registry credentials (deploy projects, Nexus Docker hosted registry)
    _set_group_variable "BRIK_REGISTRY_HOST" "nexus.briklab.test:8082" "false" && count=$((count + 1))
    _set_group_variable "BRIK_REGISTRY_USER" "admin" "false" && count=$((count + 1))
    _set_group_variable "BRIK_REGISTRY_PASSWORD" "$nexus_password" "true" && count=$((count + 1))

    # SSH deploy: skip strict host key checking (local lab only)
    _set_group_variable "BRIK_SSH_STRICT_HOST_KEY" "no" "false" && count=$((count + 1))

    # SSH deploy key (for node-deploy-ssh E2E test)
    local root_dir="${SCRIPT_DIR}/../../.."
    local ssh_key_file="${root_dir}/data/ssh-target/deploy_key"
    if [[ -f "$ssh_key_file" ]]; then
        total=$((total + 1))
        local ssh_key_content
        ssh_key_content=$(cat "$ssh_key_file")
        # SSH keys contain newlines and special chars: can't be masked, use file type
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "PRIVATE-TOKEN: ${pat}" \
            "${GITLAB_URL}/api/v4/groups/brik/variables" \
            --data-urlencode "key=SSH_PRIVATE_KEY" \
            --data-urlencode "value=${ssh_key_content}" \
            -d "protected=false&masked=false&variable_type=file")
        case "$http_code" in
            201) count=$((count + 1)) ;;
            400|409)
                curl -s -o /dev/null \
                    -X PUT \
                    -H "PRIVATE-TOKEN: ${pat}" \
                    "${GITLAB_URL}/api/v4/groups/brik/variables/SSH_PRIVATE_KEY" \
                    --data-urlencode "value=${ssh_key_content}" \
                    -d "protected=false&masked=false&variable_type=file"
                count=$((count + 1))
                ;;
            *) log_warn "SSH_PRIVATE_KEY creation returned HTTP ${http_code}" ;;
        esac
    fi

    # kubectl extra options (skip TLS validation for k3d self-signed certs)
    _set_group_variable "BRIK_KUBECTL_OPTS" "--insecure-skip-tls-verify --validate=false" "false" && count=$((count + 1))

    # kubeconfig path (runner mounts kubeconfig at /root/.kube/config but GitLab sets HOME to build dir)
    _set_group_variable "KUBECONFIG" "/root/.kube/config" "false" && count=$((count + 1))

    # ArgoCD (GitOps deploy) - runners reach ArgoCD via host.docker.internal
    # Uses the non-expiring API token generated by k3d.sh setup (stored in .env)
    if [[ -n "${ARGOCD_AUTH_TOKEN:-}" ]]; then
        local argocd_server="host.docker.internal:${ARGOCD_PORT:-9080}"
        total=$((total + 2))
        _set_group_variable "ARGOCD_SERVER" "$argocd_server" "false" && count=$((count + 1))
        _set_group_variable "ARGOCD_AUTH_TOKEN" "$ARGOCD_AUTH_TOKEN" "true" && count=$((count + 1))
    else
        log_warn "ARGOCD_AUTH_TOKEN not found in .env -- run k3d setup first"
    fi

    if [[ $count -eq $total ]]; then
        log_ok "All ${total} CI/CD variables configured"
    else
        log_warn "${count}/${total} Nexus CI/CD variables configured"
    fi
}

# Get the runner registration token
get_runner_token() {
    log_info "Retrieving runner registration token..."

    local token
    token=$(cat <<'RUBY' | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
puts Gitlab::CurrentSettings.current_application_settings.runners_registration_token
RUBY
)

    if [[ -n "$token" ]]; then
        save_to_env "GITLAB_RUNNER_TOKEN" "$token"
        export GITLAB_RUNNER_TOKEN="$token"
        log_ok "Runner token saved to .env"
    else
        log_error "Failed to retrieve runner token"
        exit 1
    fi
}

# === Main ===
wait_for_gitlab
setup_root_password
create_pat
create_test_project
create_brik_group
setup_nexus_ci_variables
get_runner_token

log_ok "GitLab configuration complete"
echo ""
echo -e "${BLUE}GitLab access:${NC}"
echo "  URL      : ${GITLAB_URL}"
echo "  Login    : root"
echo "  Password : ${GITLAB_PASSWORD}"
