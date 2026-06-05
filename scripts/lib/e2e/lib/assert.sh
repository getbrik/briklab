#!/usr/bin/env bash
# E2E Assertion Library -- facade.
#
# Sources the assertion engine (assert/core.sh) and the Brik report / infra
# assertions (assert/report.sh). E2E scripts keep sourcing this single file:
#   source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
#   assert.init
#   assert.equals "check version" "1.0" "$version"
#   assert.report  # prints summary, returns 1 if any failures
#
# The split keeps each unit focused: core.sh is a domain-agnostic assertion
# toolkit, report.sh adds the Brik aggregate-report and deploy-state surface.

[[ -n "${_E2E_ASSERT_LOADED:-}" ]] && return 0
_E2E_ASSERT_LOADED=1

_E2E_ASSERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert/core.sh
source "${_E2E_ASSERT_DIR}/assert/core.sh"
# shellcheck source=assert/report.sh
source "${_E2E_ASSERT_DIR}/assert/report.sh"
