#!/usr/bin/env bash
# Nexus 3 CE configuration via REST API
# Waits for Nexus, changes admin password, enables Docker realm,
# and creates 6 hosted repositories for artifact publishing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../.env"

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

NEXUS_URL="http://${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_HTTP_PORT:-8081}"
NEXUS_NEW_PASSWORD="${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}"

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

# Wait for Nexus to be ready
wait_for_nexus() {
    log_info "Waiting for Nexus (may take 2-3 minutes on first start)..."
    local max_attempts=60
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf -o /dev/null "${NEXUS_URL}/service/rest/v1/status"; then
            log_ok "Nexus is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        printf "."
        sleep 5
    done
    echo ""
    log_error "Nexus is not ready after $((max_attempts * 5))s"
    exit 1
}

# Read the initial admin password from the container
get_initial_password() {
    local initial_pw=""
    initial_pw=$(docker exec brik-nexus cat /nexus-data/admin.password 2>/dev/null || true)
    if [[ -z "$initial_pw" ]]; then
        log_warn "No initial admin.password found - password may already be changed"
        return 1
    fi
    echo "$initial_pw"
}

# Change admin password
change_admin_password() {
    log_info "Changing admin password..."

    local initial_pw=""
    initial_pw=$(get_initial_password) || {
        # Try with the target password to check if already changed
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${NEXUS_NEW_PASSWORD}" \
            "${NEXUS_URL}/service/rest/v1/status/check")
        if [[ "$status" == "200" ]]; then
            log_warn "Admin password already set to target value"
            return 0
        fi
        log_error "Cannot determine current admin password"
        return 1
    }

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${initial_pw}" \
        -X PUT \
        -H "Content-Type: text/plain" \
        -d "${NEXUS_NEW_PASSWORD}" \
        "${NEXUS_URL}/service/rest/v1/security/users/admin/change-password")

    if [[ "$http_code" == "204" ]]; then
        log_ok "Admin password changed"
        save_to_env "NEXUS_ADMIN_PASSWORD" "${NEXUS_NEW_PASSWORD}"
        save_to_env "NEXUS_URL" "${NEXUS_URL}"
    else
        log_error "Failed to change password (HTTP ${http_code})"
        return 1
    fi
}

# Enable Docker Bearer Token Realm
enable_docker_realm() {
    log_info "Enabling Docker Bearer Token Realm..."

    # Get current active realms
    local realms
    realms=$(curl -sf -u "admin:${NEXUS_NEW_PASSWORD}" \
        "${NEXUS_URL}/service/rest/v1/security/realms/active" 2>/dev/null || echo "[]")

    # Check if Docker realm already active
    if echo "$realms" | grep -q "DockerToken"; then
        log_warn "Docker Bearer Token Realm already active"
        return 0
    fi

    # Add DockerToken realm to active list
    local new_realms
    new_realms=$(echo "$realms" | jq '. + ["DockerToken"]')

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${NEXUS_NEW_PASSWORD}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d "$new_realms" \
        "${NEXUS_URL}/service/rest/v1/security/realms/active")

    if [[ "$http_code" == "204" ]]; then
        log_ok "Docker Bearer Token Realm enabled"
    else
        log_error "Failed to enable Docker realm (HTTP ${http_code})"
        return 1
    fi
}

# Enable anonymous access for reads (needed for npm install, docker pull)
enable_anonymous_access() {
    log_info "Enabling anonymous access..."

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${NEXUS_NEW_PASSWORD}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' \
        "${NEXUS_URL}/service/rest/v1/security/anonymous")

    if [[ "$http_code" == "200" ]]; then
        log_ok "Anonymous access enabled"
    else
        log_warn "Anonymous access config returned HTTP ${http_code}"
    fi
}

# Create a hosted repository via Nexus REST API
# Usage: create_repo <format> <name> <json_body>
create_repo() {
    local format="$1"
    local name="$2"
    local body="$3"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${NEXUS_NEW_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${NEXUS_URL}/service/rest/v1/repositories/${format}/hosted")

    case "$http_code" in
        201) log_ok "Repository '${name}' created (${format})" ;;
        400) log_warn "Repository '${name}' already exists (${format})" ;;
        *)   log_error "Failed to create '${name}' (HTTP ${http_code})"; return 1 ;;
    esac
}

# Create all 6 hosted repositories
create_repositories() {
    log_info "Creating hosted repositories..."

    # npm hosted
    create_repo "npm" "brik-npm" '{
        "name": "brik-npm",
        "online": true,
        "storage": {
            "blobStoreName": "default",
            "strictContentTypeValidation": true,
            "writePolicy": "ALLOW"
        }
    }'

    # maven2 hosted (release)
    create_repo "maven" "brik-maven" '{
        "name": "brik-maven",
        "online": true,
        "storage": {
            "blobStoreName": "default",
            "strictContentTypeValidation": true,
            "writePolicy": "ALLOW_ONCE"
        },
        "maven": {
            "versionPolicy": "RELEASE",
            "layoutPolicy": "STRICT",
            "contentDisposition": "INLINE"
        }
    }'

    # pypi hosted
    create_repo "pypi" "brik-pypi" '{
        "name": "brik-pypi",
        "online": true,
        "storage": {
            "blobStoreName": "default",
            "strictContentTypeValidation": true,
            "writePolicy": "ALLOW"
        }
    }'

    # nuget hosted (V3 protocol for modern .NET tooling)
    create_repo "nuget" "brik-nuget" '{
        "name": "brik-nuget",
        "online": true,
        "storage": {
            "blobStoreName": "default",
            "strictContentTypeValidation": true,
            "writePolicy": "ALLOW"
        },
        "nuget": {
            "nugetVersion": "V3"
        }
    }'

    # docker hosted (HTTP connector on port 8082)
    create_repo "docker" "brik-docker" '{
        "name": "brik-docker",
        "online": true,
        "storage": {
            "blobStoreName": "default",
            "strictContentTypeValidation": true,
            "writePolicy": "ALLOW"
        },
        "docker": {
            "v1Enabled": false,
            "forceBasicAuth": true,
            "httpPort": 8082
        }
    }'

    # raw hosted (for Cargo workaround and generic artifacts)
    create_repo "raw" "brik-raw" '{
        "name": "brik-raw",
        "online": true,
        "storage": {
            "blobStoreName": "default",
            "strictContentTypeValidation": false,
            "writePolicy": "ALLOW"
        }
    }'
}

# === Main ===
wait_for_nexus
change_admin_password
enable_docker_realm
enable_anonymous_access
create_repositories

# Save config to .env
save_to_env "NEXUS_HOSTNAME" "${NEXUS_HOSTNAME:-nexus.briklab.test}"
save_to_env "NEXUS_HTTP_PORT" "${NEXUS_HTTP_PORT:-8081}"
save_to_env "NEXUS_DOCKER_PORT" "${NEXUS_DOCKER_PORT:-8082}"

log_ok "Nexus configuration complete"
echo ""
echo -e "${BLUE}Nexus access:${NC}"
echo "  URL      : ${NEXUS_URL}"
echo "  Login    : admin"
echo "  Password : (see .env NEXUS_ADMIN_PASSWORD)"
echo ""
echo -e "${BLUE}Repositories:${NC}"
echo "  npm    : ${NEXUS_URL}/repository/brik-npm/"
echo "  maven  : ${NEXUS_URL}/repository/brik-maven/"
echo "  pypi   : ${NEXUS_URL}/repository/brik-pypi/"
echo "  nuget  : ${NEXUS_URL}/repository/brik-nuget/"
echo "  docker : ${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_DOCKER_PORT:-8082}"
echo "  raw    : ${NEXUS_URL}/repository/brik-raw/"
