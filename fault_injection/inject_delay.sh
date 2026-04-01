#!/bin/bash
# inject_delay.sh
# Injects artificial network delay on the KIND bridge interface.
# Usage: ./inject_delay.sh <delay_ms>

set -euo pipefail

DELAY_MS="${1:-100}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[inject_delay] Discovering KIND bridge interface..."
IFACE=$("$SCRIPT_DIR/get_interface.sh")
echo "[inject_delay] Using interface: ${IFACE}"

# Clear any existing qdisc first to avoid 'already exists' errors
sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true

echo "[inject_delay] Injecting ${DELAY_MS}ms delay on ${IFACE}..."
sudo tc qdisc add dev "$IFACE" root netem delay "${DELAY_MS}ms"

echo "[inject_delay] Verifying rule:"
sudo tc qdisc show dev "$IFACE"

echo "[inject_delay] Done. Delay of ${DELAY_MS}ms is now active."
