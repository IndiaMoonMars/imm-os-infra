#!/bin/bash
# ────────────────────────────────────────────────────────────────
# IMM-OS  ·  K3s Uninstall Script
# Removes K3s and all associated data from the dev server.
# ────────────────────────────────────────────────────────────────
set -euo pipefail

echo "==> Uninstalling K3s..."

if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    sudo /usr/local/bin/k3s-uninstall.sh
else
    echo "WARN: k3s-uninstall.sh not found. K3s may not be installed."
fi

echo "==> Removing kubeconfig..."
rm -f "${HOME}/.kube/config"

echo "✓ K3s uninstalled."
