#!/usr/bin/env bash
# E2E SCM-host abstraction
#
# A change request (CR) is the host-neutral name for what GitLab calls a
# "merge request" and Gitea/GitHub call a "pull request". The two git hosts
# differ in API shape:
#
#   Gitea : POST /repos/{owner}/{repo}/pulls   body {head, base, title}   -> .number
#   GitLab: POST /projects/:id/merge_requests  body {source_branch, ...}  -> .iid
#
# This module exposes ONE contract -- e2e.scm.create_change_request -- so the
# CI/CD orchestrator harnesses (jenkins-test.sh, gitlab-test.sh) stay agnostic
# to which git host backs the repo. It is the harness-side counterpart of the
# decoupling enforced in brik: the orchestrator never hard-codes a git host.
#
# Prerequisites: the source branch must already be pushed (e2e.git.push_branch).

[[ -n "${_E2E_SCM_LOADED:-}" ]] && return 0
_E2E_SCM_LOADED=1

_SCM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gitea-api.sh
source "${_SCM_DIR}/gitea-api.sh"
# shellcheck source=gitlab-api.sh
source "${_SCM_DIR}/gitlab-api.sh"

# Open a change request, dispatching to the backing git host.
# Args: $1 = host (gitea|gitlab)
#       $2 = repo path "owner/repo" (e.g. "brik/node-workflow-trunk")
#       $3 = source/head branch (already pushed)
#       $4 = target/base branch (default: main)
#       $5 = title (optional)
# Output: the change-request number on stdout (Gitea .number / GitLab .iid);
#         empty + non-zero status on failure.
e2e.scm.create_change_request() {
    local host="$1" repo_path="$2" source_branch="$3" target_branch="${4:-main}" title="${5:-}"

    case "$host" in
        gitea)
            local owner="${repo_path%%/*}" repo="${repo_path#*/}"
            e2e.gitea.create_pull_request "$owner" "$repo" "$source_branch" "$target_branch" "$title"
            ;;
        gitlab)
            local encoded="${repo_path//\//%2F}" pid
            pid="$(e2e.gitlab.get_project_id "$encoded")"
            if [[ -z "$pid" ]]; then
                log_error "scm: cannot resolve GitLab project id for '${repo_path}'"
                return 1
            fi
            e2e.gitlab.create_merge_request "$pid" "$source_branch" "$target_branch" "$title"
            ;;
        *)
            log_error "scm: unknown git host '${host}' (expected gitea|gitlab)"
            return 1
            ;;
    esac
}
