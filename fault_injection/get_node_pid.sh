#!/bin/bash
# get_node_pid.sh
# Returns the host PID of the KIND node container's init process.
# Used by inject_delay.sh, inject_loss.sh, and clear_rules.sh
# to nsenter the node's network namespace — the correct traffic path in KIND.

set -euo pipefail

# Inherit kubeconfig from parent (sudo-safe)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$NODE_NAME" ]; then
    echo "ERROR: No nodes found. Is the KIND cluster running?" >&2
    exit 1
fi

CONTAINER_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}' 2>/dev/null)
if [ -z "$CONTAINER_PID" ] || [ "$CONTAINER_PID" = "0" ]; then
    echo "ERROR: Could not get PID for node container '${NODE_NAME}'" >&2
    exit 1
fi

echo "$CONTAINER_PID"
