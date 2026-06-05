#!/usr/bin/env bash
# briklab.wait.until - the single poll-until-ready loop (transverse notion).
# Sourced, not executed. Replaces the per-service wait_for_* loops.
# Does NOT set shell options - callers control their own.

[[ -n "${_BRIKLAB_WAIT_LOADED:-}" ]] && return 0
_BRIKLAB_WAIT_LOADED=1

# briklab.wait.until <timeout_s> <interval_s> <cmd...>
# Runs <cmd> repeatedly until it exits 0 or <timeout_s> elapses. Silent.
# Returns 0 when ready, 1 on timeout. <cmd> is invoked directly (no eval).
briklab.wait.until() {
    local timeout="$1" interval="$2"; shift 2
    local deadline=$(( SECONDS + timeout ))
    while true; do
        "$@" && return 0
        (( SECONDS >= deadline )) && return 1
        sleep "$interval"
    done
}
