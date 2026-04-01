#!/bin/bash
# inject_loss.sh
# Injects artificial packet loss INSIDE the KIND node's network namespace.
# KIND pod-to-pod traffic flows through the node container's eth0,
# NOT through the host bridge — so tc must be applied via nsenter.
#
# Usage: sudo ./inject_loss.sh <loss_percent>

set -euo pipefail

LOSS_PCT="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inherit kubeconfig
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[inject_loss] Resolving KIND node PID..."
NODE_PID=$("$SCRIPT_DIR/get_node_pid.sh")
echo "[inject_loss] Node PID: ${NODE_PID}"

# Clear any existing rule first
nsenter -t "$NODE_PID" -n -- tc qdisc del dev eth0 root 2>/dev/null || true

echo "[inject_loss] Injecting ${LOSS_PCT}% packet loss on node eth0..."
nsenter -t "$NODE_PID" -n -- \
    tc qdisc add dev eth0 root netem loss "${LOSS_PCT}%"

echo "[inject_loss] Verifying:"
nsenter -t "$NODE_PID" -n -- tc qdisc show dev eth0

echo "[inject_loss] Done. ${LOSS_PCT}% packet loss is now active on pod traffic path."
