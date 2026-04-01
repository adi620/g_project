#!/bin/bash
# measure_latency.sh
# Measures HTTP response time from the traffic pod to the web service.
# Saves results to a CSV file with timestamps.
# Usage: ./measure_latency.sh <output_csv> <duration_seconds>

set -euo pipefail

OUTPUT_CSV="${1:-/dev/stdout}"
DURATION="${2:-60}"

if [ "$OUTPUT_CSV" != "/dev/stdout" ]; then
    mkdir -p "$(dirname "$OUTPUT_CSV")"
    echo "timestamp,latency_seconds" > "$OUTPUT_CSV"
    echo "[measure] Saving latency to: ${OUTPUT_CSV}"
fi

echo "[measure] Running for ${DURATION} seconds..."

START=$(date +%s)

while true; do
    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "$DURATION" ]; then
        break
    fi

    TIMESTAMP=$(date +%s%3N)   # milliseconds since epoch
    LATENCY=$(kubectl exec traffic -- \
        curl -o /dev/null -s -w "%{time_total}" \
        --max-time 10 web 2>/dev/null || echo "timeout")

    if [ "$OUTPUT_CSV" != "/dev/stdout" ]; then
        echo "${TIMESTAMP},${LATENCY}" >> "$OUTPUT_CSV"
    fi
    echo "[measure] ${TIMESTAMP}  ${LATENCY}s"

    sleep 1
done

echo "[measure] Done."
