#!/usr/bin/env bash
# GitLab Runner registration with Docker executor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

GITLAB_INTERNAL_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.local}:${GITLAB_HTTP_PORT:-8929}"
RUNNER_TOKEN="${GITLAB_RUNNER_TOKEN:-}"
HELPER_IMAGE="${GITLAB_RUNNER_HELPER_IMAGE:-gitlab/gitlab-runner-helper:alpine3.21-arm-bleeding}"
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
    --docker-extra-hosts "${GITLAB_HOSTNAME:-gitlab.briklab.local}:172.20.0.10" \
    --description "brik-docker-runner" \
    --tag-list "docker,brik" \
    --run-untagged=true \
    --locked=false

# Add helper_image (bleeding edge image requires an explicit helper)
log_info "Configuring helper_image..."
docker exec brik-runner sed -i \
    "/image = \"${DEFAULT_IMAGE}\"/a\\    helper_image = \"${HELPER_IMAGE}\"" \
    /etc/gitlab-runner/config.toml

# Verification
if docker exec brik-runner grep -q "helper_image" /etc/gitlab-runner/config.toml; then
    log_ok "Runner registered successfully"
else
    log_warn "helper_image not added - jobs may fail"
fi

echo ""
echo -e "${BLUE}Runner configuration:${NC}"
echo "  Executor     : docker"
echo "  Image        : ${DEFAULT_IMAGE}"
echo "  Helper       : ${HELPER_IMAGE}"
echo "  Tags         : docker, brik"
echo "  Network      : brik-net"
