#!/usr/bin/env bash
# E2E Git Operations Library
#
# Reusable functions for Git operations in E2E tests.
# Extracted from push-test-project-gitlab.sh and push-test-project-gitea.sh.
#
# These functions simulate developer actions (commit, push, tag) on test repos.

[[ -n "${_E2E_GIT_LOADED:-}" ]] && return 0
_E2E_GIT_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Core operations
# ---------------------------------------------------------------------------

# Initialize a git repo from a template directory.
# Creates a temporary directory with a git repo, initial commit, and optional tag.
# Args: $1 = source directory (template), $2 = tag (optional, default: v0.1.0)
# Output: path to the temporary directory on stdout
# Caller is responsible for cleanup (rm -rf).
e2e.git.init_from_template() {
    local source_dir="$1"
    local tag="${2:-v0.1.0}"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Template directory not found: ${source_dir}"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    cp -r "${source_dir}"/. "${tmp_dir}/"
    (
        cd "$tmp_dir" || exit 1
        rm -rf .git
        git init -b main >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit -m "Initial commit" >/dev/null 2>&1
        if [[ -n "$tag" ]]; then
            git tag "$tag" >/dev/null 2>&1
        fi
    )

    echo "$tmp_dir"
}

# Push a local repo to a remote URL using GIT_ASKPASS.
# The PAT is never embedded in the process list.
# Args: $1 = local repo dir, $2 = remote URL, $3 = username, $4 = token/PAT
#       $5 = flags (optional, e.g. "--force")
e2e.git.push() {
    local repo_dir="$1"
    local remote_url="$2"
    local username="$3"
    local token="$4"
    local flags="${5:-}"

    local askpass_script
    askpass_script=$(mktemp)
    printf "#!/bin/sh\\nprintf '%%s' '%s'\\n" "$token" > "$askpass_script"
    chmod +x "$askpass_script"

    local push_result=0
    (
        cd "$repo_dir" || exit 1
        # Add or update remote
        if git remote get-url origin &>/dev/null; then
            git remote set-url origin "$remote_url" >/dev/null 2>&1
        else
            git remote add origin "$remote_url" >/dev/null 2>&1
        fi

        # shellcheck disable=SC2086  # Intentional word splitting on flags
        if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.username=${username}" push -u origin main --tags $flags >/dev/null 2>&1; then
            true
        else
            exit 1
        fi
    ) || push_result=1

    rm -f "$askpass_script"
    return "$push_result"
}

# Create a commit in a repo.
# Args: $1 = repo dir, $2 = message, $3 = flags (optional, e.g. "--allow-empty")
e2e.git.commit() {
    local repo_dir="$1"
    local message="$2"
    local flags="${3:-}"

    (
        cd "$repo_dir" || exit 1
        git add -A >/dev/null 2>&1
        # shellcheck disable=SC2086  # Intentional word splitting on flags
        git commit $flags -m "$message" >/dev/null 2>&1
    )
}

# Create a tag in a repo.
# Args: $1 = repo dir, $2 = tag name
e2e.git.tag() {
    local repo_dir="$1"
    local tag_name="$2"
    (
        cd "$repo_dir" || exit 1
        git tag "$tag_name" >/dev/null 2>&1
    )
}

# Push a specific tag to the remote.
# Args: $1 = repo dir, $2 = remote URL, $3 = username, $4 = token, $5 = tag name
e2e.git.push_tag() {
    local repo_dir="$1"
    local remote_url="$2"
    local username="$3"
    local token="$4"
    local tag_name="$5"

    local askpass_script
    askpass_script=$(mktemp)
    printf "#!/bin/sh\\nprintf '%%s' '%s'\\n" "$token" > "$askpass_script"
    chmod +x "$askpass_script"

    local push_result=0
    (
        cd "$repo_dir" || exit 1
        if git remote get-url origin &>/dev/null; then
            git remote set-url origin "$remote_url" >/dev/null 2>&1
        else
            git remote add origin "$remote_url" >/dev/null 2>&1
        fi

        if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.username=${username}" push origin "$tag_name" >/dev/null 2>&1; then
            true
        else
            exit 1
        fi
    ) || push_result=1

    rm -f "$askpass_script"
    return "$push_result"
}

# Push a specific branch to the remote.
# Args: $1 = repo dir, $2 = remote URL, $3 = username, $4 = token, $5 = branch name
e2e.git.push_branch() {
    local repo_dir="$1"
    local remote_url="$2"
    local username="$3"
    local token="$4"
    local branch="$5"

    local askpass_script
    askpass_script=$(mktemp)
    printf "#!/bin/sh\\nprintf '%%s' '%s'\\n" "$token" > "$askpass_script"
    chmod +x "$askpass_script"

    local push_result=0
    (
        cd "$repo_dir" || exit 1
        if git remote get-url origin &>/dev/null; then
            git remote set-url origin "$remote_url" >/dev/null 2>&1
        else
            git remote add origin "$remote_url" >/dev/null 2>&1
        fi

        if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.username=${username}" push -u origin "$branch" >/dev/null 2>&1; then
            true
        else
            exit 1
        fi
    ) || push_result=1

    rm -f "$askpass_script"
    return "$push_result"
}

# Reset a repo to its baseline state (initial commit + tag).
# Force-pushes to overwrite remote history.
# Args: $1 = repo dir, $2 = remote URL, $3 = username, $4 = token
e2e.git.reset_to_baseline() {
    local repo_dir="$1"
    local remote_url="$2"
    local username="$3"
    local token="$4"

    (
        cd "$repo_dir" || exit 1
        # Reset to the first commit
        local first_commit
        first_commit=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
        if [[ -n "$first_commit" ]]; then
            git reset --hard "$first_commit" >/dev/null 2>&1
        fi
    )

    # Force push to reset the remote
    e2e.git.push "$repo_dir" "$remote_url" "$username" "$token" "--force"
}
