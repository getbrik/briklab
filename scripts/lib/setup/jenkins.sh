#!/usr/bin/env bash
# Initial Jenkins configuration
# Plugins and JCasC are applied automatically via volumes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/jenkins-trust.sh
source "${SCRIPT_DIR}/../auth/jenkins-trust.sh"

JENKINS_URL="http://${JENKINS_HOSTNAME:-jenkins.briklab.test}:${JENKINS_HTTP_PORT:-9090}"

# Wait for Jenkins to be ready
wait_for_jenkins() {
    log_info "Waiting for Jenkins..."
    if briklab.wait.until 150 5 curl -sf -o /dev/null "${JENKINS_URL}/login"; then
        log_ok "Jenkins is ready"
    else
        log_error "Jenkins is not ready after 150s"
        exit 1
    fi
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
# cmd_setup restarts Jenkins right after this script, which loads the store.
briklab.auth.jenkins_trust_ca

log_ok "Jenkins configuration complete"
echo ""
echo -e "${BLUE}Jenkins access:${NC}"
echo "  URL      : ${JENKINS_URL}"
echo "  Login    : admin"
echo "  Password : ${JENKINS_ADMIN_PASSWORD:-changeme_jenkins_admin}"
