#!/bin/bash
# inject_delay.sh
# Injects artificial network delay INSIDE the KIND node's network namespace.
# KIND pod-to-pod traffic flows through the node container's eth0,
# NOT through the host bridge — so tc must be applied via nsenter.
#
# Usage: sudo ./inject_delay.sh <delay_ms>

set -euo pipefail

DELAY_MS="${1:-100}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inherit kubeconfig
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[inject_delay] Resolving KIND node PID..."
NODE_PID=$("$SCRIPT_DIR/get_node_pid.sh")
echo "[inject_delay] Node PID: ${NODE_PID}"

# Clear any existing rule first
nsenter -t "$NODE_PID" -n -- tc qdisc del dev eth0 root 2>/dev/null || true

echo "[inject_delay] Injecting ${DELAY_MS}ms delay on node eth0..."
nsenter -t "$NODE_PID" -n -- \
    tc qdisc add dev eth0 root netem delay "${DELAY_MS}ms"

echo "[inject_delay] Verifying:"
nsenter -t "$NODE_PID" -n -- tc qdisc show dev eth0

echo "[inject_delay] Done. ${DELAY_MS}ms delay is now active on pod traffic path."
