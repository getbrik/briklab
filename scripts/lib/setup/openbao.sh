#!/usr/bin/env bash
# OpenBAO configuration for the cosign KMS signing scenarios.
#
# The lab server runs in dev mode (in-memory storage): everything here is
# idempotent and re-applied at each setup so a container restart - which
# wipes the Transit keys - self-heals on the next 'briklab.sh setup' or
# 'preflight --fix'.
#
# What it does:
#   1. enables the Transit secrets engine at the non-default mount
#      'brik-transit' (matches the SecretManager endpoint's transit_mount
#      in the infra-kms referential instance),
#   2. creates the 'brik-signing' ecdsa-p256 key cosign addresses as
#      openbao://brik-signing,
#   3. exports the PEM public key into the infra-kms instance trust/
#      directory for consumers that verify without OpenBAO access.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/../../.."

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

# The host talks to the published port; job containers reach the same
# server as http://openbao.briklab.test:8200 (runner/jenkins extra_hosts).
OPENBAO_URL="http://127.0.0.1:${OPENBAO_HTTP_PORT:-8200}"
OPENBAO_TOKEN="${OPENBAO_ROOT_TOKEN:-brik-bao-root-2026}"
TRANSIT_MOUNT="brik-transit"
SIGNING_KEY="brik-signing"
INFRA_KMS_TRUST_DIR="${ROOT_DIR}/data/infra-kms/trust"

# bao - run the bao CLI inside the container against the local server.
bao() {
    docker exec \
        -e BAO_ADDR="http://127.0.0.1:8200" \
        -e BAO_TOKEN="${OPENBAO_TOKEN}" \
        brik-openbao bao "$@"
}

wait_for_openbao() {
    log_info "Waiting for OpenBAO..."
    if briklab.wait.until 60 2 curl -sf -o /dev/null "${OPENBAO_URL}/v1/sys/health"; then
        log_ok "OpenBAO is ready"
    else
        log_error "OpenBAO is not ready after 60s"
        exit 1
    fi
}

enable_transit() {
    if bao secrets list | grep -q "^${TRANSIT_MOUNT}/"; then
        log_info "Transit engine already enabled at ${TRANSIT_MOUNT}/"
    else
        log_info "Enabling the Transit engine at ${TRANSIT_MOUNT}/..."
        bao secrets enable -path="${TRANSIT_MOUNT}" transit >/dev/null
        log_ok "Transit engine enabled"
    fi
}

# Transit key creation is create-or-noop: re-running against an existing
# key leaves it untouched, so the exported public key stays stable for as
# long as the dev-mode server lives.
create_signing_key() {
    log_info "Ensuring the ${SIGNING_KEY} ecdsa-p256 key..."
    bao write -f "${TRANSIT_MOUNT}/keys/${SIGNING_KEY}" type=ecdsa-p256 >/dev/null
    log_ok "Signing key present"
}

export_public_key() {
    log_info "Exporting the signing public key to the infra-kms instance..."
    mkdir -p "${INFRA_KMS_TRUST_DIR}"
    bao read -format=json "${TRANSIT_MOUNT}/keys/${SIGNING_KEY}" \
        | jq -r '.data.keys[.data.latest_version | tostring].public_key' \
        > "${INFRA_KMS_TRUST_DIR}/cosign-kms.pub"
    if grep -q "BEGIN PUBLIC KEY" "${INFRA_KMS_TRUST_DIR}/cosign-kms.pub"; then
        log_ok "Public key exported to data/infra-kms/trust/cosign-kms.pub"
    else
        log_error "Public key export failed (unexpected Transit response)"
        exit 1
    fi
}

main() {
    log_info "=== OpenBAO setup ==="
    wait_for_openbao
    enable_transit
    create_signing_key
    export_public_key
    log_ok "OpenBAO setup complete"
}

main "$@"
