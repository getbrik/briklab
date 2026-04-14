#!/usr/bin/env bash
# GitLab Runner registration with Docker executor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
reload_env

GITLAB_INTERNAL_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}"
RUNNER_TOKEN="${GITLAB_RUNNER_TOKEN:-}"
HELPER_IMAGE="${GITLAB_RUNNER_HELPER_IMAGE:-gitlab/gitlab-runner-helper:alpine3.21-arm-bleeding}"
RUNNER_CONCURRENT="${GITLAB_RUNNER_CONCURRENT:-4}"
RUNNER_REQUEST_CONCURRENCY="${GITLAB_RUNNER_REQUEST_CONCURRENCY:-${RUNNER_CONCURRENT}}"
RUNNER_JOB_MEMORY="${GITLAB_RUNNER_JOB_MEMORY:-512m}"
DEFAULT_IMAGE="alpine:3.21"

if [[ -z "$RUNNER_TOKEN" ]]; then
    log_error "GITLAB_RUNNER_TOKEN not set"
    log_info "Run first: ./scripts/briklab.sh setup"
    exit 1
fi

# Check if the runner is already registered
if docker exec brik-runner cat /etc/gitlab-runner/config.toml 2>/dev/null | grep -q "url"; then
    log_warn "Runner already registered - nothing to do"
    exit 0
fi

log_info "Registering Docker executor runner..."

docker exec brik-runner gitlab-runner register \
    --non-interactive \
    --url "${GITLAB_INTERNAL_URL}" \
    --registration-token "${RUNNER_TOKEN}" \
    --executor docker \
    --docker-image "${DEFAULT_IMAGE}" \
    --docker-privileged=false \
    --docker-network-mode "brik-net" \
    --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
    --docker-volumes "${BRIKLAB_DIR}/data/k3d/kubeconfig:/root/.kube/config:ro" \
    --docker-extra-hosts "${GITLAB_HOSTNAME:-gitlab.briklab.test}:172.20.0.10" \
    --docker-extra-hosts "${NEXUS_HOSTNAME:-nexus.briklab.test}:172.20.0.30" \
    --docker-extra-hosts "ssh-target.briklab.test:172.20.0.41" \
    --docker-extra-hosts "${GITEA_HOSTNAME:-gitea.briklab.test}:172.20.0.20" \
    --docker-extra-hosts "registry.briklab.test:172.20.0.12" \
    --description "brik-docker-runner" \
    --tag-list "docker,brik" \
    --run-untagged=true \
    --locked=false

# Set concurrent jobs (gitlab-runner register always defaults to 1)
log_info "Setting concurrent = ${RUNNER_CONCURRENT}..."
docker exec brik-runner sed -i \
    "s/^concurrent = .*/concurrent = ${RUNNER_CONCURRENT}/" \
    /etc/gitlab-runner/config.toml

# Set request_concurrency (how many jobs the runner requests in parallel)
log_info "Setting request_concurrency = ${RUNNER_REQUEST_CONCURRENCY}..."
docker exec brik-runner sed -i \
    "/executor = \"docker\"/a\\  request_concurrency = ${RUNNER_REQUEST_CONCURRENCY}" \
    /etc/gitlab-runner/config.toml

# Add helper_image (bleeding edge image requires an explicit helper)
log_info "Configuring helper_image..."
docker exec brik-runner sed -i \
    "/image = \"${DEFAULT_IMAGE}\"/a\\    helper_image = \"${HELPER_IMAGE}\"" \
    /etc/gitlab-runner/config.toml

# Set per-job memory limit to prevent OOM with concurrent execution
log_info "Setting job memory limit = ${RUNNER_JOB_MEMORY}..."
docker exec brik-runner sed -i \
    "/shm_size = 0/a\\    memory = \"${RUNNER_JOB_MEMORY}\"" \
    /etc/gitlab-runner/config.toml

# Allow flexible pull policies for job containers (needed for local/cached images)
log_info "Setting allowed pull policies..."
if ! docker exec brik-runner grep -q "allowed_pull_policies" /etc/gitlab-runner/config.toml 2>/dev/null; then
    docker exec brik-runner sed -i \
        "/\[runners.docker\]/a\\    allowed_pull_policies = [\"always\", \"if-not-present\"]" \
        /etc/gitlab-runner/config.toml 2>/dev/null || true
fi

# Verification
errors=0
if ! docker exec brik-runner grep -q "helper_image" /etc/gitlab-runner/config.toml; then
    log_warn "helper_image not added - jobs may fail"
    errors=$((errors + 1))
fi
if ! docker exec brik-runner grep -q "concurrent = ${RUNNER_CONCURRENT}" /etc/gitlab-runner/config.toml; then
    log_warn "concurrent not set to ${RUNNER_CONCURRENT}"
    errors=$((errors + 1))
fi
if ! docker exec brik-runner grep -q "request_concurrency = ${RUNNER_REQUEST_CONCURRENCY}" /etc/gitlab-runner/config.toml; then
    log_warn "request_concurrency not set to ${RUNNER_REQUEST_CONCURRENCY}"
    errors=$((errors + 1))
fi
if ! docker exec brik-runner grep -q "memory = \"${RUNNER_JOB_MEMORY}\"" /etc/gitlab-runner/config.toml; then
    log_warn "job memory limit not set to ${RUNNER_JOB_MEMORY}"
    errors=$((errors + 1))
fi

if [[ $errors -eq 0 ]]; then
    log_ok "Runner registered successfully"
else
    log_warn "Runner registered with ${errors} warning(s)"
fi

echo ""
echo -e "${BLUE}Runner configuration:${NC}"
echo "  Executor       : docker"
echo "  Image          : ${DEFAULT_IMAGE}"
echo "  Helper         : ${HELPER_IMAGE}"
echo "  Concurrent     : ${RUNNER_CONCURRENT}"
echo "  Req. concurr.  : ${RUNNER_REQUEST_CONCURRENCY}"
echo "  Job memory     : ${RUNNER_JOB_MEMORY}"
echo "  Tags           : docker, brik"
echo "  Network        : brik-net"
