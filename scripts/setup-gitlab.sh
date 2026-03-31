#!/usr/bin/env bash
# GitLab CE configuration via API
# Creates a Personal Access Token, an brik-test project, and retrieves the runner token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

GITLAB_URL="http://localhost:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PASSWORD="${GITLAB_ROOT_PASSWORD:-changeme_gitlab_root}"

# Save a variable to .env (add or update)
save_to_env() {
    local key="$1" value="$2"
    if [[ ! -f "$ENV_FILE" ]]; then return; fi
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# Wait for GitLab to be ready
wait_for_gitlab() {
    log_info "Waiting for GitLab (may take a few minutes)..."
    local max_attempts=60
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf -o /dev/null "http://localhost:${GITLAB_HTTP_PORT:-8929}/users/sign_in"; then
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
    local password="${GITLAB_ROOT_PASSWORD:-changeme_gitlab_root}"
    log_info "Configuring root password..."

    local result
    result=$(cat <<RUBY | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
user = User.find_by_username("root")
user.password = "${password}"
user.password_confirmation = "${password}"
user.password_automatically_set = false
user.password_expires_at = nil
if user.save
  puts "OK"
else
  puts "FAIL: #{user.errors.full_messages.join(', ')}"
end
RUBY
)

    if [[ "$result" == "OK" ]]; then
        log_ok "Root password configured"
    else
        log_warn "Password configuration: ${result}"
    fi
}

# Create a Personal Access Token via rails console (stdin to avoid shell escaping issues)
create_pat() {
    log_info "Creating Personal Access Token..."

    local pat
    pat=$(cat <<'RUBY' | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
user = User.find_by_username("root")
existing = user.personal_access_tokens.find_by(name: "brik-briklab")
if existing
  puts "EXISTS"
else
  token = user.personal_access_tokens.create!(
    name: "brik-briklab",
    scopes: ["api", "read_repository", "write_repository"],
    expires_at: 365.days.from_now
  )
  puts token.token
end
RUBY
)

    if [[ "$pat" == "EXISTS" ]]; then
        log_warn "Token 'brik-briklab' already exists"
        if [[ -n "${GITLAB_PAT:-}" ]]; then
            log_info "Using existing PAT from .env"
        else
            log_info "To regenerate: GitLab > User Settings > Access Tokens"
        fi
        return 0
    fi

    if [[ -n "$pat" ]]; then
        log_ok "PAT created: ${pat:0:15}..."
        save_to_env "GITLAB_PAT" "$pat"
        export GITLAB_PAT="$pat"
        log_ok "Token saved to .env"
    else
        log_error "Failed to create PAT"
        exit 1
    fi
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
get_runner_token

log_ok "GitLab configuration complete"
echo ""
echo -e "${BLUE}GitLab access:${NC}"
echo "  URL      : ${GITLAB_URL}"
echo "  Login    : root"
echo "  Password : ${GITLAB_PASSWORD}"
