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

CA_DIR="${ROOT_DIR}/data/ca"

mkdir -p "${INFRA_DIR}/endpoints" "${INFRA_DIR}/credentials" \
         "${INFRA_DIR}/bindings" "${INFRA_DIR}/policies" "${INFRA_DIR}/trust"

# --- lab CA bundle deposits --------------------------------------------------

# Endpoints declared with tls.trust: custom-ca resolve their bundle by the
# trust/ca/<hostname>/ca.crt convention; every TLS service of the lab is
# issued by the single internal CA minted by setup/ca.sh.
if [[ ! -f "${CA_DIR}/ca.crt" ]]; then
    bash "${SCRIPT_DIR}/ca.sh"
fi

# deposit_ca <hostname> - install the lab CA as the trust bundle of one host.
deposit_ca() {
    mkdir -p "${INFRA_DIR}/trust/ca/$1"
    cp "${CA_DIR}/ca.crt" "${INFRA_DIR}/trust/ca/$1/ca.crt"
}
# ArgoCD is reached at host.docker.internal from job containers and via the
# localhost port-forward from the host; the certificate covers both names.
deposit_ca "host.docker.internal"

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

# The lab Nexus serves one Docker hosted registry over TLS issued by the
# lab CA; candidate and release channels share it. Digest resolution, oras
# and cosign all verify the chain against the deposited bundle.
deposit_ca "${NEXUS_HOST}"
cat > "${INFRA_DIR}/endpoints/registry-candidate.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: Registry
name: registry-candidate
url: https://${NEXUS_HOST}:8082
tls:
  trust: custom-ca
zone: candidate
YAML

# Gitea serves TLS issued by the lab CA; brik verifies API calls and git
# operations against the deposited bundle (GIT_SSL_CAINFO / curl --cacert).
deposit_ca "${GITEA_HOST}"
cat > "${INFRA_DIR}/endpoints/git-host.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: GitHost
name: git-host
product: gitea
api_url: https://${GITEA_HOST}:${GITEA_PORT}
git_url: https://${GITEA_HOST}:${GITEA_PORT}
tls:
  trust: custom-ca
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

# ArgoCD is reached from job containers through the host port-forward; its
# certificate is issued by the lab CA (setup/ca.sh installs it as the
# argocd-server-tls secret), so verification pins the deposited bundle.
cat > "${INFRA_DIR}/endpoints/argocd.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: ArgoCD
name: argocd
url: https://${ARGOCD_HOSTPORT}
tls:
  trust: custom-ca
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

# Package registry (npm, the format the lab publishes): the publisher takes
# the destination, transport posture (declared plain http: legal but noisy)
# and credential from here instead of the BRIK_PUBLISH_NPM_* variables. The
# Nexus UI port (8081) stayed plain http at lab tier 2; only the docker
# connector (8082) moved to TLS.
cat > "${INFRA_DIR}/endpoints/pkg-npm.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: PackageRegistry
name: pkg-npm
format: npm
url: http://${NEXUS_HOST}:8081/repository/brik-npm/
credential: npm-publish
tls:
  trust: system
YAML

# --- credentials ------------------------------------------------------------

# The env bindings are CD-scope, and the CD registry identity is READ-ONLY
# (the lab's brik-cd Nexus account, delivered as environment-scoped values of
# BRIK_REGISTRY_*): digest resolution, attestation verification and pull need
# no write. The CI write identity (publish, attest attach, promote copy) is
# the same var names delivered with the admin account by the group-level CI
# variables -- distinct accounts, one revocation never strands the other.
cat > "${INFRA_DIR}/credentials/registry-read.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Credential
name: registry-read
method: basic
username: env://BRIK_REGISTRY_USER
password: env://BRIK_REGISTRY_PASSWORD
YAML

cat > "${INFRA_DIR}/credentials/npm-publish.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Credential
name: npm-publish
method: token
token: env://BRIK_PUBLISH_NPM_TOKEN
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

# The CI orchestrators inject ARGOCD_AUTH_TOKEN as a pipeline variable;
# declaring it here lets the local containerized runner forward it into the
# deploy container by name (env:// refs are the forwarding contract).
cat > "${INFRA_DIR}/credentials/argocd.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Credential
name: argocd
method: token
token: env://ARGOCD_AUTH_TOKEN
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
  registry-candidate: registry-read
  git-host: git-api
capabilities:
  artifact-attestation: cosign-key
  evidence-commit-signing: ssh-signing
YAML
}
write_binding staging
write_binding production
write_binding dev

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
   "${INFRA_DIR}/endpoints/pkg-npm.yml" \
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

# Same custom-ca trust bundles: the endpoints are shared documents, so the
# bundles their tls.trust declarations resolve to must travel with them.
rm -rf "${INFRA_KMS_DIR}/trust/ca"
cp -R "${INFRA_DIR}/trust/ca" "${INFRA_KMS_DIR}/trust/ca"

cat > "${INFRA_KMS_DIR}/referential.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Referential
profile: p-lab
description: Briklab KMS posture - identical to the main instance except artifact signing, which uses an OpenBAO Transit key through cosign openbao://.
YAML

# The key never leaves OpenBAO; cosign signs through the Transit API. The
# exported public key (verification_key) lets every verifying consumer --
# the CD deploy first -- check signatures WITHOUT OpenBAO access, so the
# KMS token stays confined to the signing phase (SLSA L2 credential leg).
cat > "${INFRA_KMS_DIR}/endpoints/signing.yml" <<'YAML'
apiVersion: brik.dev/referential/v1
kind: Signing
name: signing
backend: kms
kms_uri: openbao://brik-signing
verification_key: file://trust/cosign-kms.pub
transparency: none
YAML

# Connection material for the cosign KMS driver: BAO_ADDR from url,
# BAO_TOKEN resolved from the job environment, TRANSIT_SECRET_ENGINE_PATH
# from transit_mount. P-lab posture: the dev root token is the credential.
# The BRIK_SIGNING_ prefix is the reserved signing-phase scope: the GitLab
# template delivers it via the brik/signing environment and the Jenkins
# shared-lib injects it only into the container-scan container.
cat > "${INFRA_KMS_DIR}/endpoints/secret-manager.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: SecretManager
name: secret-manager
url: http://${OPENBAO_HOSTNAME:-openbao.briklab.test}:8200
transit_mount: brik-transit
auth:
  method: token
  ref: env://BRIK_SIGNING_BAO_TOKEN
tls:
  trust: insecure
YAML

write_kms_binding() {
    cat > "${INFRA_KMS_DIR}/bindings/$1.yml" <<YAML
apiVersion: brik.dev/referential/v1
kind: Binding
name: $1
endpoints:
  registry-candidate: registry-read
  git-host: git-api
capabilities:
  artifact-attestation: cosign-kms-openbao
  evidence-commit-signing: ssh-signing
YAML
}
write_kms_binding staging
write_kms_binding production

log_ok "P-lab KMS referential generated in ${INFRA_KMS_DIR}"
