#!/bin/bash
# experiments/run_cpu_stress.sh
# Starts CPU stress (4 workers) on the node, measures 60s, stops stress.
# Output: results/cpu_stress.csv

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${CPU_DURATION:-60}"
CPU_WORKERS="${CPU_WORKERS:-4}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " CPU STRESS EXPERIMENT"
echo " Workers:  ${CPU_WORKERS} CPU stressors"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/cpu_stress.csv"
echo "========================================"

"${PROJECT_ROOT}/fault_injection/cpu_stress.sh" start "$CPU_WORKERS" "$DURATION"
trap '"${PROJECT_ROOT}/fault_injection/cpu_stress.sh" stop 2>/dev/null || true' EXIT

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/cpu_stress.csv" "$DURATION"
echo "[cpu_stress] Done → ${RESULTS_DIR}/cpu_stress.csv"
