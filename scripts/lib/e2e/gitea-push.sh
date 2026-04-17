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

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/push.sh
source "${SCRIPT_DIR}/lib/push.sh"
reload_env

if [[ -z "${GITEA_PAT:-}" ]]; then
    log_error "GITEA_PAT is not set. Run setup/gitea.sh first."
    exit 1
fi

e2e.push.brik_repos "gitea"
e2e.push.test_projects "gitea" "${E2E_JENKINS_PROJECTS:-node-minimal}"
