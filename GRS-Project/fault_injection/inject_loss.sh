#!/bin/bash
# inject_loss.sh
# Injects packet loss on the web pod's veth interface inside the KIND node.
# Pod-to-pod traffic on the same node goes through veth pairs.
#
# Usage: sudo ./inject_loss.sh <loss_percent>

set -euo pipefail

LOSS_PCT="${1:-20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[inject_loss] Finding web pod veth interface..."
VETH=$("$SCRIPT_DIR/get_web_veth.sh")
echo "[inject_loss] Target veth: ${VETH}"

# Get node PID for nsenter
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')

# Clear existing rules
nsenter -t "$NODE_PID" -n -- \
    tc qdisc del dev "$VETH" root 2>/dev/null || true

# Inject packet loss
echo "[inject_loss] Injecting ${LOSS_PCT}% packet loss on ${VETH} (inside node netns)..."
nsenter -t "$NODE_PID" -n -- \
    tc qdisc add dev "$VETH" root netem loss "${LOSS_PCT}%"

echo "[inject_loss] Verifying:"
nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"

echo "[inject_loss] Done. ${LOSS_PCT}% packet loss active on web pod veth."
