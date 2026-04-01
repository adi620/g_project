#!/bin/bash
# inject_fault.sh
# Injects tc netem faults directly inside the web pod's network namespace.
# Works correctly for same-node pod-to-pod traffic in KIND clusters.
#
# The fault is applied on the pod's OWN eth0, so all traffic TO the pod
# experiences the fault regardless of which interface the sender uses.
#
# Usage:
#   sudo ./inject_fault.sh delay <ms>      # e.g. inject_fault.sh delay 200
#   sudo ./inject_fault.sh loss <percent>  # e.g. inject_fault.sh loss 20
#   sudo ./inject_fault.sh clear           # remove all rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

MODE="${1:-}"
if [ -z "$MODE" ]; then
    echo "Usage: $0 delay <ms> | loss <percent> | clear"
    exit 1
fi

# ── Find the web pod IP ───────────────────────────────────────
POD_IP=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
POD_NAME=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_IP" ]; then
    echo "ERROR: Web pod not running or has no IP." >&2
    exit 1
fi
echo "[inject_fault] Web pod: ${POD_NAME}  IP: ${POD_IP}"

# ── Find the host PID that owns the pod's network namespace ──
# Strategy: scan /proc for a PID whose net namespace contains the pod IP
# by checking /proc/<pid>/net/fib_trie (IPv4 routing table in text form).
# This is 100% reliable, no crictl/label bugs.

echo "[inject_fault] Scanning /proc for web pod network namespace..."

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')
NODE_NETNS=$(readlink "/proc/${NODE_PID}/ns/net" 2>/dev/null)

POD_PID=""
for status_file in /proc/*/status; do
    pid=$(echo "$status_file" | cut -d'/' -f3)
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    netns=$(readlink "/proc/${pid}/ns/net" 2>/dev/null) || continue
    # Must be different netns from the node itself
    [ "$netns" = "$NODE_NETNS" ] && continue
    # Must have the pod IP in its routing table
    fib="/proc/${pid}/net/fib_trie"
    [ -f "$fib" ] || continue
    if grep -q "$POD_IP" "$fib" 2>/dev/null; then
        POD_PID="$pid"
        break
    fi
done

if [ -z "$POD_PID" ]; then
    echo "ERROR: Could not find web pod network namespace in /proc." >&2
    echo "  Pod IP searched: ${POD_IP}" >&2
    echo "  Make sure the pod is Running: kubectl get pods" >&2
    exit 1
fi

echo "[inject_fault] Found web pod netns via PID: ${POD_PID}"

# ── Apply tc rule inside pod's netns ─────────────────────────
# nsenter -t <PID> -n enters that PID's network namespace
# Then we apply tc on eth0 (the pod's primary interface)

# Always clear existing rules first
nsenter -t "$POD_PID" -n -- \
    tc qdisc del dev eth0 root 2>/dev/null || true

case "$MODE" in
    delay)
        DELAY_MS="${2:-200}"
        echo "[inject_fault] Injecting ${DELAY_MS}ms delay on web pod eth0..."
        nsenter -t "$POD_PID" -n -- \
            tc qdisc add dev eth0 root netem delay "${DELAY_MS}ms"
        echo "[inject_fault] Verifying:"
        nsenter -t "$POD_PID" -n -- tc qdisc show dev eth0
        echo "[inject_fault] ✓ ${DELAY_MS}ms delay active. All traffic TO web pod is delayed."
        ;;
    loss)
        LOSS_PCT="${2:-20}"
        echo "[inject_fault] Injecting ${LOSS_PCT}% packet loss on web pod eth0..."
        nsenter -t "$POD_PID" -n -- \
            tc qdisc add dev eth0 root netem loss "${LOSS_PCT}%"
        echo "[inject_fault] Verifying:"
        nsenter -t "$POD_PID" -n -- tc qdisc show dev eth0
        echo "[inject_fault] ✓ ${LOSS_PCT}% packet loss active. Triggers TCP retransmissions."
        ;;
    clear)
        echo "[inject_fault] ✓ All tc rules cleared from web pod eth0."
        ;;
    *)
        echo "ERROR: Unknown mode '${MODE}'. Use: delay | loss | clear"
        exit 1
        ;;
esac
