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

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/push.sh
source "${SCRIPT_DIR}/lib/push.sh"
reload_env

ensure_gitlab_pat

if [[ -z "${GITLAB_PAT:-}" ]]; then
    log_error "GITLAB_PAT is not set. Run briklab.sh setup first."
    exit 1
fi

e2e.push.brik_repos "gitlab"
e2e.push.test_projects "gitlab" "${E2E_TEST_PROJECTS:-node-minimal}"
