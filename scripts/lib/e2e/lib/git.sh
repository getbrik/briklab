#!/usr/bin/env bash
# E2E Git Operations Library
#
# Reusable functions for Git operations in E2E tests.
# Extracted from gitlab-push.sh and gitea-push.sh.
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

# ---------------------------------------------------------------------------
# Push-driven trigger
# ---------------------------------------------------------------------------

# Trigger a CI pipeline by pushing a commit (instead of API trigger).
# Clones the repo, writes a trigger file, commits, and pushes.
# For tag refs, deletes remote tag first, then creates and pushes.
# For branch refs, creates and pushes the branch.
#
# Args: $1 = platform (gitlab|gitea), $2 = project name, $3 = trigger ref
#        trigger_ref format: "main", "vX.Y.Z" (tag), "branch:feat/xxx"
# Output: commit SHA on stdout
e2e.git.trigger_via_push() {
    local platform="$1" project_name="$2" trigger_ref="$3"

    # Build remote URL and credentials based on platform
    local remote_url username token
    case "$platform" in
        gitlab)
            local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
            remote_url="${gitlab_url}/brik/${project_name}.git"
            username="root"
            token="$GITLAB_PAT"
            ;;
        gitea)
            local gitea_url="http://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
            remote_url="${gitea_url}/brik/${project_name}.git"
            username="${GITEA_ADMIN_USER:-brik}"
            token="$GITEA_PAT"
            ;;
        *)
            log_error "Unknown platform: ${platform}"
            return 1
            ;;
    esac

    # Clone the repo
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local askpass_script
    askpass_script=$(mktemp)
    printf "#!/bin/sh\\nprintf '%%s' '%s'\\n" "$token" > "$askpass_script"
    chmod +x "$askpass_script"

    local result=0
    local sha=""
    (
        cd "$tmp_dir" || exit 1

        GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.username=${username}" \
            clone "$remote_url" repo >/dev/null 2>&1 || exit 1
        cd repo || exit 1

        # Write trigger file to ensure a new commit
        printf '%s %s\n' "$(date +%s)" "$trigger_ref" > .brik-trigger
        git add -A >/dev/null 2>&1
        git commit -m "trigger: ${trigger_ref}" >/dev/null 2>&1

        case "$trigger_ref" in
            v[0-9]*)
                # Tag push: push main first, then delete+recreate tag
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.username=${username}" \
                    push origin main >/dev/null 2>&1 || exit 1

                # Delete remote tag if it exists (to re-trigger)
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.username=${username}" \
                    push origin ":refs/tags/${trigger_ref}" >/dev/null 2>&1 || true

                git tag -f "$trigger_ref" >/dev/null 2>&1
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.username=${username}" \
                    push origin "$trigger_ref" >/dev/null 2>&1 || exit 1
                ;;
            branch:*)
                local branch_name="${trigger_ref#branch:}"
                git checkout -b "$branch_name" >/dev/null 2>&1
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.username=${username}" \
                    push -u origin "$branch_name" >/dev/null 2>&1 || exit 1
                ;;
            *)
                # Default: push to main (or whatever ref name)
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.username=${username}" \
                    push origin main >/dev/null 2>&1 || exit 1
                ;;
        esac

        # Output the SHA
        git rev-parse HEAD
    ) > "${tmp_dir}/.sha" 2>/dev/null || result=1

    sha=$(cat "${tmp_dir}/.sha" 2>/dev/null | tail -1)

    rm -f "$askpass_script"
    rm -rf "$tmp_dir"

    if [[ $result -ne 0 || -z "$sha" ]]; then
        log_error "Failed to trigger via push for ${project_name}"
        return 1
    fi

    echo "$sha"
}

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

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
