#!/bin/bash
# clear_rules.sh
# Removes all tc netem rules from the KIND bridge interface.
# Usage: ./clear_rules.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[clear_rules] Discovering KIND bridge interface..."
IFACE=$("$SCRIPT_DIR/get_interface.sh")
echo "[clear_rules] Using interface: ${IFACE}"

if sudo tc qdisc del dev "$IFACE" root 2>/dev/null; then
    echo "[clear_rules] Rules cleared on ${IFACE}."
else
    echo "[clear_rules] No active rules to clear on ${IFACE}."
fi
