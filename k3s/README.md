# K3s Setup — IMM-OS Dev Server

Lightweight Kubernetes (K3s) single-node cluster for the IMM-OS development environment.

## Prerequisites

- Ubuntu 22.04 LTS on the dev server
- User with `sudo` access
- Internet connectivity

## Install

```bash
chmod +x install-k3s.sh
./install-k3s.sh
```

### Acceptance Criteria (Phase 0 Step 4)

```bash
kubectl get nodes
# NAME        STATUS   ROLES                  AGE   VERSION
# dev-server  Ready    control-plane,master   1m    v1.28.8+k3s1
```

## Uninstall

```bash
chmod +x uninstall-k3s.sh
./uninstall-k3s.sh
```

## Notes

- K3s version is pinned via `K3S_VERSION` env var (default: `v1.28.8+k3s1`)
- kubeconfig is written to `~/.kube/config` with the node's LAN IP
- Traefik ingress controller is included by default (replaces Nginx for K8s traffic)
- In Phase 1, Helm charts for IMM-OS services will be added here
