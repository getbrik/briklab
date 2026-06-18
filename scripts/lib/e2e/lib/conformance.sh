#!/usr/bin/env bash
# E2E artifact-attestation/v1 behavioural conformance (D12 stage 3).
#
# Maps the capability contract's behavioural obligations onto the live
# node-deploy-signed evidence: brik signs the published digest in CI and
# verifies it in CD with the referential verification key. These are exactly
# the obligations the unit harness (`brik provider test`, stage 2) defers to
# real infrastructure:
#
#   C2 fail-closed verify  -- a digest with no/tampered attestation is refused.
#   C3 sign/verify round-trip -- CD verifies what CI signed, then deploys.
#   C5 key confinement     -- CD verifies with the verification key alone; the
#                             private signing key never enters the CD runtime.
#   C7 no-secret-argv      -- registry creds travel through DOCKER_CONFIG and
#                             the signing key as a path/uri; no secret in argv.
#
# Each helper takes already-captured job-trace text and logs a C-code-labelled
# verdict (returns 0 on conformance, 1 on violation). Mirrors the scenario
# idiom (log_ok / log_error from common.sh). The contract spec proves the same
# obligations in miniature; this proves them end to end on real cosign + Nexus.

[[ -n "${_E2E_CONFORMANCE_LOADED:-}" ]] && return 0
_E2E_CONFORMANCE_LOADED=1

# C3 -- the CD deploy verified the attestation CI attached to the same digest
# and reported success ("attestation verified for <digest>", deploy.sh).
e2e.conformance.attestation_v1.roundtrip() {
    local deploy_trace="$1"
    if grep -q "did not verify" <<<"$deploy_trace"; then
        log_error "C3 round-trip: CD trace shows a verification failure"
        return 1
    fi
    if ! grep -q "attestation verified for " <<<"$deploy_trace"; then
        log_error "C3 round-trip: CD trace lacks the 'attestation verified' marker"
        return 1
    fi
    log_ok "C3 round-trip: CD verified the CI-signed attestation on the deployed digest"
}

# C2 -- a digest with no (or tampered) attestation is refused, fail-closed.
e2e.conformance.attestation_v1.fail_closed() {
    local refusal_trace="$1"
    if ! grep -q "did not verify" <<<"$refusal_trace"; then
        log_error "C2 fail-closed: the unattested-digest refusal trace lacks 'did not verify'"
        return 1
    fi
    log_ok "C2 fail-closed: an unattested digest was refused at the attestation gate"
}

# C5 -- CD verifies with the verification key only; no private key in the trace.
e2e.conformance.attestation_v1.key_confinement() {
    local deploy_trace="$1"
    if ! grep -q "attestation verified for " <<<"$deploy_trace"; then
        log_error "C5 confinement: CD did not complete a verification to confine"
        return 1
    fi
    if grep -qE -- "-----BEGIN [A-Z ]*PRIVATE KEY-----" <<<"$deploy_trace"; then
        log_error "C5 confinement: private key material appears in the CD verify trace"
        return 1
    fi
    if grep -qE "env://COSIGN_PRIVATE_KEY|COSIGN_PRIVATE_KEY=" <<<"$deploy_trace"; then
        log_error "C5 confinement: the CD verify trace references the private signing key"
        return 1
    fi
    log_ok "C5 confinement: CD verified with the verification key alone (no private key in the runtime)"
}

# C7 -- no secret material in the cosign argv across the sign + verify traces.
# Args: ci_sign_trace cd_verify_trace [extra_secret_literal...]
e2e.conformance.attestation_v1.no_secret_argv() {
    local ci_trace="$1" cd_trace="$2"; shift 2
    local combined="${ci_trace}
${cd_trace}"
    if grep -q -- "--registry-password" <<<"$combined"; then
        log_error "C7 no-secret-argv: a --registry-password flag is on the cosign argv"
        return 1
    fi
    if grep -qE -- "-----BEGIN [A-Z ]*PRIVATE KEY-----" <<<"$combined"; then
        log_error "C7 no-secret-argv: private key material leaked into a trace"
        return 1
    fi
    local secret
    for secret in "$@"; do
        [[ -z "$secret" ]] && continue
        if grep -qF -- "$secret" <<<"$combined"; then
            log_error "C7 no-secret-argv: a registry secret literal leaked into a trace"
            return 1
        fi
    done
    log_ok "C7 no-secret-argv: signing/verify creds travelled out of band (DOCKER_CONFIG), no secret in argv"
}

# Run the full artifact-attestation/v1 conformance battery on captured traces.
# Args: ci_sign_trace cd_deploy_trace cd_refusal_trace [secret_literal...]
e2e.conformance.attestation_v1.run() {
    local ci_trace="$1" deploy_trace="$2" refusal_trace="$3"; shift 3
    local rc=0
    echo ""
    log_info "--- artifact-attestation/v1 behavioural conformance (D12 stage 3) ---"
    e2e.conformance.attestation_v1.roundtrip       "$deploy_trace"  || rc=1
    e2e.conformance.attestation_v1.fail_closed     "$refusal_trace" || rc=1
    e2e.conformance.attestation_v1.key_confinement "$deploy_trace"  || rc=1
    e2e.conformance.attestation_v1.no_secret_argv  "$ci_trace" "$deploy_trace" "$@" || rc=1
    if [[ "$rc" -eq 0 ]]; then
        log_ok "=== artifact-attestation/v1 CONFORMANCE PROVEN (C2/C3/C5/C7) ==="
    else
        log_error "=== artifact-attestation/v1 CONFORMANCE FAILED ==="
    fi
    return "$rc"
}
