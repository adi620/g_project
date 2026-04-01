#!/bin/bash
# get_interface.sh
# Discovers the stable KIND bridge interface for fault injection.
# KIND uses a Linux bridge (kind) that is consistent across runs.
# Falls back to finding the docker bridge if needed.

set -euo pipefail

# The KIND default bridge name is always "kind" (br-xxxxxx maps to network "kind")
# We resolve it via docker network inspect for full reproducibility.

NETWORK_NAME="${KIND_NETWORK:-kind}"

BRIDGE_ID=$(docker network inspect "$NETWORK_NAME" --format '{{.Id}}' 2>/dev/null | cut -c1-12)

if [ -z "$BRIDGE_ID" ]; then
    echo "ERROR: Could not find docker network '${NETWORK_NAME}'. Is KIND running?" >&2
    exit 1
fi

IFACE="br-${BRIDGE_ID}"

if ! ip link show "$IFACE" &>/dev/null; then
    echo "ERROR: Interface ${IFACE} not found on host. Is the KIND cluster up?" >&2
    exit 1
fi

echo "$IFACE"
