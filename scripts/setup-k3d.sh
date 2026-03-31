#!/usr/bin/env bash
# k3d cluster creation + ArgoCD installation
set -euo pipefail

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

# Create the k3d cluster
log_info "Creating k3d cluster '${CLUSTER_NAME}'..."

k3d cluster create "$CLUSTER_NAME" \
    --api-port "${K3D_API_PORT}" \
    --port "${K3D_HTTP_PORT}:80@loadbalancer" \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --network "brik-net" \
    --registry-use "brik-registry:5000" \
    --wait

log_ok "k3d cluster created"

# Verify the cluster
log_info "Verifying cluster..."
kubectl cluster-info
kubectl get nodes

# Install ArgoCD
log_info "Installing ArgoCD..."

kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
log_info "Waiting for ArgoCD (may take 1-2 min)..."
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd

# Patch the service for NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# Background port-forward
log_info "Starting ArgoCD port-forward on :${ARGOCD_PORT}..."
nohup kubectl port-forward svc/argocd-server -n argocd "${ARGOCD_PORT}:443" &>/dev/null &

# Retrieve admin password
local_argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

log_ok "ArgoCD installed"
echo ""
echo -e "${BLUE}ArgoCD access:${NC}"
echo "  URL      : https://localhost:${ARGOCD_PORT}"
echo "  Login    : admin"
echo "  Password : ${local_argocd_password}"
echo ""
echo -e "${YELLOW}Note: Port-forward is running in the background.${NC}"
echo -e "${YELLOW}To stop it: kill \$(lsof -t -i:${ARGOCD_PORT})${NC}"
