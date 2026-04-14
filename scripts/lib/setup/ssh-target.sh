#!/usr/bin/env bash
# Generate SSH key pair for E2E deploy tests.
# The public key is mounted into the ssh-target container.
# The private key can be injected as a CI variable for deploy jobs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/../../.."
DATA_DIR="${ROOT_DIR}/data/ssh-target"

mkdir -p "$DATA_DIR"

KEY_FILE="${DATA_DIR}/deploy_key"

if [[ -f "$KEY_FILE" ]]; then
    echo "[INFO] SSH key already exists: ${KEY_FILE}"
    echo "[INFO] To regenerate, delete ${KEY_FILE} and ${KEY_FILE}.pub first."
    exit 0
fi

echo "[INFO] Generating SSH key pair for E2E deploy tests..."
ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "briklab-deploy-e2e"

# Create authorized_keys from the public key
cp "${KEY_FILE}.pub" "${DATA_DIR}/authorized_keys"
chmod 644 "${DATA_DIR}/authorized_keys"

echo "[OK] SSH key pair generated:"
echo "  Private key: ${KEY_FILE}"
echo "  Public key:  ${KEY_FILE}.pub"
echo "  authorized_keys: ${DATA_DIR}/authorized_keys"
echo ""
echo "The private key content can be set as a CI variable (SSH_DEPLOY_KEY)"
echo "for deploy jobs that need SSH access to the ssh-target container."

# Restart container so entrypoint copies the new authorized_keys
if docker ps --format '{{.Names}}' | grep -q "^brik-ssh-target$"; then
    echo "[INFO] Restarting ssh-target container..."
    docker restart brik-ssh-target >/dev/null
    sleep 2
    # Verify SSH connection
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -i "$KEY_FILE" -p "${SSH_TARGET_PORT:-2223}" deploy@localhost echo ok &>/dev/null; then
        echo "[OK] SSH connection verified"
    else
        echo "[WARN] SSH connection failed -- container may need more time"
    fi
fi
