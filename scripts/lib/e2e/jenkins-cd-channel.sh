#!/usr/bin/env bash
# E2E Jenkins CD channel keystone -- Jenkins callbacks for lib/cd-channel.sh.
#
# Deploys to dev (ArgoCD app brik-e2e-cd-dev): independent of the GitLab keystone
# (staging) and a proof of build-once / deploy-many (the same digest to a second
# environment). The shared flow lives in e2e.cd_channel.run; this file only wires
# the Jenkins-specific CI/CD triggers.
#
#   CI = multibranch brikIntegrate (node-deploy-channel, Jenkinsfile)
#   CD = parameterized brikDeploy pipelineJob (node-deploy-channel-deploy)
#
# Configuration (env vars):
#   E2E_JENKINS_TIMEOUT - per-build timeout in seconds (default: 900)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/jenkins-api.sh
source "${SCRIPT_DIR}/lib/jenkins-api.sh"
# shellcheck source=lib/cd-channel.sh
source "${SCRIPT_DIR}/lib/cd-channel.sh"
reload_env

TIMEOUT_SECONDS="${E2E_JENKINS_TIMEOUT:-900}"
CI_JOB="node-deploy-channel"           # multibranch (brikIntegrate)
CD_JOB="node-deploy-channel-deploy"    # parameterized pipelineJob (brikDeploy)
SEED_TAG="v0.1.0"
DEPLOY_VERSION="0.1.0"
ENVIRONMENT="dev"
APP="brik-e2e-cd-dev"

if [[ -z "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
    log_error "JENKINS_ADMIN_PASSWORD is not set in .env"
    exit 1
fi
if ! e2e.jenkins.api_get "api/json" &>/dev/null; then
    log_error "Jenkins is not reachable"
    exit 1
fi
if ! e2e.jenkins.wait_job_exists "$CD_JOB" 60; then
    log_error "CD job '${CD_JOB}' not found (JCasC not applied?)"
    exit 1
fi

# CI seed via the v0.1.0 TAG sub-job (release context -> release + package ->
# publish), mirroring the GitLab seed. The tag is a sub-job distinct from main,
# so building it never shares main's workspace -- avoiding the @libs/ checkout
# race that concurrent same-branch builds cause. The tag is discovered by
# giteaTagDiscovery but not auto-built, so we trigger it explicitly and track
# its own build number (no branch-indexing race -> no false positive).
_cd_channel_seed_ci() {
    e2e.jenkins.scan_multibranch "$CI_JOB" || true

    # Wait for the tag sub-job to be indexed.
    local waited=0
    until E2E_JENKINS_BRANCH="$SEED_TAG" e2e.jenkins.api_get "job/${CI_JOB}/job/${SEED_TAG}/api/json" &>/dev/null; do
        if [[ "$waited" -ge 180 ]]; then
            log_error "tag sub-job ${SEED_TAG} was not indexed within 180s"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done

    # No params: a first tag build has no registered parameters, and the tag
    # context already activates release + package (the publish).
    local bn
    bn="$(E2E_JENKINS_BRANCH="$SEED_TAG" e2e.jenkins.trigger_build "$CI_JOB" "")" || true
    if [[ -z "$bn" ]]; then
        log_error "failed to trigger the ${SEED_TAG} tag build"
        return 1
    fi
    log_ok "CI tag build ${SEED_TAG} #${bn} triggered"
    local res
    res="$(E2E_JENKINS_BRANCH="$SEED_TAG" e2e.jenkins.wait_build "$CI_JOB" "$bn" "$TIMEOUT_SECONDS")"
    echo ""
    if [[ "$res" != "SUCCESS" ]]; then
        log_error "CI tag build: ${res}"
        E2E_JENKINS_BRANCH="$SEED_TAG" e2e.jenkins.get_console_log "$CI_JOB" "$bn" 2>/dev/null | tail -30 || true
        return 1
    fi
}

# CD via the parameterized brikDeploy pipelineJob.
_cd_channel_deploy() {
    local version="$1" environment="$2" bn
    bn="$(e2e.jenkins.trigger_build "$CD_JOB" \
        "BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment}")" || true
    if [[ -z "$bn" ]]; then
        log_error "failed to trigger the CD build"
        return 1
    fi
    log_ok "CD build #${bn} triggered"
    local res
    res="$(e2e.jenkins.wait_build "$CD_JOB" "$bn" "$TIMEOUT_SECONDS")"
    echo ""
    if [[ "$res" != "SUCCESS" ]]; then
        log_error "CD build: ${res}"
        e2e.jenkins.get_console_log "$CD_JOB" "$bn" 2>/dev/null | tail -30 || true
        return 1
    fi
}

e2e.cd_channel.run "jenkins" "$APP" "$ENVIRONMENT" "$DEPLOY_VERSION" "$TIMEOUT_SECONDS"
