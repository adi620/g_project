#!/bin/bash
# experiments/run_delay.sh
# Injects 100ms network delay, measures latency for 60s, then clears fault.
# Output: results/delay.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${DELAY_DURATION:-60}"
DELAY_MS="${DELAY_MS:-100}"

mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " DELAY EXPERIMENT"
echo " Delay:    ${DELAY_MS}ms"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/delay.csv"
echo "========================================"

# Inject delay fault
"${PROJECT_ROOT}/fault_injection/inject_delay.sh" "$DELAY_MS"

# Measure under fault
bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/delay.csv" \
    "$DURATION"

# Always clean up, even on error
"${PROJECT_ROOT}/fault_injection/clear_rules.sh"

echo "[delay] Complete. Results in ${RESULTS_DIR}/delay.csv"
