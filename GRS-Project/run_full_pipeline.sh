#!/bin/bash
# run_full_pipeline.sh
# Complete experiment pipeline:
#   Deploy → Baseline → Delay Fault → Loss Fault → Results
#
# Usage: sudo ./run_full_pipeline.sh
# sudo is required for: bpftrace (eBPF), nsenter + tc (fault injection)

set -euo pipefail

# ── SUDO-SAFE KUBECONFIG ──────────────────────────────────────
# sudo resets $HOME to /root; we recover the real user's kubeconfig.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

if [ ! -f "$KUBECONFIG" ]; then
    echo "ERROR: kubeconfig not found at ${KUBECONFIG}"
    echo "Please run as the user who created the KIND cluster."
    exit 1
fi

# ── SET KUBECTL CONTEXT ───────────────────────────────────────
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

echo "Switching kubectl context → ${KIND_CONTEXT}"
if ! kubectl config use-context "$KIND_CONTEXT" 2>/dev/null; then
    echo "ERROR: Context '${KIND_CONTEXT}' not found."
    echo "Available contexts:"
    kubectl config get-contexts 2>/dev/null || true
    echo ""
    echo "Available KIND clusters:"
    kind get clusters 2>/dev/null || true
    echo ""
    echo "Tip: KIND_CLUSTER=<name> sudo ./run_full_pipeline.sh"
    exit 1
fi

# ── VERIFY API SERVER ─────────────────────────────────────────
echo "Verifying Kubernetes API server..."
for i in $(seq 1 6); do
    if kubectl cluster-info &>/dev/null; then
        echo "✓ API server reachable."
        break
    fi
    [ "$i" -eq 6 ] && { echo "ERROR: API server unreachable after 30s."; exit 1; }
    echo "  Waiting... (attempt ${i}/6)"
    sleep 5
done

# ── PATHS ─────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${PROJECT_ROOT}/results"
mkdir -p "$RESULTS"

# Log everything to file AND terminal
exec > >(tee -a "${RESULTS}/pipeline.log") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   GRS — Kubernetes eBPF Networking Fault Diagnosis   ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Started:    $(date)"
echo "║  Cluster:    ${KIND_CLUSTER}"
echo "║  Kubeconfig: ${KUBECONFIG}"
echo "╚══════════════════════════════════════════════════════╝"

# ── STEP 1: DEPLOY ───────────────────────────────────────────
echo ""
echo "══ [1/7] Deploy workloads ════════════════════════════"

# Deployment and Service can be applied normally (supports rolling update)
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-deployment.yaml"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-service.yaml"

# Pods (not Deployments) are immutable after creation — you cannot patch
# spec.containers[*].command/args on a running pod.
# Solution: always delete + recreate the traffic pod to pick up any changes.
echo "Recreating traffic pod (pods are immutable, delete+create is required)..."
kubectl delete pod traffic --ignore-not-found=true
kubectl apply --validate=false -f "${PROJECT_ROOT}/traffic/traffic.yaml"

echo "Waiting for pods to be Ready..."
kubectl wait --for=condition=ready pod -l app=web  --timeout=120s
kubectl wait --for=condition=ready pod/traffic      --timeout=120s

echo ""
kubectl get pods -o wide
echo ""

# ── STEP 2: CONNECTIVITY CHECK ───────────────────────────────
echo "══ [2/7] Connectivity check ══════════════════════════"
HTTP_CODE=$(kubectl exec traffic -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://web/ 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ HTTP ${HTTP_CODE} — traffic pod can reach web pod."
else
    echo "ERROR: Expected HTTP 200 from web service, got: ${HTTP_CODE}"
    exit 1
fi

# Show pod IPs for reference
WEB_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
TRAFFIC_IP=$(kubectl get pod traffic -o jsonpath='{.status.podIP}')
echo "  Web pod IP:     ${WEB_IP}"
echo "  Traffic pod IP: ${TRAFFIC_IP}"

# ── STEP 3: START eBPF TRACING ───────────────────────────────
echo ""
echo "══ [3/7] Start eBPF tracing (background) ════════════"
bpftrace "${PROJECT_ROOT}/ebpf/tcp_retransmissions.bt" \
    > "${RESULTS}/retransmissions.log" 2>&1 &
RETRANS_PID=$!

bpftrace "${PROJECT_ROOT}/ebpf/packet_drops.bt" \
    > "${RESULTS}/packet_drops.log" 2>&1 &
DROPS_PID=$!

echo "  retransmissions tracer PID: ${RETRANS_PID}"
echo "  packet_drops tracer PID:    ${DROPS_PID}"
echo "  Waiting 3s for probes to attach..."
sleep 3

# Cleanup eBPF on any exit
cleanup_ebpf() {
    echo ""
    echo "Stopping eBPF tracers..."
    kill "$RETRANS_PID" 2>/dev/null || true
    kill "$DROPS_PID"   2>/dev/null || true
    wait "$RETRANS_PID" 2>/dev/null || true
    wait "$DROPS_PID"   2>/dev/null || true
    echo "eBPF tracers stopped."
}
trap cleanup_ebpf EXIT

# ── STEP 4: BASELINE ─────────────────────────────────────────
echo ""
echo "══ [4/7] Baseline experiment (60s, no faults) ════════"
bash "${PROJECT_ROOT}/experiments/run_baseline.sh"

# ── STEP 5: DELAY EXPERIMENT ─────────────────────────────────
echo ""
echo "══ [5/7] Delay experiment (200ms, 60s) ═══════════════"
bash "${PROJECT_ROOT}/experiments/run_delay.sh"

# ── STEP 6: PACKET LOSS EXPERIMENT ───────────────────────────
echo ""
echo "══ [6/7] Packet loss experiment (20%, 60s) ═══════════"
bash "${PROJECT_ROOT}/experiments/run_loss.sh"

# ── STEP 7: SUMMARY ──────────────────────────────────────────
echo ""
echo "══ [7/7] Results summary ═════════════════════════════"
echo ""

for csv in baseline delay loss; do
    FILE="${RESULTS}/${csv}.csv"
    if [ -f "$FILE" ]; then
        COUNT=$(tail -n +2 "$FILE" | grep -v timeout | wc -l)
        # Compute mean using awk
        MEAN=$(tail -n +2 "$FILE" | grep -v timeout | \
               awk -F',' '{s+=$2; n++} END {if(n>0) printf "%.4f", s/n; else print "N/A"}')
        MAX=$(tail -n +2 "$FILE" | grep -v timeout | \
              awk -F',' 'BEGIN{m=0} {if($2>m)m=$2} END{printf "%.4f", m}')
        echo "  ${csv}.csv: ${COUNT} samples | mean=${MEAN}s | max=${MAX}s"
    else
        echo "  ${csv}.csv: NOT FOUND"
    fi
done

echo ""
echo "  eBPF logs:"
echo "    Retransmissions: $(grep -c RETRANSMIT "${RESULTS}/retransmissions.log" 2>/dev/null || echo 0) events"
echo "    Packet drops:    $(grep -v '^TIME\|^Tracing' "${RESULTS}/packet_drops.log" 2>/dev/null | grep -c '[0-9]' || echo 0) events"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Pipeline complete: $(date)"
echo "║  All results in: ${RESULTS}/"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
ls -lh "${RESULTS}/"
