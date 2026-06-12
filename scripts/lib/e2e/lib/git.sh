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

    # Derive a stable commit timestamp from the briklab repo's HEAD so
    # each invocation produces the same initial commit (same SHA, same
    # tag commit) across pushes. Without this pin, gitlab-push and
    # jenkins-push of the same test source create commits with different
    # wallclock timestamps, which then propagate as different
    # SOURCE_DATE_EPOCH values inside brik builds and break artifact
    # reproducibility (e.g. python wheel sha256 drift on otherwise
    # identical sources). Falls back to a fixed epoch when briklab is
    # not a git repo.
    local _commit_epoch
    _commit_epoch="$( (cd "${BRIKLAB_ROOT:-.}" && git log -1 --format=%ct HEAD 2>/dev/null) || echo 1700000000)"

    cp -r "${source_dir}"/. "${tmp_dir}/"
    (
        cd "$tmp_dir" || exit 1
        rm -rf .git
        git init -b main >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        GIT_AUTHOR_DATE="@${_commit_epoch} +0000" \
        GIT_COMMITTER_DATE="@${_commit_epoch} +0000" \
            git commit -m "Initial commit" >/dev/null 2>&1
        if [[ -n "$tag" ]]; then
            # Override global git config that may force GPG signing or
            # forbid lightweight tags: with tag.gpgsign=true or
            # tag.forceSignAnnotated=true set in the user's ~/.gitconfig,
            # a bare `git tag X` would either prompt for a signature or
            # error out ("no tag message?") and the tag would never be
            # created in the tmp dir -- silently. The subsequent
            # `git push --tags` would then push nothing and the remote
            # would stay on the old tag. We force lightweight, unsigned.
            git -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag"
        fi
    )

    echo "$tmp_dir"
}

# Create a throwaway GIT_ASKPASS helper script that echoes the given token,
# so the token never appears in the process list. Echoes the script path;
# the caller is responsible for removing it after the git operation.
e2e.git._askpass_file() {
    local token="$1"
    local script
    script=$(mktemp)
    printf "#!/bin/sh\\nprintf '%%s' '%s'\\n" "$token" > "$script"
    chmod +x "$script"
    echo "$script"
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
    askpass_script=$(e2e.git._askpass_file "$token")

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
            git -c "credential.helper=" -c "credential.username=${username}" push -u origin main --tags $flags >/dev/null 2>&1; then
            true
        else
            exit 1
        fi
    ) || push_result=1

    rm -f "$askpass_script"
    return "$push_result"
}

# Clone a remote URL into a local dir using GIT_ASKPASS.
# The PAT is never embedded in the URL, the process list or the clone's
# .git/config (parity with e2e.git.push).
# Args: $1 = remote URL, $2 = destination dir, $3 = username, $4 = token/PAT
e2e.git.clone() {
    local remote_url="$1"
    local dest_dir="$2"
    local username="$3"
    local token="$4"

    local askpass_script
    askpass_script=$(e2e.git._askpass_file "$token")

    local clone_result=0
    GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
        git -c "credential.helper=" -c "credential.username=${username}" \
        clone -q "$remote_url" "$dest_dir" >/dev/null 2>&1 || clone_result=1

    rm -f "$askpass_script"
    return "$clone_result"
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
#
# tag.gpgsign=false / tag.forceSignAnnotated=false override the global
# user config: with tag.gpgsign=true in ~/.gitconfig, `git tag X` would
# require a message (annotated signed tag) and exit 128 -- silently
# under `set -euo pipefail`. We force lightweight, unsigned tags so the
# harness works regardless of the operator's global git config.
e2e.git.tag() {
    local repo_dir="$1"
    local tag_name="$2"
    (
        cd "$repo_dir" || exit 1
        git -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_name" >/dev/null 2>&1
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
    askpass_script=$(e2e.git._askpass_file "$token")

    local push_result=0
    (
        cd "$repo_dir" || exit 1
        if git remote get-url origin &>/dev/null; then
            git remote set-url origin "$remote_url" >/dev/null 2>&1
        else
            git remote add origin "$remote_url" >/dev/null 2>&1
        fi

        if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.helper=" -c "credential.username=${username}" push origin "$tag_name" >/dev/null 2>&1; then
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
    askpass_script=$(e2e.git._askpass_file "$token")

    local push_result=0
    (
        cd "$repo_dir" || exit 1
        if git remote get-url origin &>/dev/null; then
            git remote set-url origin "$remote_url" >/dev/null 2>&1
        else
            git remote add origin "$remote_url" >/dev/null 2>&1
        fi

        if GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.helper=" -c "credential.username=${username}" push -u origin "$branch" >/dev/null 2>&1; then
            true
        else
            exit 1
        fi
    ) || push_result=1

    rm -f "$askpass_script"
    return "$push_result"
}

# Build a v0.1.0 -> v0.2.0 release chain in a fresh temp repo from a template.
# Used by the rollback scenarios: an initial commit tagged v0.1.0, then an empty
# "bump" commit tagged v0.2.0, with VERSION.json marking the head at 0.2.0.
# tag.gpgsign=false / tag.forceSignAnnotated=false neutralise the operator's
# global git config (see e2e.git.tag for the rationale). Echoes the temp dir on
# stdout; the caller pushes it and is responsible for cleanup (rm -rf).
# Args: $1 = template directory.
e2e.git.build_release_chain() {
    local template_dir="$1"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cp -r "${template_dir}"/. "${tmp_dir}/"
    (
        cd "$tmp_dir" || exit 1
        rm -rf .git
        echo '{"version": "0.2.0"}' > VERSION.json
        git init -b main >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit -m "Initial commit" >/dev/null 2>&1
        git -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag v0.1.0 >/dev/null 2>&1
        git add -A >/dev/null 2>&1
        git commit --allow-empty -m "Bump to v0.2.0" >/dev/null 2>&1
        git -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag v0.2.0 >/dev/null 2>&1
    )

    echo "$tmp_dir"
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
            local gitea_url="https://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"
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
    askpass_script=$(e2e.git._askpass_file "$token")

    local result=0
    local sha=""
    (
        cd "$tmp_dir" || exit 1

        GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
            git -c "credential.helper=" -c "credential.username=${username}" \
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
                    git -c "credential.helper=" -c "credential.username=${username}" \
                    push origin main >/dev/null 2>&1 || exit 1

                # Delete remote tag if it exists (to re-trigger)
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.helper=" -c "credential.username=${username}" \
                    push origin ":refs/tags/${trigger_ref}" >/dev/null 2>&1 || true

                # tag.gpgsign override (same trap as the e2e.git.tag
                # header). Without it, a global
                # tag.gpgsign=true silently fails `git tag` here, the
                # subsequent push fails, the subshell exits 1, and the
                # whole scenario reports "Failed to trigger via push"
                # without ever creating the tag remotely.
                git -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag -f "$trigger_ref" >/dev/null 2>&1
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.helper=" -c "credential.username=${username}" \
                    push origin "$trigger_ref" >/dev/null 2>&1 || exit 1
                ;;
            branch:*)
                local branch_name="${trigger_ref#branch:}"
                # The branch may already exist remotely from a prior
                # run; the new .brik-trigger commit on top of a fresh
                # main checkout will not be a fast-forward, so force the
                # push. The tag-trigger flow above uses a delete+recreate
                # for the same reason -- this is the equivalent for
                # branches.
                git checkout -b "$branch_name" >/dev/null 2>&1
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.helper=" -c "credential.username=${username}" \
                    push -u --force origin "$branch_name" >/dev/null 2>&1 || exit 1
                ;;
            docs-only)
                # Two-phase trigger for an incremental docs-only commit.
                #
                # The dynamic-pipeline planner needs a real
                # CI_COMMIT_BEFORE_SHA to compute a diff. A single
                # force-push to a fresh repo is a planner cold-start
                # (CI_COMMIT_BEFORE_SHA=0000) and balanced mode then
                # conservatively runs every stage -- so a docs-only
                # skip can never be exhibited.
                #
                # Phase 1 pushes the baseline (the pre-trigger HEAD) to
                # main with `-o ci.skip` so the ref exists but no
                # pipeline runs. Phase 2 amends the trigger commit to
                # touch only a doc file and pushes it as a fast-forward;
                # the pipeline for that commit sees baseline as its
                # CI_COMMIT_BEFORE_SHA, the planner diffs a docs-only
                # change, and the build/lint/test grid is skipped.
                local baseline_sha
                baseline_sha="$(git rev-parse HEAD~1)"

                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.helper=" -c "credential.username=${username}" \
                    push -o ci.skip --force origin \
                    "${baseline_sha}:refs/heads/main" >/dev/null 2>&1 || exit 1

                # Carry a genuine docs change so the scenario is
                # self-documenting (the .brik-trigger plumbing file
                # alone would also skip the grid, being unmatched by
                # every stage's impact globs).
                mkdir -p docs
                printf 'E2E docs-only trigger at %s\n' "$(date +%s)" \
                    >> docs/e2e-trigger.md
                git add -A >/dev/null 2>&1
                git commit --amend -m "docs: e2e docs-only trigger" >/dev/null 2>&1

                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.helper=" -c "credential.username=${username}" \
                    push origin "HEAD:refs/heads/main" >/dev/null 2>&1 || exit 1
                ;;
            *)
                # Default: push to main (or whatever ref name)
                GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 \
                    git -c "credential.helper=" -c "credential.username=${username}" \
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
