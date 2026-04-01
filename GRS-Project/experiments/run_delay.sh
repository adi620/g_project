#!/bin/bash
# experiments/run_delay.sh
# Injects 200ms delay on the web pod's eth0, measures 60s, clears fault.

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${DELAY_DURATION:-60}"
DELAY_MS="${DELAY_MS:-200}"

mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " DELAY EXPERIMENT"
echo " Delay:    ${DELAY_MS}ms on web pod eth0"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/delay.csv"
echo "========================================"

# Inject delay
"${PROJECT_ROOT}/fault_injection/inject_fault.sh" delay "$DELAY_MS"

# Measure under fault — cleanup runs even if measurement fails
trap '"${PROJECT_ROOT}/fault_injection/inject_fault.sh" clear 2>/dev/null || true' EXIT

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/delay.csv" "$DURATION"

echo "[delay] Done → ${RESULTS_DIR}/delay.csv"
