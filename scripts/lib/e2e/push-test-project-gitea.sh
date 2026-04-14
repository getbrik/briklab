#!/usr/bin/env bash
# Push the Brik repos and test projects to briklab Gitea (for Jenkins).
#
# Always pushes:
#   1. brik/brik           - The Brik runtime, brik-lib, schemas, and Jenkins shared lib
#
# Then pushes test projects:
#   E2E_JENKINS_PROJECTS - Comma-separated list (default: node-minimal)
#
# Each repo is tagged with v0.1.0.
#
# Prerequisites:
#   - briklab Gitea must be running
#   - GITEA_PAT must be set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BRIK_ROOT="$(cd "$PROJECT_ROOT/../brik" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

GITEA_URL="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
GITEA_PAT="${GITEA_PAT:-}"
TAG_NAME="v0.1.0"

# Test projects to push (comma-separated, default: node-minimal)
TEST_PROJECTS="${E2E_JENKINS_PROJECTS:-node-minimal}"

if [[ -z "$GITEA_PAT" ]]; then
    log_error "GITEA_PAT is not set. Run setup/gitea.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a Gitea repo under the authenticated user.
# Returns nothing; logs result.
create_repo() {
    local repo_name="$1"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: token ${GITEA_PAT}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"private\":false}" \
        "${GITEA_URL}/api/v1/user/repos")

    case "$http_code" in
        201) log_ok "Repo 'brik/${repo_name}' created" ;;
        409) log_info "Repo 'brik/${repo_name}' already exists" ;;
        *)   log_warn "Repo creation returned HTTP ${http_code}" ;;
    esac
}

# Push a local directory as a Git repo to briklab Gitea.
push_directory() {
    local source_dir="$1"
    local remote_path="$2"   # e.g. brik/brik
    local tag="$3"

    local original_dir="$PWD"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064  # Intentional: capture current values
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
    local remote_url="${GITEA_URL}/${remote_path}.git"
    git remote add origin "$remote_url" >/dev/null 2>&1

    local askpass_script
    askpass_script=$(mktemp)
    # Use single quotes in the generated script to prevent shell expansion of token chars
    printf "#!/bin/sh\\nprintf '%%s' '%s'\\n" "$GITEA_PAT" > "$askpass_script"
    chmod +x "$askpass_script"
    # shellcheck disable=SC2064  # Intentional: capture current askpass_script value
    trap "cd '$original_dir'; rm -rf '$tmp_dir' '$askpass_script'" RETURN

    # Gitea user from PAT
    local gitea_user="${GITEA_ADMIN_USER:-brik}"

    if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
        git -c "credential.username=${gitea_user}" push -u origin main --tags --force >/dev/null 2>&1; then
        log_ok "Pushed ${remote_path} with tag ${tag}"
    else
        log_error "Failed to push ${remote_path}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "=== Pushing Brik repos to briklab Gitea ==="
echo ""

# 1. Create and push brik/brik (full repo, same as production)
log_info "--- brik/brik (full repo) ---"
create_repo "brik"
push_directory "$BRIK_ROOT" "brik/brik" "$TAG_NAME"
echo ""

# 2. Create and push test projects
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
    create_repo "$proj"
    push_directory "$local_dir" "brik/${proj}" "$TAG_NAME"
    PUSHED_PROJECTS+=("$proj")
    echo ""
done

log_ok "=== All repos pushed to Gitea ==="
echo ""
echo -e "${BLUE}Projects on Gitea:${NC}"
echo "  ${GITEA_URL}/brik/brik"
for proj in "${PUSHED_PROJECTS[@]}"; do
    echo "  ${GITEA_URL}/brik/${proj}"
done
