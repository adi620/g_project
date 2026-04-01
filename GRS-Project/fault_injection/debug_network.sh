#!/bin/bash
# debug_network.sh
# Verifies the entire fault injection chain step by step.
# Run this BEFORE the full pipeline to confirm tc rules are working.
#
# Usage: sudo ./debug_network.sh

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

kubectl config use-context "kind-${KIND_CLUSTER:-grs}" 2>/dev/null || true

echo "════════════════════════════════════════════"
echo " Network Fault Injection Debug Tool"
echo "════════════════════════════════════════════"

echo ""
echo "── Pod status ──"
kubectl get pods -o wide

WEB_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
echo ""
echo "── Baseline latency (3 requests, should be ~1-5ms) ──"
for i in 1 2 3; do
    kubectl exec traffic -- curl -s -o /dev/null -w "  Request ${i}: %{time_total}s\n" \
        --max-time 10 http://web/
done

echo ""
echo "── Injecting 500ms delay ──"
"${SCRIPT_DIR}/inject_fault.sh" delay 500

echo ""
echo "── Latency WITH 500ms delay (should be ~500ms+) ──"
for i in 1 2 3; do
    kubectl exec traffic -- curl -s -o /dev/null -w "  Request ${i}: %{time_total}s\n" \
        --max-time 15 http://web/
done

echo ""
echo "── Clearing fault ──"
"${SCRIPT_DIR}/inject_fault.sh" clear

echo ""
echo "── Latency AFTER clear (should be ~1-5ms again) ──"
for i in 1 2 3; do
    kubectl exec traffic -- curl -s -o /dev/null -w "  Request ${i}: %{time_total}s\n" \
        --max-time 10 http://web/
done

echo ""
echo "── Test complete ──"
echo "If delay requests showed ~500ms, fault injection is working correctly."
echo "If all requests showed ~1-5ms, fault injection is NOT affecting traffic."
