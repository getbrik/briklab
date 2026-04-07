#!/usr/bin/env bash
# Ensure a valid GitLab PAT exists before running E2E tests.
# Sources this file from other scripts: . "$(dirname "$0")/ensure-gitlab-pat.sh"
#
# If GITLAB_PAT is valid, does nothing.
# If invalid/missing, creates a fresh one via rails runner and updates .env.

_ENSURE_PAT_LOADED="${_ENSURE_PAT_LOADED:-}"
[[ -n "$_ENSURE_PAT_LOADED" ]] && return 0
_ENSURE_PAT_LOADED=1

ensure_pat() {
    local gitlab_url="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
    local env_file="${1:-}"

    # Fast path: validate existing PAT
    if [[ -n "${GITLAB_PAT:-}" ]]; then
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
            -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
            "${gitlab_url}/api/v4/user" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            return 0
        fi
        echo -e "\033[1;33m[WARN]\033[0m  PAT invalid (HTTP ${http_code}), regenerating..."
    else
        echo -e "\033[1;33m[WARN]\033[0m  No GITLAB_PAT set, creating one..."
    fi

    # Create fresh PAT via rails runner (revokes stale one if any)
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
        echo -e "\033[0;31m[ERROR]\033[0m Failed to create PAT via rails runner"
        return 1
    fi

    export GITLAB_PAT="$pat"
    echo -e "\033[0;32m[OK]\033[0m    PAT refreshed: ${pat:0:15}..."

    # Update .env if path provided
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        if grep -q "^GITLAB_PAT=" "$env_file"; then
            sed -i.bak "s|^GITLAB_PAT=.*|GITLAB_PAT=${pat}|" "$env_file" && rm -f "${env_file}.bak"
        else
            echo "GITLAB_PAT=${pat}" >> "$env_file"
        fi
    fi
}
