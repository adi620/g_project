#!/bin/bash
# clear_rules.sh
# Removes tc netem rules from the web pod's veth inside the KIND node netns.
# Usage: sudo ./clear_rules.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[clear_rules] Finding web pod veth interface..."
VETH=$("$SCRIPT_DIR/get_web_veth.sh") || { echo "[clear_rules] Could not find veth, skipping."; exit 0; }
echo "[clear_rules] Target veth: ${VETH}"

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')

if nsenter -t "$NODE_PID" -n -- tc qdisc del dev "$VETH" root 2>/dev/null; then
    echo "[clear_rules] Rules cleared on ${VETH}."
else
    echo "[clear_rules] No active rules on ${VETH}."
fi
