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
    if briklab.wait.until 300 5 curl -sf -o /dev/null "${GITLAB_URL}/users/sign_in"; then
        log_ok "GitLab is ready"
    else
        log_error "GitLab is not ready after 300s"
        exit 1
    fi
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

# Bump the per-job dotenv variable limit to accommodate Brik's
# init-stage dotenv (20 keys including the BRIK_IMG_<CLASS> mapping)
# plus the release-stage BRIK_NEXT_VERSION + headroom for future
# additions. GitLab's default is 20, which hits the cap as soon as
# the planner reaches the release stage.
configure_dotenv_limit() {
    log_info "Raising dotenv_variables limit (default 20 -> 50)..."
    local result
    result=$(cat <<'RUBY' | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
limits = Plan.default.actual_limits
limits.update!(dotenv_variables: 50)
puts "OK #{Plan.default.actual_limits.dotenv_variables}"
RUBY
)
    if [[ "$result" == OK* ]]; then
        log_ok "dotenv_variables limit: 50"
    else
        log_warn "could not raise dotenv limit (continuing): ${result}"
    fi
}

# Ensure a valid Personal Access Token exists.
# Delegates to the shared auth library.
create_pat() {
    log_info "Checking Personal Access Token..."
    briklab.auth.gitlab_pat
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

# Set a file-type CI/CD variable on the 'brik' group from a file's content
# (create or update). Used for SSH keys, whose newlines and special chars
# cannot be masked or carried as an env_var.
_set_group_file_variable() {
    local key="$1"
    local file="$2"
    local pat="${GITLAB_PAT:-}"

    local content
    content=$(cat "$file")

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${pat}" \
        "${GITLAB_URL}/api/v4/groups/brik/variables" \
        --data-urlencode "key=${key}" \
        --data-urlencode "value=${content}" \
        -d "protected=false&masked=false&variable_type=file")

    case "$http_code" in
        201) return 0 ;;
        400|409)
            curl -s -o /dev/null \
                -X PUT \
                -H "PRIVATE-TOKEN: ${pat}" \
                "${GITLAB_URL}/api/v4/groups/brik/variables/${key}" \
                --data-urlencode "value=${content}" \
                -d "protected=false&masked=false&variable_type=file"
            return 0
            ;;
        *)
            log_warn "${key} creation returned HTTP ${http_code}"
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

    # Simple env_var CI/CD variables, as "key|value|masked" rows. No value
    # contains a "|" (the base64 alphabet excludes it), so the pipe is a safe
    # field separator. The SSH deploy key (file type) is handled separately
    # below; ArgoCD rows are appended conditionally.
    local -a ci_vars=(
        # Docker registry credentials (all 5 stacks)
        "BRIK_PUBLISH_DOCKER_USER|admin|false"
        "BRIK_PUBLISH_DOCKER_PASSWORD|${nexus_password}|true"
        # npm (node-complete)
        "BRIK_PUBLISH_NPM_TOKEN|${auth_token_b64}|true"
        # PyPI (python-complete) - format admin:password for basic auth
        "BRIK_PUBLISH_PYPI_TOKEN|admin:${nexus_password}|true"
        # Maven (java-complete)
        "BRIK_PUBLISH_MAVEN_USER|admin|false"
        "BRIK_PUBLISH_MAVEN_PASSWORD|${nexus_password}|true"
        # Cargo (rust-complete) - Basic auth token; masked=false because GitLab
        # cannot mask values containing spaces ("Basic ...")
        "BRIK_PUBLISH_CARGO_TOKEN|Basic ${auth_token_b64}|false"
        # NuGet (dotnet-complete) - format admin:password for basic auth
        "BRIK_PUBLISH_NUGET_TOKEN|admin:${nexus_password}|true"
        # Brik registry credentials (deploy projects, Nexus Docker hosted registry)
        "BRIK_REGISTRY_HOST|nexus.briklab.test:8082|false"
        "BRIK_REGISTRY_USER|admin|false"
        "BRIK_REGISTRY_PASSWORD|${nexus_password}|true"
        # Nexus 3 UI URL (port 8081) -- distinct from the docker push endpoint
        # (8082). Emitted as business.registry.ui_url so the HTML report links
        # to the image browser page.
        "BRIK_PACKAGE_REGISTRY_UI_URL|http://nexus.briklab.test:8081|false"
        # SSH deploy: skip strict host key checking (local lab only)
        "BRIK_SSH_STRICT_HOST_KEY|no|false"
        # kubectl extra options (skip TLS validation for k3d self-signed certs)
        "BRIK_KUBECTL_OPTS|--insecure-skip-tls-verify --validate=false|false"
        # kubeconfig path (runner mounts it at /root/.kube/config; GitLab sets
        # HOME to the build dir)
        "KUBECONFIG|/root/.kube/config|false"
        # DSI-owned org policy URL (chantier 20260508 P3). Pipelines resolve the
        # file via the docker-compose mount on gitlab-runner; production swaps
        # this for an https:// URL pointing at the DSI repo.
        "BRIK_POLICY_URL|file:///etc/brik/policy/brik-policy.yml|false"
    )

    # ArgoCD (GitOps deploy): runners reach ArgoCD via host.docker.internal,
    # authenticating with the non-expiring API token generated by k3d.sh setup
    # (stored in .env).
    if [[ -n "${ARGOCD_AUTH_TOKEN:-}" ]]; then
        ci_vars+=("ARGOCD_SERVER|host.docker.internal:${ARGOCD_PORT:-9080}|false")
        ci_vars+=("ARGOCD_AUTH_TOKEN|${ARGOCD_AUTH_TOKEN}|true")
    else
        log_warn "ARGOCD_AUTH_TOKEN not found in .env -- run k3d setup first"
    fi

    local count=0
    local total="${#ci_vars[@]}"
    local row key value masked
    for row in "${ci_vars[@]}"; do
        IFS='|' read -r key value masked <<< "$row"
        _set_group_variable "$key" "$value" "$masked" && count=$((count + 1))
    done

    # SSH deploy key (for node-deploy-ssh E2E test) - file type, only when the
    # key has been generated.
    local ssh_key_file="${SCRIPT_DIR}/../../../data/ssh-target/deploy_key"
    if [[ -f "$ssh_key_file" ]]; then
        total=$((total + 1))
        _set_group_file_variable "SSH_PRIVATE_KEY" "$ssh_key_file" && count=$((count + 1))
    fi

    # Cosign signing material for the node-deploy-signed scenario. The air-gapped
    # lab has no Fulcio/Rekor, so signing uses a local key. cosign verify needs
    # the PUBLIC key while sign needs the PRIVATE key, and GitLab CE cannot hold
    # the same variable key under two environment scopes, so both PEMs are
    # published as env_var values and BRIK_COSIGN_KEY selects which one applies:
    # the default (env://COSIGN_PRIVATE_KEY) makes CI sign; the CD trigger passes
    # BRIK_COSIGN_KEY=env://COSIGN_PUBLIC_KEY so the deploy verifies.
    setup_cosign_signing_vars

    if [[ $count -eq $total ]]; then
        log_ok "All ${total} CI/CD variables configured"
    else
        log_warn "${count}/${total} Nexus CI/CD variables configured"
    fi
}

# Generate a local cosign key pair (once) and publish the signing material as
# group CI/CD variables. Idempotent: the key pair is reused across runs so the
# public key pinned in the lab stays stable.
setup_cosign_signing_vars() {
    local pat="${GITLAB_PAT:-}"
    [[ -z "$pat" ]] && { log_warn "GITLAB_PAT not set - cosign variables not configured"; return 0; }
    if ! command -v cosign >/dev/null 2>&1; then
        log_warn "cosign not on PATH - skipping signing variables (node-deploy-signed will not sign)"
        return 0
    fi

    local key_dir="${SCRIPT_DIR}/../../../data/cosign"
    mkdir -p "$key_dir"
    if [[ ! -f "${key_dir}/cosign.key" || ! -f "${key_dir}/cosign.pub" ]]; then
        log_info "Generating cosign key pair (empty password, local lab)..."
        ( cd "$key_dir" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1 ) || {
            log_warn "cosign key generation failed - signing variables not configured"
            return 0
        }
    fi

    _set_group_variable "COSIGN_PRIVATE_KEY" "$(cat "${key_dir}/cosign.key")" "false"
    _set_group_variable "COSIGN_PUBLIC_KEY"  "$(cat "${key_dir}/cosign.pub")" "false"
    _set_group_variable "COSIGN_PASSWORD"    ""                                "false"
    _set_group_variable "BRIK_COSIGN_KEY"    "env://COSIGN_PRIVATE_KEY"        "false"
    log_ok "Cosign signing variables configured (CI signs with the private key)"
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
configure_dotenv_limit
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
