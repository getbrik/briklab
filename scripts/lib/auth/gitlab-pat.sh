#!/usr/bin/env bash
# GitLab PAT management - validate or regenerate via rails runner.
#
# Usage:
#   source "path/to/auth/gitlab-pat.sh"
#   ensure_gitlab_pat

[[ -n "${_BRIKLAB_GITLAB_PAT_LOADED:-}" ]] && return 0
_BRIKLAB_GITLAB_PAT_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# Ensure a valid GitLab PAT exists.
# If GITLAB_PAT is valid, does nothing.
# If invalid/missing, creates a fresh one via rails runner and updates .env.
ensure_gitlab_pat() {
    local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"

    # Fast path: validate existing PAT
    if [[ -n "${GITLAB_PAT:-}" ]]; then
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
            -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
            "${gitlab_url}/api/v4/user" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log_ok "GitLab PAT valid"
            return 0
        fi
        log_warn "GitLab PAT invalid (HTTP ${http_code}), regenerating..."
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
