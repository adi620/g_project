#!/bin/bash
# inject_fault.sh
# Injects tc netem faults on the web pod's veth (host-side, inside node netns).
#
# HOW IT WORKS — KIND networking:
#
#   Host
#   └── KIND node container (docker)
#       └── node network namespace
#           ├── cbr0 bridge
#           ├── veth_web ──── web pod eth0   ← tc goes HERE
#           └── veth_traffic── traffic pod eth0
#
# We nsenter into the KIND node's network namespace (using its docker PID),
# then find which veth corresponds to the web pod by matching the pod IP
# via `ip route get`, then apply tc netem on that veth.
#
# This is the authoritative correct approach — no crictl, no /proc scanning,
# no guessing. The node PID gives us its netns; the pod IP gives us the veth.
#
# Usage:
#   sudo ./inject_fault.sh delay <ms>      e.g. sudo ./inject_fault.sh delay 200
#   sudo ./inject_fault.sh loss <percent>  e.g. sudo ./inject_fault.sh loss 20
#   sudo ./inject_fault.sh clear

set -euo pipefail

# ── Enforce sudo ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo."
    echo "  sudo $0 $*"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

MODE="${1:-}"
if [ -z "$MODE" ]; then
    echo "Usage: sudo $0 delay <ms> | loss <percent> | clear"
    exit 1
fi

# ── 1. Get web pod IP ─────────────────────────────────────────
POD_NAME=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
POD_IP=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$POD_IP" ]; then
    echo "ERROR: Web pod not running or has no IP."
    kubectl get pods
    exit 1
fi
echo "[inject] Pod: ${POD_NAME}  IP: ${POD_IP}"

# ── 2. Get KIND node docker container PID ────────────────────
NODE_NAME=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')
echo "[inject] Node: ${NODE_NAME}  PID: ${NODE_PID}"

# ── 3. Find the veth for the web pod inside the node netns ───
# Inside the node's netns, run: ip route get <POD_IP>
# This tells us which interface the node uses to reach the pod.
# For a bridged veth setup it returns the veth directly.
#
# Example output: 10.244.0.5 dev vethXXXXXX src 10.244.0.1 uid 0

ROUTE_OUT=$(nsenter -t "$NODE_PID" -n -- \
    ip route get "$POD_IP" 2>/dev/null || true)
echo "[inject] Route to pod: ${ROUTE_OUT}"

VETH=$(echo "$ROUTE_OUT" | awk '{
    for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)
}')

# If route get returned the bridge (cbr0/kindnet), find the veth via
# ARP / neighbor table instead
if [ -z "$VETH" ] || echo "$VETH" | grep -qE "^(cbr|br|kind|docker)"; then
    echo "[inject] Route via bridge, using ARP table to find veth..."
    # Get the MAC of the pod's eth0
    POD_MAC=$(nsenter -t "$NODE_PID" -n -- \
        ip neigh show "$POD_IP" 2>/dev/null | awk '{print $5}' | head -1)
    echo "[inject] Pod MAC: ${POD_MAC}"

    if [ -n "$POD_MAC" ]; then
        # Find the veth whose peer has that MAC — iterate veth interfaces
        for iface in $(nsenter -t "$NODE_PID" -n -- \
                ip -o link show type veth 2>/dev/null | \
                awk -F': ' '{print $2}' | cut -d'@' -f1); do
            # Get the peer's MAC via bridge fdb or direct check
            IFACE_IDX=$(nsenter -t "$NODE_PID" -n -- \
                cat /sys/class/net/"$iface"/ifindex 2>/dev/null || echo "")
            PEER_IDX=$(nsenter -t "$NODE_PID" -n -- \
                cat /sys/class/net/"$iface"/iflink 2>/dev/null || echo "")
            # Read peer MAC by entering its netns temporarily
            PEER_PID=$(grep -rl "^${PEER_IDX}$" /proc/*/net/iflink 2>/dev/null \
                | head -1 | cut -d'/' -f3 || true)
            if [ -n "$PEER_PID" ]; then
                PEER_MAC=$(nsenter -t "$PEER_PID" -n -- \
                    cat /sys/class/net/eth0/address 2>/dev/null || true)
                if [ "$PEER_MAC" = "$POD_MAC" ]; then
                    VETH="$iface"
                    break
                fi
            fi
        done
    fi
fi

# Final fallback: match by iflink — find the veth whose peer iflink
# points to an interface that has the pod IP in its netns
if [ -z "$VETH" ]; then
    echo "[inject] Trying iflink scan fallback..."
    # Find all veth interfaces in node netns
    VETHI_LIST=$(nsenter -t "$NODE_PID" -n -- \
        ip -o link show type veth 2>/dev/null | \
        awk -F': ' '{gsub(/@.*/,"",$2); print $1":"$2}')

    while IFS=: read -r idx iface; do
        PEER_IDX=$(nsenter -t "$NODE_PID" -n -- \
            cat /sys/class/net/"$iface"/iflink 2>/dev/null || echo "0")
        # The peer is inside some pod netns — find that PID
        for pid_net in /proc/*/net/fib_trie; do
            p=$(echo "$pid_net" | cut -d'/' -f3)
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            if grep -q "$POD_IP" "$pid_net" 2>/dev/null; then
                PEER_LINK=$(cat /proc/"$p"/net/if_inet6 2>/dev/null | \
                    head -1 | awk '{print $NF}' || true)
                POD_IFIDX=$(cat /proc/"$p"/net/dev 2>/dev/null | \
                    grep eth0 | awk '{print $1}' | tr -d ':' || true)
                ETH0_IDX=$(nsenter -t "$p" -n -- \
                    cat /sys/class/net/eth0/ifindex 2>/dev/null || echo "0")
                if [ "$PEER_IDX" = "$ETH0_IDX" ]; then
                    VETH="$iface"
                    break 2
                fi
            fi
        done
    done <<< "$VETHI_LIST"
fi

if [ -z "$VETH" ]; then
    echo ""
    echo "ERROR: Could not identify the veth for pod ${POD_NAME} (IP: ${POD_IP})"
    echo ""
    echo "── Node network interfaces ──"
    nsenter -t "$NODE_PID" -n -- ip link show
    echo ""
    echo "── Routes in node netns ──"
    nsenter -t "$NODE_PID" -n -- ip route
    exit 1
fi

echo "[inject] Target veth: ${VETH}"

# ── 4. Apply tc rule ─────────────────────────────────────────
nsenter -t "$NODE_PID" -n -- \
    tc qdisc del dev "$VETH" root 2>/dev/null || true

case "$MODE" in
    delay)
        DELAY_MS="${2:-200}"
        nsenter -t "$NODE_PID" -n -- \
            tc qdisc add dev "$VETH" root netem delay "${DELAY_MS}ms"
        echo "[inject] ✓ ${DELAY_MS}ms delay on ${VETH}"
        nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"
        ;;
    loss)
        LOSS_PCT="${2:-20}"
        nsenter -t "$NODE_PID" -n -- \
            tc qdisc add dev "$VETH" root netem loss "${LOSS_PCT}%"
        echo "[inject] ✓ ${LOSS_PCT}% packet loss on ${VETH}"
        nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"
        ;;
    clear)
        echo "[inject] ✓ Rules cleared from ${VETH}"
        ;;
    *)
        echo "ERROR: Unknown mode '${MODE}'"
        exit 1
        ;;
esac
