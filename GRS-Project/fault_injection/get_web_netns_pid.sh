#!/bin/bash
# get_web_netns_pid.sh
# Finds the PID (on the HOST) of the nginx process running inside the web pod.
# This PID can be used with `nsenter -t <PID> -n` to enter the pod's
# network namespace and apply tc rules directly on the pod's loopback/eth0.
#
# Method: purely /proc-based — no crictl label bugs, no hardcoding.
#   1. Get the web pod IP from kubectl
#   2. Get the KIND node container PID
#   3. Walk /proc/<pid>/net/fib_trie inside the node to find which PID
#      has a network namespace containing that pod IP
#   4. Return that PID

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

# ── 1. Get web pod IP ─────────────────────────────────────────
POD_IP=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$POD_IP" ]; then
    echo "ERROR: Could not get web pod IP. Is the pod Running?" >&2
    exit 1
fi
echo "[get_web_netns_pid] Web pod IP: ${POD_IP}" >&2

# ── 2. Get KIND node name and its host PID ────────────────────
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}' 2>/dev/null)

if [ -z "$NODE_PID" ] || [ "$NODE_PID" = "0" ]; then
    echo "ERROR: Could not get node PID. Is the KIND cluster running?" >&2
    exit 1
fi
echo "[get_web_netns_pid] Node: ${NODE_NAME}  PID: ${NODE_PID}" >&2

# ── 3. Convert pod IP to hex for /proc/net/fib_trie search ───
# fib_trie stores IPs in hex, little-endian on some kernels.
# We search both the direct address file and tcp socket list.
# Simplest reliable method: find PID whose /proc/<pid>/net/if_inet6
# or /proc/<pid>/net/fib_trie contains the pod IP.

# Walk all PIDs under the node's /proc to find one that "owns" the pod IP.
# We use the node PID's mount namespace to access the right /proc.
FOUND_PID=""

# All child PIDs of the node container share its PID namespace on the host.
# We scan /proc for PIDs whose net namespace contains the pod IP.
for pid_dir in /proc/*/net/fib_trie; do
    pid=$(echo "$pid_dir" | cut -d'/' -f3)
    # Skip non-numeric
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Check if this netns has our pod IP
    if grep -q "$POD_IP" "$pid_dir" 2>/dev/null; then
        # Confirm it's a process inside the KIND node (same parent namespace)
        # by checking the net namespace symlink
        NET_NS=$(readlink "/proc/${pid}/ns/net" 2>/dev/null || true)
        NODE_NS=$(readlink "/proc/${NODE_PID}/ns/net" 2>/dev/null || true)
        # Must be a DIFFERENT netns from the node (it's the pod's own netns)
        if [ -n "$NET_NS" ] && [ "$NET_NS" != "$NODE_NS" ]; then
            FOUND_PID="$pid"
            break
        fi
    fi
done

if [ -z "$FOUND_PID" ]; then
    echo "ERROR: Could not find a process with pod IP ${POD_IP} in /proc" >&2
    echo "Falling back to node PID namespace scan..." >&2

    # Fallback: nsenter into node and find nginx PID there
    FOUND_PID=$(nsenter -t "$NODE_PID" -m -u -i -n -p -- \
        pgrep -x nginx 2>/dev/null | head -1 || true)

    if [ -z "$FOUND_PID" ]; then
        echo "ERROR: Fallback also failed." >&2
        exit 1
    fi
    # Map node-namespace PID to host PID via /proc/<node_pid>/root/proc
    echo "[get_web_netns_pid] Found nginx PID inside node: ${FOUND_PID}" >&2
    # The host PID for a process in a container = read NSpid from /proc
    FOUND_PID=$(grep -m1 'NSpid' /proc/*/status 2>/dev/null \
        | awk -F'\t' -v p="$FOUND_PID" '$NF==p{split($0,a,"/"); print a[3]}' \
        | head -1)
fi

echo "[get_web_netns_pid] Host PID for web pod netns: ${FOUND_PID}" >&2
echo "$FOUND_PID"
