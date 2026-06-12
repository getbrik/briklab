#!/usr/bin/env bash
# ArgoCD Application provisioning for E2E deploy scenarios.
#
# Separated from k3d.sh (S5) so the Applications can be (re-)applied against an
# existing cluster without recreating it. k3d.sh invokes this at the end of a
# fresh cluster bring-up; it can also be run standalone to repair or refresh the
# Applications after the cluster is already up.
#
# Prerequisites:
#   - k3d cluster 'brik' running with ArgoCD installed (k3d.sh)
#   - Gitea running with config-deploy-gitops / config-deploy-rollback / config-deploy-cd repos
#   - GITEA_ADMIN_PASSWORD in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# Reload .env for the Gitea password (written during service setup).
reload_env
GITEA_PASSWORD="${GITEA_ADMIN_PASSWORD:-Brik-Gitea-2026}"

# Provision an ArgoCD Application that tracks the k8s/ path of a Gitea config
# repo. Args: $1 app_name  $2 namespace  $3 gitea_config_repo
_provision_argocd_app() {
    local app_name="$1"
    local namespace="$2"
    local config_repo="$3"
    local repo_url="https://brik:${GITEA_PASSWORD}@gitea.briklab.test:3000/brik/${config_repo}.git"

    kubectl apply -f - <<ARGOAPP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: ${namespace}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
ARGOAPP
    log_ok "ArgoCD application '${app_name}' created"
}

# === Main ===

# Trust the lab CA for the Gitea config repos: the repo-server resolves TLS
# certificates by hostname from argocd-tls-certs-cm. Restart it so the trust
# is effective immediately (the projected configmap refresh can lag ~1 min).
log_info "Trusting the lab CA for the Gitea config repos..."
_gitea_host="${GITEA_HOSTNAME:-gitea.briklab.test}"
kubectl -n argocd patch configmap argocd-tls-certs-cm --type merge \
    -p "$(jq -nc --arg host "$_gitea_host" \
            --arg pem "$(cat "${BRIKLAB_ROOT}/data/ca/ca.crt")" \
            '{data:{($host):$pem}}')"
kubectl -n argocd rollout restart deployment argocd-repo-server
kubectl -n argocd rollout status deployment argocd-repo-server --timeout=120s

log_info "Creating ArgoCD applications for E2E..."

# brik-e2e-gitops:   used by the node-deploy-gitops E2E scenario.
# brik-e2e-rollback: used by the node-deploy-gitops-rollback E2E scenario.
_provision_argocd_app "brik-e2e-gitops"   "brik-e2e-gitops"   "config-deploy-gitops"
_provision_argocd_app "brik-e2e-rollback" "brik-e2e-rollback" "config-deploy-rollback"
_provision_argocd_app "brik-e2e-cd"      "brik-e2e-cd"      "config-deploy-cd"
_provision_argocd_app "brik-e2e-cd-dev"  "brik-e2e-cd-dev"  "config-deploy-cd-dev"
# brik-e2e-cd-prod: chain-gated target of the validates_for producer E2E.
_provision_argocd_app "brik-e2e-cd-prod" "brik-e2e-cd-prod" "config-deploy-cd-prod"
# brik-e2e-signed: used by the node-deploy-signed E2E scenario (provenance gate).
_provision_argocd_app "brik-e2e-signed" "brik-e2e-signed" "config-deploy-signed"

log_ok "ArgoCD applications provisioned"
