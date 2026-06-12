#!/usr/bin/env bash
# Mint the briklab internal CA and the per-service leaf certificates.
#
# The lab services (ArgoCD, Gitea, Nexus docker registry) serve TLS with
# certificates issued by this CA so the brik referential can declare
# tls.trust: custom-ca and exercise the real verification path (no
# insecure escape hatch). The CA certificate is the bundle the referential
# deposits under trust/ca/<hostname>/ca.crt.
#
# Key material is generated once and reused across runs: the CA must stay
# stable so the trust bundles distributed to consumers (referential
# instances, Jenkins truststore, k3d containerd, docker daemon) do not
# churn. Leaf certificates are re-issued only when absent, expiring, no
# longer signed by the current CA, or when their SAN set changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/../../.."
CA_DIR="${ROOT_DIR}/data/ca"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

GITEA_HOST="${GITEA_HOSTNAME:-gitea.briklab.test}"
NEXUS_HOST="${NEXUS_HOSTNAME:-nexus.briklab.test}"

mkdir -p "${CA_DIR}"

# --- root CA (generated once, never rotated by this script) -----------------

if [[ ! -f "${CA_DIR}/ca.key" || ! -f "${CA_DIR}/ca.crt" ]]; then
    log_info "Generating the briklab internal CA..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -keyout "${CA_DIR}/ca.key" -out "${CA_DIR}/ca.crt" \
        -days 3650 -subj "/CN=Briklab Internal CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    chmod 600 "${CA_DIR}/ca.key"
    log_ok "CA created at data/ca/ca.crt"
fi

# --- leaf certificates -------------------------------------------------------

# _issue_leaf <service> <san-csv>
# Issues data/ca/<service>/tls.{key,crt} with the given SANs (DNS: / IP:
# prefixed, comma-separated). Skips when the existing cert is signed by the
# current CA, valid for 30+ days and carries the same SAN set.
_issue_leaf() {
    local service="$1" sans="$2"
    local dir="${CA_DIR}/${service}"
    local cn="${sans#DNS:}"
    cn="${cn%%,*}"

    if [[ -f "${dir}/tls.crt" && -f "${dir}/tls.key" ]] \
        && openssl verify -CAfile "${CA_DIR}/ca.crt" "${dir}/tls.crt" >/dev/null 2>&1 \
        && openssl x509 -checkend 2592000 -noout -in "${dir}/tls.crt" >/dev/null 2>&1 \
        && [[ "$(cat "${dir}/san" 2>/dev/null)" == "$sans" ]]; then
        log_info "${service}: certificate up to date (CN=${cn})"
        return 0
    fi

    log_info "Issuing the ${service} certificate (SAN ${sans})..."
    mkdir -p "$dir"
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -keyout "${dir}/tls.key" -out "${dir}/tls.csr" \
        -subj "/CN=${cn}" >/dev/null 2>&1
    openssl x509 -req -in "${dir}/tls.csr" \
        -CA "${CA_DIR}/ca.crt" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
        -out "${dir}/tls.crt" -days 825 \
        -extfile <(printf 'subjectAltName=%s\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$sans") \
        >/dev/null 2>&1
    rm -f "${dir}/tls.csr"
    chmod 600 "${dir}/tls.key"
    printf '%s' "$sans" > "${dir}/san"
    log_ok "${service}: certificate issued"
}

# ArgoCD is reached through the host port-forward: job containers use
# host.docker.internal, host-side tooling uses localhost.
_issue_leaf argocd "DNS:host.docker.internal,DNS:localhost,DNS:argocd.briklab.test,IP:127.0.0.1"

# Gitea is reached by its public hostname (jobs, host) and by its compose
# service name (ArgoCD repo-server and webhooks resolve brik-gitea on
# brik-net via the container DNS).
_issue_leaf gitea "DNS:${GITEA_HOST},DNS:brik-gitea,DNS:localhost,IP:127.0.0.1,IP:172.20.0.20"

# The Nexus docker connector is reached by its public hostname (jobs, host
# docker daemon) and by its compose service name (k3d containerd mirror
# endpoint).
_issue_leaf nexus "DNS:${NEXUS_HOST},DNS:brik-nexus,DNS:localhost,IP:127.0.0.1,IP:172.20.0.30"

log_ok "Lab CA material ready in data/ca/"
