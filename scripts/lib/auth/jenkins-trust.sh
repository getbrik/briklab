#!/usr/bin/env bash
# Lab CA trust for the Jenkins container - JVM truststore + system git.
#
# The Gitea plugin (JVM) and the SCM checkouts (git CLI on the controller)
# reach Gitea over TLS issued by the lab CA, mounted at /etc/briklab/ca.crt.
# Both imports land in the container's writable layer, so they survive a
# restart but NOT a recreate: every path that recreates the container
# (cmd_setup, briklab.recover.jenkins_token) must call this again.
#
# Usage:
#   source "path/to/auth/jenkins-trust.sh"
#   briklab.auth.jenkins_trust_ca            # import only
#   briklab.auth.jenkins_trust_ca --restart  # import + restart so the
#                                            # running JVM loads the store

[[ -n "${_BRIKLAB_JENKINS_TRUST_LOADED:-}" ]] && return 0
_BRIKLAB_JENKINS_TRUST_LOADED=1

# shellcheck source=../common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

briklab.auth.jenkins_trust_ca() {
    if ! docker exec brik-jenkins test -f /etc/briklab/ca.crt 2>/dev/null; then
        log_warn "Lab CA not mounted at /etc/briklab/ca.crt - TLS services will not verify"
        return 0
    fi
    docker exec -u root brik-jenkins bash -c '
        keytool -list -cacerts -storepass changeit -alias briklab-ca >/dev/null 2>&1 \
            || keytool -importcert -noprompt -cacerts -storepass changeit \
                   -alias briklab-ca -file /etc/briklab/ca.crt >/dev/null
        git config --system http.sslCAInfo /etc/briklab/ca.crt
    '
    log_ok "Lab CA trusted (JVM truststore + system git)"

    if [[ "${1:-}" == "--restart" ]]; then
        # The running JVM read its truststore at boot: restart (NOT recreate,
        # which would wipe the import again) so the import takes effect.
        log_info "Restarting Jenkins to load the truststore..."
        docker restart brik-jenkins >/dev/null
    fi
    return 0
}
