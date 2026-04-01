#!/bin/bash
# experiments/run_loss.sh
# Injects 10% packet loss, measures latency for 60s, then clears fault.
# Output: results/loss.csv

set -euo pipefail

# Inherit kubeconfig from parent (sudo-safe)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${LOSS_DURATION:-60}"
LOSS_PCT="${LOSS_PCT:-20}"

mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " PACKET LOSS EXPERIMENT"
echo " Loss:     ${LOSS_PCT}%"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/loss.csv"
echo "========================================"

# Inject loss fault
"${PROJECT_ROOT}/fault_injection/inject_loss.sh" "$LOSS_PCT"

# Measure under fault
bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/loss.csv" \
    "$DURATION"

# Always clean up
"${PROJECT_ROOT}/fault_injection/clear_rules.sh"

echo "[loss] Complete. Results in ${RESULTS_DIR}/loss.csv"
