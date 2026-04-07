#!/bin/bash
# experiments/run_reordering.sh
# Injects 25% packet reordering with 100ms base delay, measures 60s, clears fault.
# Output: results/reordering.csv

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${REORDER_DURATION:-60}"
DELAY_MS="${REORDER_DELAY_MS:-100}"
REORDER_PCT="${REORDER_PCT:-25}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " REORDERING EXPERIMENT"
echo " Reorder:  ${REORDER_PCT}% + ${DELAY_MS}ms delay on web pod veth"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/reordering.csv"
echo "========================================"

"${PROJECT_ROOT}/fault_injection/reordering.sh" inject "$DELAY_MS" "$REORDER_PCT"
trap '"${PROJECT_ROOT}/fault_injection/reordering.sh" clear 2>/dev/null || true' EXIT

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/reordering.csv" "$DURATION"
echo "[reordering] Done → ${RESULTS_DIR}/reordering.csv"
