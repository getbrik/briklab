#!/usr/bin/env bash
# E2E GitLab channel promotion (P2-A) -- candidate -> release with evidence.
#
# Proves the channel-model promote stage on a live orchestrator:
#
#   Phase A (positive): a tagged CI run publishes the candidate image and
#     signs its digest (cosign attestations on the referential's key), then
#     brik-promote copies the image WITH its referrers to the release channel
#     (oras cp -r) and verifies the attestations on the destination.
#     Host-side asserts: release digest == candidate digest AND the referrer
#     index travelled to the destination.
#
#   Phase B (negative): seed the release channel with a DIFFERENT artifact at
#     the same version, re-run the tagged pipeline: brik-promote must FAIL
#     (immutable release channel) and say why in its trace. A silent
#     overwrite or a green no-op here is the exact failure mode the
#     immutability check exists to refuse.
#
# Configuration (env vars):
#   E2E_TIMEOUT - per-pipeline timeout in seconds (default: 900)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/gitlab-api.sh
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
# shellcheck source=lib/nexus.sh
source "${SCRIPT_DIR}/lib/nexus.sh"
reload_env
briklab.auth.gitlab_pat

TIMEOUT_SECONDS="${E2E_TIMEOUT:-900}"
PROJECT_PATH="brik%2Fnode-promote-channel"
PROJECT_NAME="brik/node-promote-channel"
SEED_TAG="v0.1.0"
VERSION="0.1.0"
CANDIDATE_REPO="brik/node-promote-channel"
RELEASE_REPO="brik/node-promote-channel-released"

echo ""
log_info "=== Brik E2E GitLab channel promotion (cd-promote) ==="
log_info "version=${VERSION}  candidate=${CANDIDATE_REPO}  release=${RELEASE_REPO}"
echo ""

log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID="$(e2e.gitlab.get_project_id "$PROJECT_PATH")"
if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found (was it pushed?)"
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# The release channel is immutable: clean it so the run starts from "version
# absent" whatever a previous run (notably its phase B junk) left behind.
log_info "Cleaning the release channel (idempotent re-run)..."
e2e.nexus.delete_docker_images "$RELEASE_REPO"

# Trigger the tagged pipeline (CI flow: package publishes the candidate,
# container-scan signs it, promote copies it to release) and wait for its
# terminal state. Sets PIPELINE_ID and PIPELINE_STATUS (globals: a command
# substitution would lose them to a subshell).
_run_tagged_pipeline() {
    PIPELINE_ID=""
    PIPELINE_STATUS=""
    local id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$SEED_TAG" "BRIK_WITH_PACKAGE=true")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the tagged pipeline"
        return 1
    fi
    log_ok "pipeline #${id} triggered"
    PIPELINE_ID="$id"
    PIPELINE_STATUS="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
}

# --- Phase A: positive promotion --------------------------------------------
log_info "--- Phase A: tagged CI run promotes candidate -> release ---"
_run_tagged_pipeline || exit 1
if [[ "$PIPELINE_STATUS" != "success" ]]; then
    log_error "tagged pipeline status: ${PIPELINE_STATUS} (expected success)"
    exit 1
fi
log_ok "tagged pipeline succeeded"

CAND_DIGEST="$(e2e.nexus.docker_digest "$CANDIDATE_REPO" "$VERSION")"
REL_DIGEST="$(e2e.nexus.docker_digest "$RELEASE_REPO" "$VERSION")"
log_info "candidate digest: ${CAND_DIGEST:-<absent>}"
log_info "release   digest: ${REL_DIGEST:-<absent>}"
if [[ -z "$CAND_DIGEST" || -z "$REL_DIGEST" ]]; then
    log_error "candidate or release image missing from the registry"
    exit 1
fi
if [[ "$CAND_DIGEST" != "$REL_DIGEST" ]]; then
    log_error "release digest differs from candidate (promotion did not preserve the bytes)"
    exit 1
fi
log_ok "release channel holds the candidate digest (digest-preserving copy)"

REFERRERS="$(e2e.nexus.docker_referrers_count "$RELEASE_REPO" "$REL_DIGEST")"
log_info "referrer manifests on the release digest: ${REFERRERS:-0}"
if [[ "${REFERRERS:-0}" -lt 1 ]]; then
    log_error "no referrers at the destination: the evidence graph did NOT travel"
    exit 1
fi
log_ok "evidence graph travelled with the image (${REFERRERS} referrers)"

# --- Phase B: negative -- immutable release channel -------------------------
log_info "--- Phase B: divergent release content must refuse the promotion ---"
if ! command -v oras >/dev/null 2>&1; then
    log_error "oras is required on the host to seed the divergent artifact"
    exit 1
fi
JUNK_DIR="$(mktemp -d)"
trap 'rm -rf "$JUNK_DIR"' EXIT
printf 'divergent content\n' > "${JUNK_DIR}/junk.txt"
NEXUS_DOCKER_HOST="${NEXUS_HOSTNAME:-nexus.briklab.test}:${NEXUS_DOCKER_PORT:-8082}"
log_info "seeding a divergent artifact at ${RELEASE_REPO}:${VERSION}..."
if ! (cd "$JUNK_DIR" && oras push --plain-http \
        -u admin -p "${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}" \
        "${NEXUS_DOCKER_HOST}/${RELEASE_REPO}:${VERSION}" \
        junk.txt:text/plain >/dev/null 2>&1); then
    log_error "failed to seed the divergent artifact in the release channel"
    exit 1
fi
log_ok "release channel now holds a foreign digest at ${VERSION}"

_run_tagged_pipeline || exit 1
if [[ "$PIPELINE_STATUS" != "failed" ]]; then
    log_error "pipeline status: ${PIPELINE_STATUS} (expected failed -- the immutable release channel must refuse the overwrite)"
    exit 1
fi
log_ok "pipeline failed as expected"

# The brik-* jobs live in the child pipeline (parent -> bridge).
CHILD_ID="$(e2e.gitlab.get_child_pipeline_id "$PROJECT_ID" "$PIPELINE_ID")"
JOBS_JSON="$(e2e.gitlab.get_jobs "$PROJECT_ID" "${CHILD_ID:-$PIPELINE_ID}")"
PROMOTE_STATUS="$(e2e.gitlab.get_job_status "$JOBS_JSON" "brik-promote")"
if [[ "$PROMOTE_STATUS" != "failed" ]]; then
    log_error "brik-promote status: ${PROMOTE_STATUS} (expected failed)"
    exit 1
fi
PROMOTE_JOB_ID="$(echo "$JOBS_JSON" | jq -r '[.[] | select(.name == "brik-promote")][0].id // empty')"
TRACE="$(e2e.gitlab.get_job_log "$PROJECT_ID" "$PROMOTE_JOB_ID")"
if ! grep -q "immutable" <<< "$TRACE"; then
    log_error "brik-promote failed but did not state the immutability refusal"
    exit 1
fi
log_ok "brik-promote refused the overwrite (immutable release channel)"

# Leave a clean release channel behind (next run, other scenarios).
e2e.nexus.delete_docker_images "$RELEASE_REPO"

echo ""
log_ok "=== GITLAB CHANNEL PROMOTION PASSED (evidence carried, immutability enforced) ==="
