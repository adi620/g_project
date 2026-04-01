#!/bin/bash
# experiments/run_baseline.sh
# 60-second baseline — no faults, clean latency measurement.

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${BASELINE_DURATION:-60}"

mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " BASELINE EXPERIMENT (no faults)"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/baseline.csv"
echo "========================================"

# Ensure no leftover fault rules from previous runs
"${PROJECT_ROOT}/fault_injection/inject_fault.sh" clear 2>/dev/null || true

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/baseline.csv" "$DURATION"

echo "[baseline] Done → ${RESULTS_DIR}/baseline.csv"
