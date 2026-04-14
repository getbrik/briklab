#!/usr/bin/env bash
# Initial Gitea configuration
# Creates admin user, API token, and 'brik' organization
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/gitea-pat.sh
source "${SCRIPT_DIR}/../auth/gitea-pat.sh"
reload_env

GITEA_URL="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-brik}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-brik@briklab.test}"

if [[ -z "$GITEA_ADMIN_PASSWORD" ]]; then
    log_error "GITEA_ADMIN_PASSWORD is not set in .env"
    exit 1
fi

# Complete Gitea initial installation if needed
run_initial_install() {
    log_info "Running Gitea initial installation..."
    local http_code
    http_code=$(curl -s --max-time 30 -X POST "${GITEA_URL}/" \
        -d "db_type=sqlite3" \
        -d "db_host=localhost:3306" \
        -d "db_user=root" \
        -d "db_passwd=" \
        -d "db_name=gitea" \
        -d "ssl_mode=disable" \
        -d "db_schema=" \
        -d "charset=utf8" \
        -d "db_path=/data/gitea/gitea.db" \
        -d "app_name=Gitea: Git with a cup of tea" \
        -d "repo_root_path=/data/git/repositories" \
        -d "lfs_root_path=/data/git/lfs" \
        -d "run_user=git" \
        -d "domain=${GITEA_HOSTNAME:-gitea.briklab.test}" \
        -d "ssh_port=22" \
        -d "http_port=${GITEA_HTTP_PORT:-3000}" \
        -d "app_url=http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}/" \
        -d "log_root_path=/data/gitea/log" \
        -d "smtp_addr=" \
        -d "smtp_port=" \
        -d "smtp_from=" \
        -d "smtp_user=" \
        -d "smtp_passwd=" \
        -d "enable_federated_avatar=off" \
        -d "enable_open_id_sign_in=off" \
        -d "enable_open_id_sign_up=off" \
        -d "default_allow_create_organization=on" \
        -d "default_enable_timetracking=on" \
        -d "no_reply_address=noreply.${GITEA_HOSTNAME:-gitea.briklab.test}" \
        -d "admin_name=${GITEA_ADMIN_USER}" \
        -d "admin_passwd=${GITEA_ADMIN_PASSWORD}" \
        -d "admin_confirm_passwd=${GITEA_ADMIN_PASSWORD}" \
        -d "admin_email=${GITEA_ADMIN_EMAIL}" \
        -o /dev/null -w "%{http_code}")

    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        log_ok "Initial installation complete"
        sleep 2
    else
        log_error "Initial installation failed (HTTP ${http_code})"
        return 1
    fi
}

# Wait for Gitea to be ready
wait_for_gitea() {
    log_info "Waiting for Gitea..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        # Check if Gitea HTTP is reachable at all
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${GITEA_URL}/api/v1/version" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log_ok "Gitea is ready"
            return 0
        fi

        # If API returns 404, Gitea is on install page -- run initial install
        if [[ "$http_code" == "404" ]]; then
            run_initial_install
            continue
        fi

        attempt=$((attempt + 1))
        echo -n "."
        sleep 5
    done
    echo ""
    log_error "Gitea is not ready after $((max_attempts * 5))s"
    exit 1
}

# Create admin user via Gitea CLI inside the container
create_admin_user() {
    log_info "Creating admin user '${GITEA_ADMIN_USER}'..."

    # Check if user already exists
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}")

    if [[ "$http_code" == "200" ]]; then
        log_info "User '${GITEA_ADMIN_USER}' already exists"
        return 0
    fi

    docker exec -u git brik-gitea gitea admin user create \
        --username "${GITEA_ADMIN_USER}" \
        --password "${GITEA_ADMIN_PASSWORD}" \
        --email "${GITEA_ADMIN_EMAIL}" \
        --admin \
        --must-change-password=false 2>/dev/null || {
        log_warn "Could not create user via CLI (may already exist)"
        return 0
    }

    log_ok "Admin user '${GITEA_ADMIN_USER}' created"
}

# Generate API token
# Delegates to the shared auth library.
create_api_token() {
    log_info "Generating API token..."
    ensure_gitea_pat "briklab"
}

# Create the GitOps config repo (used by node-deploy-gitops E2E scenario)
create_config_deploy_repo() {
    local org="brik"
    local repo="config-deploy"

    # Check if repo already exists
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: token ${GITEA_PAT}" \
        "${GITEA_URL}/api/v1/repos/${org}/${repo}")

    if [[ "$http_code" == "200" ]]; then
        log_info "Repo '${org}/${repo}' already exists"
        return 0
    fi

    # Create repo under user (brik is a user, not an org) with auto-init
    log_info "Creating repo '${org}/${repo}'..."
    curl -sf --max-time 10 \
        -H "Authorization: token ${GITEA_PAT}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${repo}\",\"auto_init\":true,\"default_branch\":\"main\",\"description\":\"GitOps config repo for E2E deploy tests\"}" \
        "${GITEA_URL}/api/v1/user/repos" -o /dev/null || {
        log_error "Failed to create repo '${org}/${repo}'"
        return 1
    }

    log_ok "Repo '${org}/${repo}' created"
}

# === Main ===
wait_for_gitea
create_admin_user
create_api_token
create_config_deploy_repo

log_ok "Gitea configuration complete"
echo ""
echo -e "${BLUE}Gitea access:${NC}"
echo "  URL      : ${GITEA_URL}"
echo "  Login    : ${GITEA_ADMIN_USER}"
echo "  Password : (from GITEA_ADMIN_PASSWORD in .env)"
