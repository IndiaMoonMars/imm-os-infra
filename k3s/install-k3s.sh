#!/bin/bash
# ────────────────────────────────────────────────────────────────────────────
# IMM-OS  ·  K3s Single-Node Install Script
# Target OS : Ubuntu 22.04 LTS (development server)
# Acceptance: kubectl get nodes  →  dev server listed as Ready
# Run as    : non-root user with sudo access
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.28.8+k3s1}"
KUBECONFIG_PATH="${HOME}/.kube/config"

echo "════════════════════════════════════════════════════"
echo "  IMM-OS K3s Installer  ·  ${K3S_VERSION}"
echo "════════════════════════════════════════════════════"

# ── 1. Install K3s ───────────────────────────────────────────────
echo ""
echo "==> [1/4] Installing K3s ${K3S_VERSION}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -

# ── 2. Wait for node Ready ───────────────────────────────────────
echo ""
echo "==> [2/4] Waiting for node to become Ready (up to 2 min)..."
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s

# ── 3. Set up kubeconfig ─────────────────────────────────────────
echo ""
echo "==> [3/4] Configuring kubeconfig at ${KUBECONFIG_PATH}..."
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_PATH}"
sudo chown "$(id -u):$(id -g)" "${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"

# Replace 127.0.0.1 with the node's LAN IP so remote kubectl works
NODE_IP=$(hostname -I | awk '{print $1}')
sed -i "s/127.0.0.1/${NODE_IP}/g" "${KUBECONFIG_PATH}"
echo "   Node IP: ${NODE_IP}"

# ── 4. Verify ─────────────────────────────────────────────────────
echo ""
echo "==> [4/4] Verification..."
export KUBECONFIG="${KUBECONFIG_PATH}"
kubectl get nodes -o wide

echo ""
echo "════════════════════════════════════════════════════"
echo "  ✓ K3s installed successfully!"
echo "  Run: kubectl get nodes"
echo "════════════════════════════════════════════════════"
