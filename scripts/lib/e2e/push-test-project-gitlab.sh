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

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/gitlab-pat.sh
source "${SCRIPT_DIR}/../auth/gitlab-pat.sh"
reload_env

# Source E2E libraries
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"

GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
GITLAB_PAT="${GITLAB_PAT:-}"
TAG_NAME="v0.1.0"

# Test projects to push (comma-separated, default: node-minimal)
TEST_PROJECTS="${E2E_TEST_PROJECTS:-node-minimal}"

# Ensure PAT is valid (refresh if expired/missing)
ensure_gitlab_pat

if [[ -z "$GITLAB_PAT" ]]; then
    log_error "GITLAB_PAT is not set. Run briklab.sh setup first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Push a local directory as a Git repo to briklab GitLab.
push_to_gitlab() {
    local source_dir="$1"
    local remote_path="$2"   # e.g. brik/brik
    local tag="$3"

    log_info "Pushing ${source_dir} -> ${remote_path}..."

    local tmp_dir
    tmp_dir=$(e2e.git.init_from_template "$source_dir" "$tag")

    # Unprotect main branch to allow force push (GitLab protects it by default)
    local encoded_path
    encoded_path=$(printf '%s' "$remote_path" | jq -sRr @uri 2>/dev/null || \
        python3 -c "import urllib.parse; print(urllib.parse.quote('${remote_path}', safe=''))" 2>/dev/null)
    e2e.gitlab.api_delete "projects/${encoded_path}/protected_branches/main"

    if e2e.git.push "$tmp_dir" "${GITLAB_URL}/${remote_path}.git" "root" "$GITLAB_PAT" "--force"; then
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
log_info "=== Pushing Brik repos to briklab GitLab ==="
echo ""

# 1. Create the 'brik' group
e2e.gitlab.ensure_group "brik"
echo ""

# 2. Create and push brik/brik (runtime + brik-lib + schemas)
log_info "--- brik/brik (runtime, brik-lib, schemas) ---"
e2e.gitlab.create_project "brik" "brik"
push_to_gitlab "$BRIK_ROOT" "brik/brik" "$TAG_NAME"
echo ""

# 3. Create and push brik/gitlab-templates (shared library)
log_info "--- brik/gitlab-templates (GitLab shared library) ---"
e2e.gitlab.create_project "brik" "gitlab-templates"
push_to_gitlab "$BRIK_ROOT/shared-libs/gitlab" "brik/gitlab-templates" "$TAG_NAME"
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
    e2e.gitlab.create_project "brik" "$proj"
    push_to_gitlab "$local_dir" "brik/${proj}" "$TAG_NAME"
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
