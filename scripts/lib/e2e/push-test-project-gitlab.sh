#!/usr/bin/env bash
# Push the Brik repos and test projects to briklab GitLab.
#
# Always pushes:
#   1. brik/brik           - The Brik runtime and brik-lib
#   2. brik/gitlab-templates - The GitLab shared library templates
#
# Then pushes test projects from test-projects/ directory:
#   E2E_TEST_PROJECTS - Comma-separated list (default: node-minimal)
#
# Each repo is tagged with v0.1.0.
#
# Prerequisites:
#   - briklab GitLab must be running
#   - GITLAB_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BRIK_ROOT="$(cd "$PROJECT_ROOT/../brik" && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
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

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PAT="${GITLAB_PAT:-}"
TAG_NAME="v0.1.0"

# Test projects to push (comma-separated, default: node-minimal)
TEST_PROJECTS="${E2E_TEST_PROJECTS:-node-minimal}"

# Ensure PAT is valid (refresh if expired/missing)
# shellcheck source=ensure-gitlab-pat.sh
. "${SCRIPT_DIR}/ensure-gitlab-pat.sh"
ensure_pat "$ENV_FILE"

if [[ -z "$GITLAB_PAT" ]]; then
    log_error "GITLAB_PAT is not set. Run briklab.sh setup first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a GitLab group if it does not exist.
create_group() {
    local group_name="$1"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${GITLAB_URL}/api/v4/groups" \
        -d "name=${group_name}&path=${group_name}&visibility=public")

    case "$http_code" in
        201) log_ok "Group '${group_name}' created" ;;
        400) log_info "Group '${group_name}' already exists" ;;
        *)   log_warn "Group creation returned HTTP ${http_code}" ;;
    esac
}

# Create a GitLab project under a group (namespace).
# Returns the project ID.
create_project() {
    local namespace="$1"
    local project_name="$2"

    # Get namespace ID
    local ns_id
    ns_id=$(curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${GITLAB_URL}/api/v4/namespaces?search=${namespace}" | \
        python3 -c "import sys,json; data=json.load(sys.stdin); print(next((n['id'] for n in data if n['path']=='${namespace}'), ''))" 2>/dev/null || true)

    if [[ -z "$ns_id" ]]; then
        log_warn "Namespace '${namespace}' not found, creating project under root namespace"
        ns_id=""
    fi

    local data="name=${project_name}&path=${project_name}&visibility=public&initialize_with_readme=false"
    if [[ -n "$ns_id" ]]; then
        data="${data}&namespace_id=${ns_id}"
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${GITLAB_URL}/api/v4/projects" \
        -d "$data")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        201)
            local project_id
            project_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
            log_ok "Project '${namespace}/${project_name}' created (ID: ${project_id})"
            echo "$project_id"
            ;;
        400)
            log_info "Project '${namespace}/${project_name}' already exists"
            # Get existing project ID
            local encoded_path
            encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${namespace}/${project_name}', safe=''))")
            local existing_id
            existing_id=$(curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
                "${GITLAB_URL}/api/v4/projects/${encoded_path}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
            echo "$existing_id"
            ;;
        *)
            log_error "Project creation failed (HTTP ${http_code}): ${body}"
            return 1
            ;;
    esac
}

# Push a local directory as a Git repo to briklab GitLab.
push_directory() {
    local source_dir="$1"
    local remote_path="$2"   # e.g. brik/brik
    local tag="$3"

    local original_dir="$PWD"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064  # Intentional: capture current values of original_dir and tmp_dir
    trap "cd '$original_dir'; rm -rf '$tmp_dir'" RETURN

    log_info "Pushing ${source_dir} -> ${remote_path}..."

    # Create a temporary git repo
    cp -r "$source_dir"/. "$tmp_dir/"
    cd "$tmp_dir"
    rm -rf .git
    git init -b main >/dev/null 2>&1
    git add -A >/dev/null 2>&1
    git commit -m "Initial commit" >/dev/null 2>&1

    # Tag
    git tag "$tag" >/dev/null 2>&1

    # Push using GIT_ASKPASS to avoid embedding PAT in process list
    local remote_url="${GITLAB_URL}/${remote_path}.git"
    git remote add origin "$remote_url" >/dev/null 2>&1

    local askpass_script
    askpass_script=$(mktemp)
    printf '#!/bin/sh\necho "%s"' "$GITLAB_PAT" > "$askpass_script"
    chmod +x "$askpass_script"

    # Unprotect main branch to allow force push (GitLab protects it by default)
    curl -s -o /dev/null -X DELETE \
        -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
        "${GITLAB_URL}/api/v4/projects/$(python3 -c "import urllib.parse; print(urllib.parse.quote('${remote_path}', safe=''))")/protected_branches/main" 2>/dev/null || true

    if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
        git -c credential.username=root push -u origin main --tags --force >/dev/null 2>&1; then
        log_ok "Pushed ${remote_path} with tag ${tag}"
    else
        log_error "Failed to push ${remote_path}"
        rm -f "$askpass_script"
        return 1
    fi
    rm -f "$askpass_script"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "=== Pushing Brik repos to briklab GitLab ==="
echo ""

# 1. Create the 'brik' group
create_group "brik"
echo ""

# 2. Create and push brik/brik (runtime + brik-lib + schemas)
log_info "--- brik/brik (runtime, brik-lib, schemas) ---"
create_project "brik" "brik"
push_directory "$BRIK_ROOT" "brik/brik" "$TAG_NAME"
echo ""

# 3. Create and push brik/gitlab-templates (shared library)
log_info "--- brik/gitlab-templates (GitLab shared library) ---"
create_project "brik" "gitlab-templates"
push_directory "$BRIK_ROOT/shared-libs/gitlab" "brik/gitlab-templates" "$TAG_NAME"
echo ""

# 4. Create and push test projects
PUSHED_PROJECTS=()

IFS=',' read -ra PROJECTS_ARRAY <<< "$TEST_PROJECTS"
for proj in "${PROJECTS_ARRAY[@]}"; do
    proj="$(echo "$proj" | tr -d '[:space:]')"
    [[ -z "$proj" ]] && continue

    local_dir="${PROJECT_ROOT}/test-projects/${proj}"
    if [[ ! -d "$local_dir" ]]; then
        log_warn "Test project directory not found: ${local_dir} -- skipping"
        continue
    fi

    log_info "--- brik/${proj} (test project) ---"
    create_project "brik" "$proj"
    push_directory "$local_dir" "brik/${proj}" "$TAG_NAME"
    PUSHED_PROJECTS+=("$proj")
    echo ""
done

log_ok "=== All repos pushed successfully ==="
echo ""
echo -e "${BLUE}Projects on briklab:${NC}"
echo "  ${GITLAB_URL}/brik/brik"
echo "  ${GITLAB_URL}/brik/gitlab-templates"
for proj in "${PUSHED_PROJECTS[@]}"; do
    echo "  ${GITLAB_URL}/brik/${proj}"
done
