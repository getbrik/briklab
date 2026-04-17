#!/usr/bin/env bash
# E2E auth aggregator - sources all auth scripts for E2E convenience.
#
# Instead of sourcing 2-4 auth scripts individually in each E2E script,
# source this single file:
#   source "${SCRIPT_DIR}/lib/auth.sh"
#
# Provides: ensure_gitlab_pat, ensure_gitea_pat,
#           ensure_argocd_port_forward, ensure_argocd_token

[[ -n "${_E2E_AUTH_LOADED:-}" ]] && return 0
_E2E_AUTH_LOADED=1

_E2E_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../auth/gitlab-pat.sh
source "${_E2E_AUTH_DIR}/../../auth/gitlab-pat.sh"
# shellcheck source=../../auth/gitea-pat.sh
source "${_E2E_AUTH_DIR}/../../auth/gitea-pat.sh"
# shellcheck source=../../auth/argocd-portfwd.sh
source "${_E2E_AUTH_DIR}/../../auth/argocd-portfwd.sh"
# shellcheck source=../../auth/argocd-token.sh
source "${_E2E_AUTH_DIR}/../../auth/argocd-token.sh"
