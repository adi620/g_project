#!/bin/bash
# experiments/run_baseline.sh
# Runs a 60-second baseline latency measurement with no faults injected.
# Output: results/baseline.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${BASELINE_DURATION:-60}"

mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " BASELINE EXPERIMENT"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/baseline.csv"
echo "========================================"

# Ensure no leftover fault rules
"${PROJECT_ROOT}/fault_injection/clear_rules.sh" 2>/dev/null || true

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/baseline.csv" \
    "$DURATION"

echo "[baseline] Complete. Results in ${RESULTS_DIR}/baseline.csv"
