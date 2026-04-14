#!/usr/bin/env bash
# Initial Jenkins configuration
# Plugins and JCasC are applied automatically via volumes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

JENKINS_URL="http://${JENKINS_HOSTNAME:-jenkins.briklab.test}:${JENKINS_HTTP_PORT:-9090}"

# Wait for Jenkins to be ready
wait_for_jenkins() {
    log_info "Waiting for Jenkins..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf "${JENKINS_URL}/login" &>/dev/null; then
            log_ok "Jenkins is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 5
    done
    echo ""
    log_error "Jenkins is not ready after $((max_attempts * 5))s"
    exit 1
}

# Install plugins
install_plugins() {
    log_info "Installing Jenkins plugins..."

    # Plugins are installed via the mounted plugins.txt file
    # Run manual installation if needed
    docker exec brik-jenkins bash -c '
        if [ -f /usr/share/jenkins/ref/plugins.txt ]; then
            jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt 2>/dev/null || true
        fi
    ' 2>/dev/null || true

    log_ok "Plugins installed (Jenkins restart may be required)"
}

# === Main ===
wait_for_jenkins
install_plugins

log_ok "Jenkins configuration complete"
echo ""
echo -e "${BLUE}Jenkins access:${NC}"
echo "  URL      : ${JENKINS_URL}"
echo "  Login    : admin"
echo "  Password : ${JENKINS_ADMIN_PASSWORD:-changeme_jenkins_admin}"
