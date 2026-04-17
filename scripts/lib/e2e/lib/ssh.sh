#!/usr/bin/env bash
# E2E SSH Validation Library
#
# Functions for validating SSH deployments on the briklab ssh-target container.
#
# Prerequisites:
#   - ssh-target container must be running
#   - SSH deploy key must exist at data/ssh-target/deploy_key

[[ -n "${_E2E_SSH_LOADED:-}" ]] && return 0
_E2E_SSH_LOADED=1

# shellcheck source=../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_E2E_SSH_PORT="${SSH_TARGET_PORT:-2223}"
_E2E_SSH_USER="deploy"
_E2E_SSH_HOST="localhost"

# Auto-detect key file relative to BRIKLAB_ROOT
if [[ -n "${BRIKLAB_ROOT:-}" ]]; then
    _E2E_SSH_KEY="${BRIKLAB_ROOT}/data/ssh-target/deploy_key"
else
    _E2E_SSH_KEY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/data/ssh-target/deploy_key"
fi

# Common SSH options
_E2E_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------

# Execute a command on the SSH target.
# Args: $@ = command to run
# Returns: exit code of remote command
# Output: command output on stdout
e2e.ssh.exec() {
    ssh "${_E2E_SSH_OPTS[@]}" \
        -i "$_E2E_SSH_KEY" \
        -p "$_E2E_SSH_PORT" \
        "${_E2E_SSH_USER}@${_E2E_SSH_HOST}" \
        "$@"
}

# Check if a file exists on the SSH target.
# Args: $1 = remote path
# Returns: 0 if exists, 1 otherwise
e2e.ssh.file_exists() {
    local path="$1"
    e2e.ssh.exec "test -f '${path}'" &>/dev/null
}

# Check if a process is running on the SSH target.
# Args: $1 = process name (grep pattern)
# Returns: 0 if running, 1 otherwise
e2e.ssh.process_running() {
    local process="$1"
    e2e.ssh.exec "pgrep -f '${process}'" &>/dev/null
}
