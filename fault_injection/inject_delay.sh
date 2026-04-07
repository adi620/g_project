#!/bin/bash
# inject_delay.sh
# Injects network delay on the web pod's veth interface inside the KIND node.
# This is the correct path — pod-to-pod traffic on the same node
# goes through veth pairs, NOT through eth0.
#
# Usage: sudo ./inject_delay.sh <delay_ms>

set -euo pipefail

DELAY_MS="${1:-200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[inject_delay] Finding web pod veth interface..."
VETH=$("$SCRIPT_DIR/get_web_veth.sh")
echo "[inject_delay] Target veth: ${VETH}"

# Get node PID for nsenter
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')

# Clear existing rules
nsenter -t "$NODE_PID" -n -- \
    tc qdisc del dev "$VETH" root 2>/dev/null || true

# Inject delay
echo "[inject_delay] Injecting ${DELAY_MS}ms delay on ${VETH} (inside node netns)..."
nsenter -t "$NODE_PID" -n -- \
    tc qdisc add dev "$VETH" root netem delay "${DELAY_MS}ms"

echo "[inject_delay] Verifying:"
nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"

# Quick sanity test
echo "[inject_delay] Sanity ping test (should take ~${DELAY_MS}ms):"
WEB_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
kubectl exec traffic -- sh -c \
    "time wget -q -O /dev/null http://${WEB_IP}/ 2>&1 || true" 2>/dev/null || true

echo "[inject_delay] Done. ${DELAY_MS}ms delay active on web pod veth."
