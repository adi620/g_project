#!/bin/bash
# clear_rules.sh
# Removes all tc netem rules from the KIND node's network namespace.
# Usage: sudo ./clear_rules.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inherit kubeconfig
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[clear_rules] Resolving KIND node PID..."
NODE_PID=$("$SCRIPT_DIR/get_node_pid.sh")
echo "[clear_rules] Node PID: ${NODE_PID}"

if nsenter -t "$NODE_PID" -n -- tc qdisc del dev eth0 root 2>/dev/null; then
    echo "[clear_rules] tc rules cleared from node eth0."
else
    echo "[clear_rules] No active tc rules found on node eth0."
fi
