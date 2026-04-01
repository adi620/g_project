#!/bin/bash
# inject_loss.sh
# Injects artificial packet loss on the KIND bridge interface.
# Usage: ./inject_loss.sh <loss_percent>

set -euo pipefail

LOSS_PCT="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[inject_loss] Discovering KIND bridge interface..."
IFACE=$("$SCRIPT_DIR/get_interface.sh")
echo "[inject_loss] Using interface: ${IFACE}"

# Clear any existing qdisc first
sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true

echo "[inject_loss] Injecting ${LOSS_PCT}% packet loss on ${IFACE}..."
sudo tc qdisc add dev "$IFACE" root netem loss "${LOSS_PCT}%"

echo "[inject_loss] Verifying rule:"
sudo tc qdisc show dev "$IFACE"

echo "[inject_loss] Done. Packet loss of ${LOSS_PCT}% is now active."
