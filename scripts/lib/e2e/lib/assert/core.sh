#!/usr/bin/env bash
# E2E Assertion Library -- core engine.
#
# Domain-agnostic assertion primitives: pass/fail accounting, generic value
# assertions, JSON document assertions, generic pipeline/build/job status, and
# job-log scanning. Brik aggregate-report and infra-state assertions live in
# the sibling report.sh; assert.sh sources both as a facade.
#
# Usage (via the facade):
#   source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
#   assert.init
#   assert.equals "check version" "1.0" "$version"
#   assert.report  # prints summary, returns 1 if any failures

[[ -n "${_E2E_ASSERT_CORE_LOADED:-}" ]] && return 0
_E2E_ASSERT_CORE_LOADED=1

# shellcheck source=../../../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common.sh"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

E2E_ASSERT_PASS=0
E2E_ASSERT_FAIL=0
E2E_ASSERT_ERRORS=()

# Directory holding the error-pattern config files (lib/e2e/lib, the parent of
# this assert/ directory).
_E2E_ASSERT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

assert._pass() {
    local desc="$1"
    E2E_ASSERT_PASS=$((E2E_ASSERT_PASS + 1))
    echo -e "  ${GREEN}[PASS]${NC} $desc"
}

assert._fail() {
    local desc="$1"
    local detail="${2:-}"
    E2E_ASSERT_FAIL=$((E2E_ASSERT_FAIL + 1))
    E2E_ASSERT_ERRORS+=("$desc")
    if [[ -n "$detail" ]]; then
        echo -e "  ${RED}[FAIL]${NC} $desc -- $detail"
    else
        echo -e "  ${RED}[FAIL]${NC} $desc"
    fi
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

# Reset counters. Call at the start of each test.
assert.init() {
    E2E_ASSERT_PASS=0
    E2E_ASSERT_FAIL=0
    E2E_ASSERT_ERRORS=()
}

# Print summary and return 1 if any assertions failed.
assert.report() {
    local total=$((E2E_ASSERT_PASS + E2E_ASSERT_FAIL))
    echo ""
    echo -e "${BOLD}Assertion Summary: ${E2E_ASSERT_PASS} passed, ${E2E_ASSERT_FAIL} failed (${total} total)${NC}"

    if [[ ${E2E_ASSERT_FAIL} -gt 0 ]]; then
        echo -e "${RED}Failed assertions:${NC}"
        for err in "${E2E_ASSERT_ERRORS[@]}"; do
            echo -e "  - $err"
        done
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Generic assertions
# ---------------------------------------------------------------------------

# assert.true <description> <command...>
# Evaluates command; passes if exit code is 0.
assert.true() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        assert._pass "$desc"
    else
        assert._fail "$desc"
    fi
}

# assert.false <description> <command...>
# Evaluates command; passes if exit code is non-zero.
assert.false() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        assert._fail "$desc" "expected failure but command succeeded"
    else
        assert._pass "$desc"
    fi
}

# assert.equals <description> <expected> <actual>
assert.equals() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "expected='${expected}' actual='${actual}'"
    fi
}

# assert.not_empty <description> <value>
assert.not_empty() {
    local desc="$1" value="$2"
    if [[ -n "$value" ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "value is empty"
    fi
}

# assert.contains <description> <haystack> <needle>
assert.contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "does not contain '${needle}'"
    fi
}

# assert.not_contains <description> <haystack> <needle>
assert.not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "unexpectedly contains '${needle}'"
    fi
}

# ---------------------------------------------------------------------------
# JSON document assertions
# ---------------------------------------------------------------------------

# assert.json_eq <description> <file> <jq-path> <expected_json>
# Reads jq-path from <file> and compares against <expected_json> (literal,
# pass quoted strings as '"value"').
assert.json_eq() {
    local desc="$1" file="$2" path="$3" expected="$4"
    if [[ ! -f "$file" ]]; then
        assert._fail "$desc" "file not found: ${file}"
        return
    fi
    local actual
    actual=$(jq -c "$path" "$file" 2>/dev/null || echo "<error>")
    if [[ "$actual" == "$expected" ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "expected=${expected} actual=${actual}"
    fi
}

# assert.json_match <description> <file> <jq-path> <regex>
# Reads jq-path with -r and matches against ERE regex.
assert.json_match() {
    local desc="$1" file="$2" path="$3" regex="$4"
    if [[ ! -f "$file" ]]; then
        assert._fail "$desc" "file not found: ${file}"
        return
    fi
    local actual
    actual=$(jq -r "$path" "$file" 2>/dev/null || echo "")
    if [[ "$actual" =~ $regex ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "value '${actual}' does not match /${regex}/"
    fi
}

# assert.json_ge <description> <file> <jq-path> <min>
# Reads jq-path (numeric) and asserts value >= min.
assert.json_ge() {
    local desc="$1" file="$2" path="$3" min="$4"
    if [[ ! -f "$file" ]]; then
        assert._fail "$desc" "file not found: ${file}"
        return
    fi
    local actual
    actual=$(jq -r "$path" "$file" 2>/dev/null || echo "")
    if [[ "$actual" =~ ^[0-9]+$ ]] && [[ "$actual" -ge "$min" ]]; then
        assert._pass "$desc"
    else
        assert._fail "$desc" "value '${actual}' is not a number >= ${min}"
    fi
}

# ---------------------------------------------------------------------------
# Pipeline / Build status assertions
# ---------------------------------------------------------------------------

# assert.pipeline_succeeded <pipeline_status>
assert.pipeline_succeeded() {
    local status="$1"
    assert.equals "Pipeline succeeded" "success" "$status"
}

# assert.pipeline_failed <pipeline_status>
assert.pipeline_failed() {
    local status="$1"
    assert.equals "Pipeline failed (expected)" "failed" "$status"
}

# assert.build_succeeded <build_result>
assert.build_succeeded() {
    local result="$1"
    assert.equals "Build succeeded" "SUCCESS" "$result"
}

# assert.build_failed <build_result>
assert.build_failed() {
    local result="$1"
    assert.equals "Build failed (expected)" "FAILURE" "$result"
}

# ---------------------------------------------------------------------------
# Job-level assertions
# ---------------------------------------------------------------------------

# assert.job_status <jobs_json> <job_name> <expected_status>
# Uses jq to extract job status from GitLab jobs JSON array.
assert.job_status() {
    local jobs_json="$1" job_name="$2" expected="$3"
    local actual
    actual=$(echo "$jobs_json" | jq -r \
        --arg name "$job_name" \
        '[.[] | select(.name == $name)][0].status // "not_found"' 2>/dev/null || echo "unknown")
    assert.equals "Job '${job_name}' status" "$expected" "$actual"
}

# Strip comment lines (# ...) and blank lines from a pattern file and emit
# the result on stdout. Required because grep -f treats blank lines as
# "match every line" (both BSD and GNU grep), which silently broke
# assert.job_logs_clean: the broken match-everything in error-patterns
# was cancelled by the same broken match-everything in error-ignore-patterns,
# producing a permanent silent PASS regardless of log content.
assert._strip_pattern_comments() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -E -v '^[[:space:]]*(#|$)' "$file" 2>/dev/null || true
}

# assert.job_logs_clean <job_log_text>
# Checks that job log does not contain known error patterns.
# Uses three pattern files from lib/ directory:
#   error-patterns.conf          - errors filtered by error-ignore-patterns.conf
#   error-ignore-patterns.conf   - lines to drop from the error matches
#   false-positive-patterns.conf - patterns ALWAYS treated as errors,
#                                   bypassing the ignore filter (use for
#                                   noise the project considers a bug)
assert.job_logs_clean() {
    local log_text="$1"
    local desc="${2:-Job logs clean}"
    local patterns_file="${_E2E_ASSERT_LIB_DIR}/error-patterns.conf"
    local ignore_file="${_E2E_ASSERT_LIB_DIR}/error-ignore-patterns.conf"
    local fp_file="${_E2E_ASSERT_LIB_DIR}/false-positive-patterns.conf"

    if [[ ! -f "$patterns_file" ]]; then
        assert._fail "$desc" "error-patterns.conf not found"
        return
    fi

    # Find lines matching error patterns. Pattern files have comments and
    # blank lines that grep -f would otherwise treat as wildcards; strip
    # them via process substitution before feeding grep.
    local matches
    matches=$(echo "$log_text" \
        | grep -E -f <(assert._strip_pattern_comments "$patterns_file") \
            2>/dev/null || true)

    # Filter out known false positives
    if [[ -n "$matches" && -f "$ignore_file" ]]; then
        matches=$(echo "$matches" \
            | grep -v -E -f <(assert._strip_pattern_comments "$ignore_file") \
                2>/dev/null || true)
    fi

    # Add false-positive matches that bypass the ignore filter. These are
    # patterns the project decided to surface unconditionally (e.g. CI cache
    # warnings that indicate a runner-config bug).
    if [[ -f "$fp_file" ]]; then
        local fp_matches
        fp_matches=$(echo "$log_text" \
            | grep -E -f <(assert._strip_pattern_comments "$fp_file") \
                2>/dev/null || true)
        if [[ -n "$fp_matches" ]]; then
            if [[ -n "$matches" ]]; then
                matches="${matches}"$'\n'"${fp_matches}"
            else
                matches="$fp_matches"
            fi
        fi
    fi

    if [[ -z "$matches" ]]; then
        assert._pass "$desc"
    else
        local count
        count=$(echo "$matches" | wc -l | tr -d ' ')
        assert._fail "$desc" "${count} error(s) found"
        # Show first 5 matching lines for debugging
        echo "$matches" | head -5 | while IFS= read -r line; do
            echo -e "    ${YELLOW}|${NC} $line"
        done
    fi
}

# assert.job_log_contains <job_log_text> <pattern>
assert.job_log_contains() {
    local log_text="$1" pattern="$2"
    if echo "$log_text" | grep -qE "$pattern" 2>/dev/null; then
        assert._pass "Log contains '${pattern}'"
    else
        assert._fail "Log contains '${pattern}'" "pattern not found in log"
    fi
}

# assert.job_log_not_contains <job_log_text> <pattern>
assert.job_log_not_contains() {
    local log_text="$1" pattern="$2"
    if echo "$log_text" | grep -qE "$pattern" 2>/dev/null; then
        assert._fail "Log does not contain '${pattern}'" "pattern found in log"
    else
        assert._pass "Log does not contain '${pattern}'"
    fi
}

# ---------------------------------------------------------------------------
# Jenkins build-level assertions (thin aliases over the job-log helpers)
# ---------------------------------------------------------------------------

# assert.build_logs_clean <console_log_text>
assert.build_logs_clean() {
    local log_text="$1"
    local desc="${2:-Build logs clean}"
    assert.job_logs_clean "$log_text" "$desc"
}

# assert.build_log_contains <console_log_text> <pattern>
assert.build_log_contains() {
    assert.job_log_contains "$@"
}
