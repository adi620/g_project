#!/bin/bash
# experiments/run_bandwidth.sh
# Limits bandwidth to 1mbit on web pod veth, measures 60s, clears fault.
# Output: results/bandwidth.csv

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${BW_DURATION:-60}"
BW_RATE="${BW_RATE:-1mbit}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " BANDWIDTH EXPERIMENT"
echo " Rate:     ${BW_RATE} on web pod veth"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/bandwidth.csv"
echo "========================================"

"${PROJECT_ROOT}/fault_injection/bandwidth.sh" inject "$BW_RATE"
trap '"${PROJECT_ROOT}/fault_injection/bandwidth.sh" clear 2>/dev/null || true' EXIT

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/bandwidth.csv" "$DURATION"
echo "[bandwidth] Done → ${RESULTS_DIR}/bandwidth.csv"
