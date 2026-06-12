#!/usr/bin/env bash
# E2E GitLab CD channel keystone -- GitLab callbacks for lib/cd-channel.sh.
#
# Deploys to staging (ArgoCD app brik-e2e-cd). The shared flow lives in
# e2e.cd_channel.run; this file only wires the GitLab-specific CI/CD triggers.
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
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
# shellcheck source=lib/reset.sh
source "${SCRIPT_DIR}/lib/reset.sh"
# shellcheck source=lib/cd-channel.sh
source "${SCRIPT_DIR}/lib/cd-channel.sh"
reload_env
briklab.auth.gitlab_pat

TIMEOUT_SECONDS="${E2E_TIMEOUT:-900}"
PROJECT_PATH="brik%2Fnode-deploy-channel"
PROJECT_NAME="brik/node-deploy-channel"
SEED_TAG="v0.1.0"
# Package tags the image with the release version without the leading "v"
# (cf. assert.image_tag); brik deploy resolves that version, so DEPLOY_VERSION
# drops the "v".
DEPLOY_VERSION="0.1.0"
ENVIRONMENT="staging"
APP="brik-e2e-cd"

log_info "Looking up project ${PROJECT_NAME}..."
PROJECT_ID="$(e2e.gitlab.get_project_id "$PROJECT_PATH")"
if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ${PROJECT_NAME} not found (was it pushed?)"
    exit 1
fi
log_ok "Project ID: ${PROJECT_ID}"

e2e.gitlab.cancel_pipelines "$PROJECT_ID" "running"
e2e.gitlab.cancel_pipelines "$PROJECT_ID" "pending"

# Least-privilege CD: the deploy jobs resolve and verify with the read-only
# brik-cd account (environment-scoped values of BRIK_REGISTRY_*); the CI
# seed keeps the group-level write identity.
e2e.gitlab.scope_cd_registry_creds "$PROJECT_ID" staging production dev
log_ok "read-only CD registry identity scoped to staging/production/dev"

# The scenario owns its state-repo: each project push re-mints the commit
# while the reproducible image keeps the SAME digest, so a stale evidence
# record would conflict (another commit claiming the digest) and stale
# validated_for grants would defeat the chain-refusal phase. Start from a
# clean journal (the reset drops and restores the branch-protection rule
# around its baseline force-push).
e2e.reset.gitops_config_repo "gitea" "evidence-cd" || {
    log_error "cannot reset the evidence-cd state-repo"
    exit 1
}

# CI seed: no CD inputs -> include:rules selects brik-integrate.yml, which
# publishes the image to the release channel.
_cd_channel_seed_ci() {
    local id
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "$SEED_TAG" "BRIK_WITH_PACKAGE=true")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CI seed pipeline"
        return 1
    fi
    log_ok "CI pipeline #${id} triggered"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CI seed status: ${st}"; return 1; }
}

# CD: both CD inputs set -> include:rules selects brik-deploy.yml.
# Records the pipeline id in _CD_LAST_PIPELINE_ID so the chain phase can
# assert the producer trace of the staging run.
_CD_LAST_PIPELINE_ID=""
_cd_channel_deploy() {
    local version="$1" environment="$2" extra="${3:-}" id
    local vars="BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment}"
    [[ -n "$extra" ]] && vars="${vars},${extra}"
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" "$vars")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CD pipeline"
        return 1
    fi
    log_ok "CD pipeline #${id} triggered"
    _CD_LAST_PIPELINE_ID="$id"
    local st
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    [[ "$st" == "success" ]] || { log_error "CD status: ${st}"; return 1; }
}

# _cd_deploy_trace <pipeline_id> - echo the brik-cd-deploy job trace.
_cd_deploy_trace() {
    local pipeline_id="$1" jobs job_id
    jobs="$(e2e.gitlab.get_jobs "$PROJECT_ID" "$pipeline_id")"
    job_id="$(echo "$jobs" | jq -r '[.[] | select(.name == "brik-cd-deploy")][0].id // empty')"
    if [[ -z "$job_id" ]]; then
        log_error "job brik-cd-deploy not found in pipeline #${pipeline_id}"
        return 1
    fi
    e2e.gitlab.get_job_log "$PROJECT_ID" "$job_id"
}

# _trigger_cd_expect_failure - trigger a CD pipeline that MUST fail, and the
# brik-cd-deploy trace MUST carry <pattern> (true-positive: the right gate
# refused, not an unrelated crash).
_trigger_cd_expect_failure() {
    local version="$1" environment="$2" pattern="$3" id st
    id="$(e2e.gitlab.trigger_pipeline "$PROJECT_ID" "main" \
        "BRIK_DEPLOY_VERSION=${version},BRIK_DEPLOY_ENVIRONMENT=${environment}")"
    if [[ -z "$id" ]]; then
        log_error "failed to trigger the CD pipeline"
        return 1
    fi
    log_ok "CD pipeline #${id} triggered (expected to be refused)"
    st="$(e2e.gitlab.wait_pipeline "$PROJECT_ID" "$id" "$TIMEOUT_SECONDS")" || true
    echo ""
    if [[ "$st" != "failed" ]]; then
        log_error "CD status: ${st} (expected failed -- the gate must refuse)"
        return 1
    fi
    local trace
    trace="$(_cd_deploy_trace "$id")" || return 1
    if ! grep -q "$pattern" <<< "$trace"; then
        log_error "brik-cd-deploy trace does not show '${pattern}' -- wrong refusal"
        return 1
    fi
    log_ok "deploy refused with '${pattern}'"
}

# _cd_channel_pre_deploy - chain negative: production is gated on
# requires_eligibility [artifact_validated_for] and nothing validated the
# fresh digest yet (the CI seed re-mints a digest, so grants from previous
# runs cannot replay), so the CD deploy to production MUST be refused.
_cd_channel_pre_deploy() {
    log_info "--- Chain: production must be refused before the staging validation ---"
    _trigger_cd_expect_failure "$DEPLOY_VERSION" "production" "refusing to deploy"
}

# _cd_journal_events <subtree> - clone the evidence-cd state-repo and emit
# the events under the given journal subtree (promotions|deployments) as a
# JSON stream on stdout. Empty subtree -> empty stream.
_cd_journal_events() {
    local subtree="$1" tmp
    tmp="$(mktemp -d)"
    if ! e2e.git.clone \
            "https://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}/brik/evidence-cd.git" \
            "${tmp}/evidence-cd" "${GITEA_ADMIN_USER:-brik}" "$GITEA_PAT"; then
        rm -rf "$tmp"
        return 1
    fi
    find "${tmp}/evidence-cd/${subtree}" -type f -name '*.json' -exec cat {} + 2>/dev/null || true
    rm -rf "$tmp"
}

e2e.cd_channel.run "gitlab" "$APP" "$ENVIRONMENT" "$DEPLOY_VERSION" "$TIMEOUT_SECONDS"

# --- Promotion chain (validates_for): staging validated the artifact for ---
# --- production; the eligibility gate must now let the same digest through. -
echo ""
log_info "=== Chain phase: staging -> production (validates_for producer) ==="

log_info "--- Chain: staging trace shows the journaled validation ---"
STAGING_TRACE="$(_cd_deploy_trace "$_CD_LAST_PIPELINE_ID")"
if ! grep -q "journaled artifact_validated_for" <<< "$STAGING_TRACE"; then
    log_error "staging brik-cd-deploy trace does not show 'journaled artifact_validated_for'"
    exit 1
fi
log_ok "staging journaled the validation for production"

if ! grep -q "journaled deployed" <<< "$STAGING_TRACE"; then
    log_error "staging brik-cd-deploy trace does not show 'journaled deployed'"
    exit 1
fi
log_ok "staging journaled its deployed event"

STAGING_IMAGE="$(e2e.argocd.get_app_image "$APP")"
STAGING_DIGEST="${STAGING_IMAGE#*@}"

log_info "--- Chain: the journal carries the digest-bound grant ---"
if ! GRANT_EVENTS="$(_cd_journal_events promotions)"; then
    log_error "cannot clone the evidence-cd state-repo"
    exit 1
fi
GRANT_COUNT="$(jq -s --arg d "$STAGING_DIGEST" \
    '[.[] | select(.type == "artifact_validated_for"
                   and .environment == "production"
                   and .digest == $d)] | length' <<< "$GRANT_EVENTS")"
if [[ -z "$GRANT_COUNT" || "$GRANT_COUNT" -lt 1 ]]; then
    log_error "no artifact_validated_for(production) event bound to ${STAGING_DIGEST} in the journal"
    exit 1
fi
log_ok "journal carries artifact_validated_for(production) bound to ${STAGING_DIGEST}"

# DeploymentJournal (P3-A): the staging deploy recorded a deployed event
# bound to the digest, anchored by the definition_hash and carrying both
# definition layers (version_ref = the tag commit, env_config_ref = the
# config_ref commit) plus the orchestrator run id.
log_info "--- Journal: deployed(staging) is recorded with its definition refs ---"
if ! DEPLOYED_EVENTS="$(_cd_journal_events deployments)"; then
    log_error "cannot clone the evidence-cd state-repo"
    exit 1
fi
DEP_COUNT="$(jq -s --arg d "$STAGING_DIGEST" \
    '[.[] | select(.type == "deployed"
                   and .environment == "staging"
                   and .digest == $d
                   and (.definition_hash | startswith("sha256:"))
                   and has("version_ref")
                   and has("env_config_ref")
                   and has("run_id"))] | length' <<< "$DEPLOYED_EVENTS")"
if [[ -z "$DEP_COUNT" || "$DEP_COUNT" -lt 1 ]]; then
    log_error "no deployed(staging) event bound to ${STAGING_DIGEST} with definition_hash + version_ref + env_config_ref + run_id"
    exit 1
fi
log_ok "journal carries deployed(staging) bound to ${STAGING_DIGEST} (definition_hash + layers + run_id)"

# CD notification (best-effort on brik's side, asserted here): a sink on the
# host receives the outcome of the production deploy. Job containers reach
# the host via host.docker.internal.
NP_DIR="$(mktemp -d)"
NP_PORT=18765
python3 - "$NP_PORT" "${NP_DIR}/hooks.log" <<'PY' &
import sys, http.server
port, out = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode('utf-8', 'replace')
        with open(out, 'a') as f:
            f.write(body + "\n")
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(('0.0.0.0', port), H).serve_forever()
PY
NP_PID=$!
_np_cleanup() { kill "$NP_PID" 2>/dev/null || true; rm -rf "$NP_DIR"; }

# Readiness gate: the sink must be listening on the host AND reachable from
# a container (the same path the job's POST takes) before the deploy fires,
# so an assert failure blames brik, never the sink infrastructure.
NP_READY=0
for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${NP_PORT}/"; then
        NP_READY=1
        break
    fi
    sleep 0.5
done
if [[ "$NP_READY" -ne 1 ]]; then
    _np_cleanup
    log_error "the webhook sink did not come up on :${NP_PORT}"
    exit 1
fi
if ! docker run --rm curlimages/curl:latest \
        curl -s -o /dev/null --max-time 5 "http://host.docker.internal:${NP_PORT}/" 2>/dev/null; then
    _np_cleanup
    log_error "the webhook sink is not reachable from containers (host.docker.internal:${NP_PORT})"
    exit 1
fi
log_ok "webhook sink up and container-reachable on :${NP_PORT}"

log_info "--- Chain: CD deploy ${DEPLOY_VERSION} -> production ---"
if ! _cd_channel_deploy "$DEPLOY_VERSION" "production" \
        "BRIK_NOTIFY_WEBHOOK_URL=http://host.docker.internal:${NP_PORT}/hook"; then
    _np_cleanup
    log_error "production CD deploy failed despite the validation grant"
    exit 1
fi

log_info "--- Chain: assert the production digest via ArgoCD (brik-e2e-cd-prod) ---"
if ! e2e.argocd.assert_synced "brik-e2e-cd-prod" "$TIMEOUT_SECONDS"; then
    log_error "ArgoCD app 'brik-e2e-cd-prod' did not reach Synced+Healthy"
    exit 1
fi
PROD_IMAGE="$(e2e.argocd.get_app_image "brik-e2e-cd-prod")"
log_info "production image: ${PROD_IMAGE:-<none>}"
if [[ "$PROD_IMAGE" != *"@${STAGING_DIGEST}" ]]; then
    log_error "production does not run the validated digest (staging=${STAGING_DIGEST} production=${PROD_IMAGE:-<empty>})"
    exit 1
fi

log_info "--- Journal: deployed(production) is recorded on the same digest ---"
if ! DEPLOYED_EVENTS="$(_cd_journal_events deployments)"; then
    log_error "cannot clone the evidence-cd state-repo"
    exit 1
fi
PROD_DEP_COUNT="$(jq -s --arg d "$STAGING_DIGEST" \
    '[.[] | select(.type == "deployed"
                   and .environment == "production"
                   and .digest == $d
                   and (.definition_hash | startswith("sha256:"))
                   and has("version_ref"))] | length' <<< "$DEPLOYED_EVENTS")"
if [[ -z "$PROD_DEP_COUNT" || "$PROD_DEP_COUNT" -lt 1 ]]; then
    _np_cleanup
    log_error "no deployed(production) event bound to ${STAGING_DIGEST} in the journal"
    exit 1
fi
log_ok "journal carries deployed(production) bound to ${STAGING_DIGEST}"

log_info "--- Notification: the webhook received the CD outcome ---"
if ! grep -q '"event": "deploy"' "${NP_DIR}/hooks.log" 2>/dev/null \
        || ! grep -q '"status": "success"' "${NP_DIR}/hooks.log" \
        || ! grep -q '"environment": "production"' "${NP_DIR}/hooks.log" \
        || ! grep -q "$STAGING_DIGEST" "${NP_DIR}/hooks.log" \
        || ! grep -q "requires_eligibility" "${NP_DIR}/hooks.log"; then
    if [[ -s "${NP_DIR}/hooks.log" ]]; then
        log_error "the webhook sink received an unexpected payload:"
        sed 's/^/    /' "${NP_DIR}/hooks.log"
    else
        log_error "the webhook sink received nothing (sink alive: $(kill -0 "$NP_PID" 2>/dev/null && echo yes || echo no)); brik-cd-deploy trace:"
        _cd_deploy_trace "$_CD_LAST_PIPELINE_ID" 2>/dev/null | grep -i "webhook\|notif" | sed 's/^/    /' || true
    fi
    _np_cleanup
    log_error "the webhook sink did not receive the CD outcome (event/status/env/digest/gates)"
    exit 1
fi
_np_cleanup
log_ok "webhook notification received (event, status, environment, digest, gates)"

log_info "--- Projection: GitLab records the deployment on the environment ---"
NP_DEPLOYMENTS="$(e2e.gitlab.api_get "projects/${PROJECT_ID}/deployments?environment=production&status=success" | jq 'length')"
if [[ -z "$NP_DEPLOYMENTS" || "$NP_DEPLOYMENTS" -lt 1 ]]; then
    log_error "no GitLab deployment record for environment 'production'"
    exit 1
fi
log_ok "GitLab shows ${NP_DEPLOYMENTS} deployment(s) on 'production' (projection, never source of truth)"

log_ok "=== GITLAB CD CHAIN PASSED (refused -> validated by staging -> deployed) ==="

# --- Independent Layer E (config_ref, A3): an env config change redeploys ---
# --- the SAME version; production keeps the definition frozen at the tag. ---
echo ""
log_info "=== Layer E phase: env config change redeploys without a new version (config_ref) ==="

GITLAB_REPO_URL="http://${GITLAB_HOSTNAME:-gitlab.briklab.test}:${GITLAB_HTTP_PORT:-8929}/brik/node-deploy-channel.git"
GITEA_BASE_URL="https://${GITEA_HOSTNAME:-gitea.briklab.test}:${GITEA_HTTP_PORT:-3000}"

log_info "--- Layer E: push an env config change on main (no new version) ---"
LE_TMP="$(mktemp -d)"
APP_DIR="${LE_TMP}/node-deploy-channel"
if ! e2e.git.clone "$GITLAB_REPO_URL" "$APP_DIR" "root" "$GITLAB_PAT"; then
    rm -rf "$LE_TMP"
    log_error "cannot clone the app repo from GitLab"
    exit 1
fi
# Idempotent across re-runs: bump replicas from whatever main carries now.
LE_OLD_REPLICAS="$(grep -oE 'replicas: [0-9]+' "${APP_DIR}/k8s/deployment.yaml" | awk '{print $2}')"
LE_NEW_REPLICAS=$((LE_OLD_REPLICAS + 1))
sed -i.bak "s/replicas: ${LE_OLD_REPLICAS}/replicas: ${LE_NEW_REPLICAS}/" \
    "${APP_DIR}/k8s/deployment.yaml" && rm -f "${APP_DIR}/k8s/deployment.yaml.bak"
if ! e2e.git.commit "$APP_DIR" "chore: bump staging replicas to ${LE_NEW_REPLICAS} (env config change)"; then
    rm -rf "$LE_TMP"
    log_error "cannot commit the env config change"
    exit 1
fi
# ci.skip: this push must not fire a CI pipeline -- the point is precisely
# that NO new version is produced for the config change.
if ! e2e.git.push "$APP_DIR" "$GITLAB_REPO_URL" "root" "$GITLAB_PAT" "-o ci.skip"; then
    rm -rf "$LE_TMP"
    log_error "cannot push the env config change"
    exit 1
fi
rm -rf "$LE_TMP"
log_ok "main now carries replicas: ${LE_NEW_REPLICAS} (tag ${SEED_TAG} still carries ${LE_OLD_REPLICAS})"

log_info "--- Layer E: redeploy ${DEPLOY_VERSION} -> staging (same version, new config) ---"
if ! _cd_channel_deploy "$DEPLOY_VERSION" "staging"; then
    log_error "staging CD redeploy failed after the env config change"
    exit 1
fi

log_info "--- Layer E: the deploy resolved the env config at config_ref ---"
LE_TRACE="$(_cd_deploy_trace "$_CD_LAST_PIPELINE_ID")"
if ! grep -q "resolving environment config for 'staging' at main" <<< "$LE_TRACE"; then
    log_error "brik-cd-deploy trace does not show the Layer E resolution (config_ref)"
    exit 1
fi
log_ok "trace shows the env config resolved at main"

log_info "--- Layer E: config repo carries the new config pinned to the SAME digest ---"
LE_CFG_TMP="$(mktemp -d)"
if ! e2e.git.clone "${GITEA_BASE_URL}/brik/config-deploy-cd.git" \
        "${LE_CFG_TMP}/cfg" "${GITEA_ADMIN_USER:-brik}" "$GITEA_PAT"; then
    rm -rf "$LE_CFG_TMP"
    log_error "cannot clone config-deploy-cd"
    exit 1
fi
if ! grep -q "replicas: ${LE_NEW_REPLICAS}" "${LE_CFG_TMP}/cfg/k8s/deployment.yaml"; then
    rm -rf "$LE_CFG_TMP"
    log_error "config-deploy-cd does not carry replicas: ${LE_NEW_REPLICAS} (Layer E not applied)"
    exit 1
fi
if ! grep -q "@${STAGING_DIGEST}" "${LE_CFG_TMP}/cfg/k8s/deployment.yaml"; then
    rm -rf "$LE_CFG_TMP"
    log_error "config-deploy-cd is not pinned to the seeded digest ${STAGING_DIGEST} anymore"
    exit 1
fi
log_ok "staging intent: replicas ${LE_NEW_REPLICAS} @ unchanged digest ${STAGING_DIGEST}"

log_info "--- Layer E: production stays on the tag's definition (no config_ref) ---"
if ! e2e.git.clone "${GITEA_BASE_URL}/brik/config-deploy-cd-prod.git" \
        "${LE_CFG_TMP}/cfg-prod" "${GITEA_ADMIN_USER:-brik}" "$GITEA_PAT" \
    || ! grep -q "replicas: ${LE_OLD_REPLICAS}" "${LE_CFG_TMP}/cfg-prod/k8s/deployment.yaml"; then
    rm -rf "$LE_CFG_TMP"
    log_error "config-deploy-cd-prod no longer carries replicas: ${LE_OLD_REPLICAS} (Layer V leaked)"
    exit 1
fi
rm -rf "$LE_CFG_TMP"
log_ok "production intent untouched (replicas ${LE_OLD_REPLICAS})"

log_info "--- Layer E: ArgoCD reconciles staging to the new config ---"
if ! e2e.argocd.assert_synced "$APP" "$TIMEOUT_SECONDS"; then
    log_error "ArgoCD app '${APP}' did not reach Synced+Healthy after the Layer E redeploy"
    exit 1
fi

# The redeploy resolved the env config at a NEW main commit: the journal
# must now carry two deployed(staging) events on the same digest with
# DISTINCT env_config_ref values -- the Layer E history of the environment.
log_info "--- Journal: the Layer E redeploy recorded a new env_config_ref ---"
if ! DEPLOYED_EVENTS="$(_cd_journal_events deployments)"; then
    log_error "cannot clone the evidence-cd state-repo"
    exit 1
fi
LE_REF_COUNT="$(jq -s --arg d "$STAGING_DIGEST" \
    '[.[] | select(.type == "deployed"
                   and .environment == "staging"
                   and .digest == $d)
          | .env_config_ref] | unique | length' <<< "$DEPLOYED_EVENTS")"
if [[ -z "$LE_REF_COUNT" || "$LE_REF_COUNT" -lt 2 ]]; then
    log_error "expected 2 distinct env_config_ref on deployed(staging) for ${STAGING_DIGEST}, got ${LE_REF_COUNT:-0}"
    exit 1
fi
log_ok "journal carries ${LE_REF_COUNT} distinct env_config_ref for deployed(staging)"

log_ok "=== GITLAB LAYER E PASSED (config change redeployed ${DEPLOY_VERSION} without a new version) ==="

# --- Status (P3-B): the three layers agree after the redeploy; a config ---
# --- change pushed WITHOUT a redeploy surfaces as DEFINITION drift.     ---
echo ""
log_info "=== Status phase: brik status reports journal + desired + live ==="

SP_BRIK_BIN="${BRIKLAB_ROOT}/../brik/bin/brik"
SP_TMP="$(mktemp -d)"
SP_LOG="${SP_TMP}/logs"

# Fresh clone each call: the desired layer re-derives at the CURRENT tip of
# the env's config_ref, which the host-side copy would not carry.
_sp_run_status() {
    rm -rf "${SP_TMP}/app" "$SP_LOG"
    mkdir -p "$SP_LOG"
    if ! e2e.git.clone "$GITLAB_REPO_URL" "${SP_TMP}/app" "root" "$GITLAB_PAT"; then
        log_error "cannot clone the app repo for brik status"
        return 1
    fi
    BRIK_INFRA_DIR="${BRIKLAB_ROOT}/data/infra" BRIK_LOG_DIR="$SP_LOG" \
        BRIK_GIT_TOKEN="${GITEA_PAT}" ARGOCD_AUTH_TOKEN="${ARGOCD_AUTH_TOKEN}" \
        "$SP_BRIK_BIN" status --environment staging --workspace "${SP_TMP}/app"
}

log_info "--- Status: the three layers agree (no drift) ---"
SP_OUT="$(_sp_run_status)" || { rm -rf "$SP_TMP"; log_error "brik status failed"; exit 1; }
printf '%s\n' "$SP_OUT" | sed 's/^/    /'
if ! grep -q "journal:.*${DEPLOY_VERSION} @ ${STAGING_DIGEST}" <<< "$SP_OUT" \
        || ! grep -q "live:.*${STAGING_DIGEST}" <<< "$SP_OUT" \
        || ! grep -q "drift:.*none detected" <<< "$SP_OUT"; then
    rm -rf "$SP_TMP"
    log_error "brik status does not show the three layers in agreement"
    exit 1
fi
log_ok "status shows journal + desired + live in agreement"

log_info "--- Status: a config change without a redeploy is DEFINITION drift ---"
SP_PUSH="$(mktemp -d)"
if ! e2e.git.clone "$GITLAB_REPO_URL" "${SP_PUSH}/app" "root" "$GITLAB_PAT"; then
    rm -rf "$SP_TMP" "$SP_PUSH"
    log_error "cannot clone the app repo for the drift bump"
    exit 1
fi
SP_OLD_REPLICAS="$(grep -oE 'replicas: [0-9]+' "${SP_PUSH}/app/k8s/deployment.yaml" | awk '{print $2}')"
sed -i.bak "s/replicas: ${SP_OLD_REPLICAS}/replicas: $((SP_OLD_REPLICAS + 1))/" \
    "${SP_PUSH}/app/k8s/deployment.yaml" && rm -f "${SP_PUSH}/app/k8s/deployment.yaml.bak"
if ! e2e.git.commit "${SP_PUSH}/app" "chore: bump staging replicas (status drift probe)" \
        || ! e2e.git.push "${SP_PUSH}/app" "$GITLAB_REPO_URL" "root" "$GITLAB_PAT" "-o ci.skip"; then
    rm -rf "$SP_TMP" "$SP_PUSH"
    log_error "cannot push the drift probe config change"
    exit 1
fi
rm -rf "$SP_PUSH"

SP_OUT="$(_sp_run_status)" || { rm -rf "$SP_TMP"; log_error "brik status failed after the drift probe"; exit 1; }
printf '%s\n' "$SP_OUT" | sed 's/^/    /'
if ! grep -q "DEFINITION drift" <<< "$SP_OUT"; then
    rm -rf "$SP_TMP"
    log_error "brik status does not surface the definition drift"
    exit 1
fi
rm -rf "$SP_TMP"
log_ok "status surfaces the definition drift (config moved, no redeploy)"

log_ok "=== GITLAB STATUS PASSED (three layers + drift detection) ==="
