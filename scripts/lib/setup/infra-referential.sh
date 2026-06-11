#!/usr/bin/env bash
# Generate the P-lab infrastructure referential instance consumed by brik.
#
# Brik requires a referential (BRIK_INFRA_DIR) at init: endpoints declare
# WHERE the lab services live and with which transport posture, credentials
# reference secrets by env:// or file://, bindings wire one to the other per
# environment. This replaces the former ad-hoc BRIK_* infrastructure
# variables (BRIK_COSIGN_*, BRIK_SSH_STRICT_HOST_KEY, BRIK_KUBECTL_OPTS,
# BRIK_POLICY_URL, ARGOCD_SERVER/ARGOCD_INSECURE).
#
# The instance is distributed to CI jobs as a read-only mount at
# /etc/brik/infra: the GitLab runner declares it in its docker volumes,
# Jenkins forwards its own compose mount to stage containers.
#
# Key material under trust/ is generated once and reused across runs so the
# principals pinned in allowed_signers and the cosign public key stay stable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/../../.."
INFRA_DIR="${ROOT_DIR}/data/infra"
COSIGN_DIR="${ROOT_DIR}/data/cosign"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

NEXUS_HOST="${NEXUS_HOSTNAME:-nexus.briklab.test}"
GITEA_HOST="${GITEA_HOSTNAME:-gitea.briklab.test}"
GITEA_PORT="${GITEA_HTTP_PORT:-3000}"
ARGOCD_HOSTPORT="host.docker.internal:${ARGOCD_PORT:-9080}"

mkdir -p "${INFRA_DIR}/endpoints" "${INFRA_DIR}/credentials" \
         "${INFRA_DIR}/bindings" "${INFRA_DIR}/policies" "${INFRA_DIR}/trust"

# --- trust material (generated once, reused) -------------------------------

# Evidence commit signing: brik signs BuildEvidence commits with this ssh key
# (credential 'evidence-signing') and verifies them against allowed_signers.
# The principal is the brik-ci robot identity state_repo.commit uses.
if [[ ! -f "${INFRA_DIR}/trust/evidence_signing_key" ]]; then
    log_info "Generating the evidence-signing ssh key pair..."
    ssh-keygen -t ed25519 -N "" -q -C "brik-ci@noreply" \
        -f "${INFRA_DIR}/trust/evidence_signing_key"
fi
# Principals are verified in the 'git' namespace (commits AND tags); a
# 'git-commit' namespace entry fails with "key is not permitted".
printf 'brik-ci@noreply namespaces="git" %s\n' \
    "$(cat "${INFRA_DIR}/trust/evidence_signing_key.pub")" \
    > "${INFRA_DIR}/trust/allowed_signers"

# Cosign key pair: shared with the CI variables setup (the private key is
# published as a secret variable, never written into the referential).
if [[ ! -f "${COSIGN_DIR}/cosign.key" || ! -f "${COSIGN_DIR}/cosign.pub" ]]; then
    if command -v cosign >/dev/null 2>&1; then
        log_info "Generating the cosign key pair (empty password, local lab)..."
        mkdir -p "${COSIGN_DIR}"
        ( cd "${COSIGN_DIR}" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1 ) \
            || log_warn "cosign key generation failed - signing scenarios will not sign"
    else
        log_warn "cosign not on PATH - signing scenarios will not sign"
    fi
fi
if [[ -f "${COSIGN_DIR}/cosign.pub" ]]; then
    cp "${COSIGN_DIR}/cosign.pub" "${INFRA_DIR}/trust/cosign.pub"
fi
# The signing key travels as referential trust material (P-lab posture:
# file keys, empty passphrase). Both orchestrators and the local mode read
# the same mounted file; only COSIGN_PASSWORD travels as a variable.
if [[ -f "${COSIGN_DIR}/cosign.key" ]]; then
    cp "${COSIGN_DIR}/cosign.key" "${INFRA_DIR}/trust/cosign.key"
    chmod 600 "${INFRA_DIR}/trust/cosign.key"
fi

# --- root manifest ---------------------------------------------------------

cat > "${INFRA_DIR}/referential.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Referential
profile: p-lab
description: Briklab posture - plain-HTTP services, self-signed TLS and file/env keys. Legal but noisy; never a production reference.
YAML

# --- endpoints --------------------------------------------------------------

# The lab Nexus serves one Docker hosted registry over plain HTTP; candidate
# and release channels share it. The declared http:// scheme is what lets
# digest resolution and cosign reach it (no insecure escape-hatch variable).
cat > "${INFRA_DIR}/endpoints/registry-candidate.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: Registry
name: registry-candidate
url: http://${NEXUS_HOST}:8082
tls:
  trust: insecure
zone: candidate
YAML

cat > "${INFRA_DIR}/endpoints/git-host.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: GitHost
name: git-host
product: gitea
api_url: http://${GITEA_HOST}:${GITEA_PORT}
git_url: http://${GITEA_HOST}:${GITEA_PORT}
tls:
  trust: insecure
YAML

# Air-gapped lab: no Fulcio/Rekor, attestation uses a local key pair shipped
# as trust material of the mounted instance (P-lab posture); COSIGN_PASSWORD
# decrypts it. Verification only needs the public key.
cat > "${INFRA_DIR}/endpoints/signing.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Signing
name: signing
backend: key
key: file://trust/cosign.key
verification_key: file://trust/cosign.pub
transparency: none
YAML

# ArgoCD is reached from job containers through the host port-forward; the
# certificate is self-signed, hence trust: insecure (maps to --insecure).
cat > "${INFRA_DIR}/endpoints/argocd.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: ArgoCD
name: argocd
url: https://${ARGOCD_HOSTPORT}
tls:
  trust: insecure
YAML

# SSH deploy target: lab containers are rebuilt at will, so host keys are
# not pinned. The explicit opt-out replaces BRIK_SSH_STRICT_HOST_KEY=no.
cat > "${INFRA_DIR}/endpoints/ssh-target.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: SshTarget
name: ssh-target
hosts:
  - ssh-target.briklab.test
strict_host_key: false
YAML

# --- credentials ------------------------------------------------------------

cat > "${INFRA_DIR}/credentials/registry-push.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Credential
name: registry-push
method: basic
username: env://BRIK_REGISTRY_USER
password: env://BRIK_REGISTRY_PASSWORD
YAML

cat > "${INFRA_DIR}/credentials/git-api.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Credential
name: git-api
method: token
token: env://BRIK_GIT_TOKEN
YAML

cat > "${INFRA_DIR}/credentials/evidence-signing.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Credential
name: evidence-signing
method: ssh-key
private_key: file://trust/evidence_signing_key
YAML

# --- bindings ---------------------------------------------------------------

# One binding per deploy environment name the test projects use. The
# branch-protection check resolves the GitHost credential through the
# binding of the environment being deployed.
write_binding() {
    cat > "${INFRA_DIR}/bindings/$1.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: Binding
name: $1
endpoints:
  registry-candidate: registry-push
  git-host: git-api
capabilities:
  artifact-attestation: cosign-key
  evidence-commit-signing: ssh-signing
YAML
}
write_binding staging
write_binding production

# --- policies ----------------------------------------------------------------

# DSI-owned org policy: jobs resolve the file through the compose mount.
# Replaces the BRIK_POLICY_URL variable.
cat > "${INFRA_DIR}/policies/org.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Policy
name: org
url: file:///etc/brik/policy/brik-policy.yml
YAML

log_ok "P-lab referential generated in ${INFRA_DIR}"

# --- KMS variant (data/infra-kms) -------------------------------------------

# Same lab posture, but artifact signing goes through OpenBAO Transit
# (Signing backend kms + SecretManager endpoint) instead of a file key.
# The signed-KMS scenarios select this instance with a project-level
# BRIK_INFRA_DIR=/etc/brik/infra-kms; everything else (registry, git host,
# evidence ssh signing, policy) is identical to the main instance.
#
# trust/cosign-kms.pub is exported by setup/openbao.sh AFTER this script
# runs (setup order), so this generation must never delete the directory.
INFRA_KMS_DIR="${ROOT_DIR}/data/infra-kms"
mkdir -p "${INFRA_KMS_DIR}/endpoints" "${INFRA_KMS_DIR}/credentials" \
         "${INFRA_KMS_DIR}/bindings" "${INFRA_KMS_DIR}/policies" \
         "${INFRA_KMS_DIR}/trust"

# Shared documents: every endpoint, credential and policy except Signing.
cp "${INFRA_DIR}/endpoints/registry-candidate.yml" \
   "${INFRA_DIR}/endpoints/git-host.yml" \
   "${INFRA_DIR}/endpoints/argocd.yml" \
   "${INFRA_DIR}/endpoints/ssh-target.yml" \
   "${INFRA_KMS_DIR}/endpoints/"
cp "${INFRA_DIR}/credentials/"*.yml "${INFRA_KMS_DIR}/credentials/"
cp "${INFRA_DIR}/policies/org.yml" "${INFRA_KMS_DIR}/policies/"

# Same evidence-signing key pair: state-repo commits verify against the
# same allowed_signers regardless of the artifact-signing backend.
cp "${INFRA_DIR}/trust/evidence_signing_key" \
   "${INFRA_DIR}/trust/evidence_signing_key.pub" \
   "${INFRA_DIR}/trust/allowed_signers" \
   "${INFRA_KMS_DIR}/trust/"
chmod 600 "${INFRA_KMS_DIR}/trust/evidence_signing_key"

cat > "${INFRA_KMS_DIR}/referential.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Referential
profile: p-lab
description: Briklab KMS posture - identical to the main instance except artifact signing, which uses an OpenBAO Transit key through cosign openbao://.
YAML

# The key never leaves OpenBAO; cosign signs through the Transit API. The
# exported public key is for consumers that verify without OpenBAO access.
cat > "${INFRA_KMS_DIR}/endpoints/signing.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Signing
name: signing
backend: kms
kms_uri: openbao://brik-signing
transparency: none
YAML

# Connection material for the cosign KMS driver: BAO_ADDR from url,
# BAO_TOKEN resolved from the job environment, TRANSIT_SECRET_ENGINE_PATH
# from transit_mount. P-lab posture: the dev root token is the credential.
cat > "${INFRA_KMS_DIR}/endpoints/secret-manager.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: SecretManager
name: secret-manager
url: http://${OPENBAO_HOSTNAME:-openbao.briklab.test}:8200
transit_mount: brik-transit
auth:
  method: token
  ref: env://BRIK_BAO_TOKEN
tls:
  trust: insecure
YAML

write_kms_binding() {
    cat > "${INFRA_KMS_DIR}/bindings/$1.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: Binding
name: $1
endpoints:
  registry-candidate: registry-push
  git-host: git-api
capabilities:
  artifact-attestation: cosign-kms-openbao
  evidence-commit-signing: ssh-signing
YAML
}
write_kms_binding staging
write_kms_binding production

log_ok "P-lab KMS referential generated in ${INFRA_KMS_DIR}"
