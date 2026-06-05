#!/usr/bin/env bash
# GitLab PAT management - validate or regenerate via rails runner.
#
# Usage:
#   source "path/to/auth/gitlab-pat.sh"
#   briklab.auth.gitlab_pat

[[ -n "${_BRIKLAB_GITLAB_PAT_LOADED:-}" ]] && return 0
_BRIKLAB_GITLAB_PAT_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
# shellcheck source=../checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/../checks.sh"

# Ensure a valid GitLab PAT exists.
# If GITLAB_PAT is valid, does nothing.
# If invalid/missing, creates a fresh one via rails runner and updates .env.
briklab.auth.gitlab_pat() {
    # Fast path: validate existing PAT (shared probe with verify/preflight)
    if briklab.check.gitlab_pat; then
        log_ok "GitLab PAT valid"
        return 0
    fi
    if [[ -n "${GITLAB_PAT:-}" ]]; then
        log_warn "GitLab PAT invalid, regenerating..."
    else
        log_warn "No GITLAB_PAT set, creating one..."
    fi

    # Revoke stale token and create fresh one via rails runner
    local pat
    pat=$(cat <<'RUBY' | docker exec -i brik-gitlab gitlab-rails runner - 2>/dev/null | tail -1
user = User.find_by_username("root")
existing = user.personal_access_tokens.active.find_by(name: "brik-briklab")
existing&.revoke!
token = user.personal_access_tokens.create!(
  name: "brik-briklab",
  scopes: ["api", "read_api", "read_repository", "write_repository", "admin_mode"],
  expires_at: 365.days.from_now
)
puts token.token
RUBY
)

    if [[ -z "$pat" ]]; then
        log_error "Failed to create GitLab PAT via rails runner"
        return 1
    fi

    export GITLAB_PAT="$pat"
    save_to_env "GITLAB_PAT" "$pat"
    log_ok "GitLab PAT refreshed: ${pat:0:15}..."
}
