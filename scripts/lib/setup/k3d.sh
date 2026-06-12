#!/usr/bin/env bash
# k3d cluster creation + ArgoCD installation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../auth/argocd-portfwd.sh
source "${SCRIPT_DIR}/../auth/argocd-portfwd.sh"
# shellcheck source=../auth/argocd-token.sh
source "${SCRIPT_DIR}/../auth/argocd-token.sh"

# Pinned component versions (k3s image, ArgoCD release) from versions.yml.
load_versions
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.6-k3s1}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.3.7}"

K3D_API_PORT="${K3D_API_PORT:-6443}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8080}"
ARGOCD_PORT="${ARGOCD_PORT:-9080}"
CLUSTER_NAME="brik"

# Check prerequisites
for cmd in k3d kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "'${cmd}' not installed: brew install ${cmd}"
        exit 1
    fi
done

# Check if the cluster already exists
if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    log_warn "Cluster '${CLUSTER_NAME}' already exists"
    read -rp "Recreate? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        exit 0
    fi
    k3d cluster delete "$CLUSTER_NAME"
fi

# Create registries config for the Nexus Docker hosted registry.
# The Nexus docker repo enforces basic auth (forceBasicAuth), so containerd
# must authenticate: with no credentials the pull is anonymous, Nexus returns
# 401, and deployed pods are stuck in ImagePullBackOff. Inject the same admin
# credentials the CI uses to push (BRIK_PUBLISH_DOCKER_USER=admin) so the
# cluster can pull released images. Both hosts need an auth entry: containerd
# routes the pull through the mirror endpoint (brik-nexus:8082) and matches
# credentials against the host it actually contacts, not just the image's
# registry host (nexus.briklab.test:8082).
REGISTRIES_FILE=$(mktemp /tmp/k3d-registries-XXXXXX.yaml)
trap 'rm -f "$REGISTRIES_FILE"' EXIT

nexus_registry_user="admin"
nexus_registry_pass="${NEXUS_ADMIN_PASSWORD:-Brik-Nexus-2026}"
cat > "$REGISTRIES_FILE" <<YAML
mirrors:
  "nexus.briklab.test:8082":
    endpoint:
      - "http://brik-nexus:8082"
configs:
  "nexus.briklab.test:8082":
    auth:
      username: "${nexus_registry_user}"
      password: "${nexus_registry_pass}"
  "brik-nexus:8082":
    auth:
      username: "${nexus_registry_user}"
      password: "${nexus_registry_pass}"
YAML

# Create the k3d cluster
log_info "Creating k3d cluster '${CLUSTER_NAME}'..."

k3d cluster create "$CLUSTER_NAME" \
    --image "${K3S_IMAGE}" \
    --api-port "${K3D_API_PORT}" \
    --port "${K3D_HTTP_PORT}:80@loadbalancer" \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --servers-memory "${K3D_SERVER_MEMORY:-4g}" \
    --agents-memory "${K3D_AGENT_MEMORY:-4g}" \
    --network "brik-net" \
    --registry-config "$REGISTRIES_FILE" \
    --wait

log_ok "k3d cluster created"

# Export kubeconfig for CI runners (containers on brik-net)
KUBECONFIG_DIR="${BRIKLAB_ROOT}/data/k3d"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/kubeconfig"
mkdir -p "$KUBECONFIG_DIR"
k3d kubeconfig get "$CLUSTER_NAME" \
    | sed 's|https://0.0.0.0:6443|https://k3d-brik-serverlb:6443|' \
    | sed 's|certificate-authority-data:.*|insecure-skip-tls-verify: true|' \
    > "$KUBECONFIG_FILE"
chmod 644 "$KUBECONFIG_FILE"
log_ok "Kubeconfig exported to ${KUBECONFIG_FILE}"

# Verify the cluster
log_info "Verifying cluster..."
kubectl cluster-info
kubectl get nodes

# Create namespaces used by E2E deploy tests
for ns in brik-e2e-k8s brik-e2e-gitops brik-e2e-helm brik-e2e-rollback brik-e2e-workflow brik-e2e-cd brik-e2e-cd-dev brik-e2e-cd-prod; do
    kubectl create namespace "$ns" 2>/dev/null || true
done

# Install ArgoCD
log_info "Installing ArgoCD..."

kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd --server-side -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Wait for all ArgoCD deployments to be ready
log_info "Waiting for ArgoCD (may take 1-2 min)..."
for deploy in argocd-server argocd-repo-server argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis; do
    kubectl wait --for=condition=available --timeout=180s "deployment/${deploy}" -n argocd 2>/dev/null || \
        kubectl wait --for=condition=ready --timeout=180s "statefulset/${deploy}" -n argocd 2>/dev/null || true
done
kubectl wait --for=condition=ready --timeout=180s pod -l app.kubernetes.io/part-of=argocd -n argocd 2>/dev/null || true

# Patch the service for NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# Start and verify port-forward
briklab.auth.argocd_portfwd

# Retrieve admin password
local_argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Save to .env and export for current shell (needed by briklab.auth.argocd_token)
save_to_env "ARGOCD_ADMIN_PASSWORD" "$local_argocd_password"
export ARGOCD_ADMIN_PASSWORD="$local_argocd_password"

# Create ArgoCD service account and generate non-expiring API token
log_info "Creating ArgoCD service account 'brik' and generating API token..."
briklab.auth.argocd_token

log_ok "ArgoCD installed"

# Provision the ArgoCD Applications for E2E deploy scenarios. Kept in a separate
# script (S5) so the apps can be re-applied without recreating the cluster.
bash "${SCRIPT_DIR}/argocd-apps.sh"
echo ""
echo -e "${BLUE}ArgoCD access:${NC}"
echo "  URL      : https://localhost:${ARGOCD_PORT}"
echo "  Login    : admin"
echo "  Password : ${local_argocd_password}"
echo ""
echo -e "${YELLOW}Note: Port-forward is running in the background.${NC}"
echo -e "${YELLOW}To stop it: kill \$(lsof -t -i:${ARGOCD_PORT})${NC}"
