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

# Source E2E libraries
# shellcheck source=lib/gitea-api.sh
source "${SCRIPT_DIR}/lib/gitea-api.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"

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

# Push a local directory as a Git repo to briklab Gitea.
push_to_gitea() {
    local source_dir="$1"
    local remote_path="$2"   # e.g. brik/brik
    local tag="$3"

    log_info "Pushing ${source_dir} -> ${remote_path}..."

    local tmp_dir
    tmp_dir=$(e2e.git.init_from_template "$source_dir" "$tag")

    local gitea_user="${GITEA_ADMIN_USER:-brik}"

    if e2e.git.push "$tmp_dir" "${GITEA_URL}/${remote_path}.git" "$gitea_user" "$GITEA_PAT" "--force"; then
        log_ok "Pushed ${remote_path} with tag ${tag}"
    else
        log_error "Failed to push ${remote_path}"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "=== Pushing Brik repos to briklab Gitea ==="
echo ""

# 1. Create and push brik/brik (full repo, same as production)
log_info "--- brik/brik (full repo) ---"
e2e.gitea.create_repo "brik"
push_to_gitea "$BRIK_ROOT" "brik/brik" "$TAG_NAME"
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
    e2e.gitea.create_repo "$proj"
    push_to_gitea "$local_dir" "brik/${proj}" "$TAG_NAME"
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
