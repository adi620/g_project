#!/bin/bash
# get_web_veth.sh
# Finds the host-side veth interface that corresponds to the web pod's eth0.
#
# Strategy:
#   1. Get the web pod's container ID from kubectl
#   2. Find its PID via docker/crictl inside the KIND node
#   3. Read the ifindex of eth0 inside the pod's netns
#   4. Match that index to the veth on the node side
#
# This is the definitive correct approach for pod-to-pod traffic in KIND.

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

# ── Step 1: Get web pod name and node ────────────────────────
POD_NAME=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD_NAME" ]; then
    echo "ERROR: No web pod found. Is the deployment running?" >&2
    exit 1
fi

NODE_NAME=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}')
echo "[get_web_veth] Pod: ${POD_NAME}  Node: ${NODE_NAME}" >&2

# ── Step 2: Get node container PID ───────────────────────────
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')
echo "[get_web_veth] Node container PID: ${NODE_PID}" >&2

# ── Step 3: Get the container ID of the web pod ──────────────
# crictl is available inside the KIND node — use it via nsenter
CONTAINER_ID=$(nsenter -t "$NODE_PID" -m -u -i -n -p -- \
    crictl ps --label "io.kubernetes.pod.name=${POD_NAME}" \
    --state Running -q 2>/dev/null | head -1)

if [ -z "$CONTAINER_ID" ]; then
    echo "ERROR: Could not find container for pod ${POD_NAME} via crictl" >&2
    exit 1
fi
echo "[get_web_veth] Container ID: ${CONTAINER_ID}" >&2

# ── Step 4: Get the PID of the container process ─────────────
CONTAINER_PID=$(nsenter -t "$NODE_PID" -m -u -i -n -p -- \
    crictl inspect --output go-template \
    --template '{{.info.pid}}' "$CONTAINER_ID" 2>/dev/null)

echo "[get_web_veth] Container PID: ${CONTAINER_PID}" >&2

# ── Step 5: Read ifindex of eth0 inside the pod netns ────────
# The pod's eth0 peer index tells us which veth on the node it's paired with
IFINDEX=$(nsenter -t "$CONTAINER_PID" -n -- \
    cat /sys/class/net/eth0/iflink 2>/dev/null)
echo "[get_web_veth] Pod eth0 peer ifindex: ${IFINDEX}" >&2

# ── Step 6: Find matching veth on the node ───────────────────
VETH=$(nsenter -t "$NODE_PID" -n -- \
    ip link show | awk -F': ' "/^${IFINDEX}:/{print \$2}" | cut -d'@' -f1)

if [ -z "$VETH" ]; then
    echo "ERROR: Could not find veth with ifindex ${IFINDEX} on node" >&2
    exit 1
fi

echo "[get_web_veth] Host-side veth: ${VETH}" >&2
echo "$VETH"
