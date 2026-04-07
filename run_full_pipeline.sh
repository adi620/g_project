#!/bin/bash
# run_full_pipeline.sh
# GRS — Kubernetes eBPF Networking Fault Diagnosis
# Single command to run everything:
#   Deploy → Verify → eBPF tracing → Baseline → Delay → Loss → Report
#
# Usage: sudo ./run_full_pipeline.sh

set -euo pipefail

# ── SUDO-SAFE KUBECONFIG ──────────────────────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

if [ ! -f "$KUBECONFIG" ]; then
    echo "ERROR: kubeconfig not found at ${KUBECONFIG}"
    echo "Run as the ubuntu user with sudo, not as root directly."
    exit 1
fi

# ── SET KUBECTL CONTEXT ───────────────────────────────────────
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

echo "Switching kubectl context → ${KIND_CONTEXT}"
if ! kubectl config use-context "$KIND_CONTEXT" 2>/dev/null; then
    echo "ERROR: Context '${KIND_CONTEXT}' not found."
    echo "Available contexts:"; kubectl config get-contexts 2>/dev/null || true
    echo "Available KIND clusters:"; kind get clusters 2>/dev/null || true
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
    [ "$i" -eq 6 ] && { echo "ERROR: API server unreachable."; exit 1; }
    echo "  Waiting... (${i}/6)"; sleep 5
done

# ── PATHS ─────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${PROJECT_ROOT}/results"
mkdir -p "$RESULTS"

exec > >(tee -a "${RESULTS}/pipeline.log") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      GRS — Kubernetes eBPF Networking Fault Diagnosis        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Started:    $(date)"
echo "║  Cluster:    ${KIND_CLUSTER}   Context: ${KIND_CONTEXT}"
echo "║  Kubeconfig: ${KUBECONFIG}"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── STEP 1: DEPLOY ────────────────────────────────────────────
echo ""
echo "══ [1/8] Deploying Kubernetes workloads ══════════════════════"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-deployment.yaml"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-service.yaml"

echo "Recreating traffic pod (pod spec is immutable — must delete + recreate)..."
kubectl delete pod traffic --ignore-not-found=true
kubectl apply --validate=false -f "${PROJECT_ROOT}/traffic/traffic.yaml"

echo "Waiting for pods to be Ready..."
kubectl wait --for=condition=ready pod -l app=web --timeout=120s
kubectl wait --for=condition=ready pod/traffic    --timeout=120s

echo ""
kubectl get pods -o wide
echo ""

# ── STEP 2: CONNECTIVITY CHECK ────────────────────────────────
echo "══ [2/8] Connectivity check ══════════════════════════════════"
HTTP_CODE=$(kubectl exec traffic -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://web/ 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ HTTP ${HTTP_CODE} — traffic pod → web pod connectivity confirmed."
else
    echo "ERROR: Expected HTTP 200, got: ${HTTP_CODE}"; exit 1
fi

WEB_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
TRAFFIC_IP=$(kubectl get pod traffic -o jsonpath='{.status.podIP}')
echo "  Web pod IP:     ${WEB_IP}"
echo "  Traffic pod IP: ${TRAFFIC_IP}"

# ── STEP 3: START eBPF TRACING ────────────────────────────────
echo ""
echo "══ [3/8] Starting eBPF kernel tracers (background) ══════════"
bpftrace "${PROJECT_ROOT}/ebpf/tcp_retransmissions.bt" \
    > "${RESULTS}/retransmissions.log" 2>&1 &
RETRANS_PID=$!

bpftrace "${PROJECT_ROOT}/ebpf/packet_drops.bt" \
    > "${RESULTS}/packet_drops.log" 2>&1 &
DROPS_PID=$!

echo "  tcp_retransmit_skb tracer PID : ${RETRANS_PID}"
echo "  kfree_skb (drops) tracer PID  : ${DROPS_PID}"
echo "  Waiting 3s for probes to attach..."
sleep 3

# Stop eBPF tracers on any exit
cleanup_ebpf() {
    echo ""
    echo "── Stopping eBPF tracers ──"
    kill "$RETRANS_PID" 2>/dev/null || true
    kill "$DROPS_PID"   2>/dev/null || true
    wait "$RETRANS_PID" 2>/dev/null || true
    wait "$DROPS_PID"   2>/dev/null || true
    echo "   eBPF tracers stopped."
}
trap cleanup_ebpf EXIT

# ── STEP 4: BASELINE ──────────────────────────────────────────
echo ""
echo "══ [4/8] Baseline experiment — 60s, no faults ════════════════"
bash "${PROJECT_ROOT}/experiments/run_baseline.sh"

# ── STEP 5: DELAY ─────────────────────────────────────────────
echo ""
echo "══ [5/8] Delay experiment — 200ms, 60s ═══════════════════════"
bash "${PROJECT_ROOT}/experiments/run_delay.sh"

# ── STEP 6: LOSS ──────────────────────────────────────────────
echo ""
echo "══ [6/8] Packet loss experiment — 20%, 60s ═══════════════════"
bash "${PROJECT_ROOT}/experiments/run_loss.sh"

# ── Stop eBPF before analysis ─────────────────────────────────
echo ""
echo "── Stopping eBPF tracers before analysis ──"
kill "$RETRANS_PID" 2>/dev/null || true
kill "$DROPS_PID"   2>/dev/null || true
wait "$RETRANS_PID" 2>/dev/null || true
wait "$DROPS_PID"   2>/dev/null || true
# Disable trap since we already stopped them
trap - EXIT
sleep 2

# ── STEP 7: LATENCY + eBPF SUMMARY ───────────────────────────
echo ""
echo "══ [7/8] Results summary ═════════════════════════════════════"
echo ""
echo "── Latency CSV results ──────────────────────────────────────"
for csv in baseline delay loss; do
    FILE="${RESULTS}/${csv}.csv"
    if [ -f "$FILE" ]; then
        STATS=$(tail -n +2 "$FILE" | grep -v timeout | \
            awk -F',' '{s+=$2; n++; if($2>m) m=$2} \
            END{printf "samples=%-3d  mean=%.4fs  max=%.4fs", n, s/n, m}')
        echo "  ${csv}.csv  →  ${STATS}"
    else
        echo "  ${csv}.csv  →  NOT FOUND"
    fi
done

echo ""
echo "── eBPF kernel events ───────────────────────────────────────"
RETRANS_COUNT=$(grep -c "RETRANSMIT" "${RESULTS}/retransmissions.log" 2>/dev/null || echo 0)
DROP_COUNT=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${RESULTS}/packet_drops.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
echo "  TCP retransmissions captured : ${RETRANS_COUNT} events"
echo "  Packet drops captured        : ${DROP_COUNT} events"

echo ""
echo "── Top retransmitting IPs ───────────────────────────────────"
awk 'NR>2 && $5=="RETRANSMIT"{print $2}' "${RESULTS}/retransmissions.log" 2>/dev/null | \
    sort | uniq -c | sort -rn | head -5 | \
    awk '{printf "  %3s events  src=%s\n", $1, $2}' || echo "  (no data)"

echo ""
echo "── Loss experiment spikes ───────────────────────────────────"
SPIKES_100=$(tail -n +2 "${RESULTS}/loss.csv" 2>/dev/null | awk -F',' '$2>0.1{c++} END{print c+0}')
SPIKES_1S=$(tail -n +2 "${RESULTS}/loss.csv" 2>/dev/null | awk -F',' '$2>1.0{c++} END{print c+0}')
echo "  Spikes > 100ms : ${SPIKES_100}  (TCP retransmit triggered)"
echo "  Spikes > 1s    : ${SPIKES_1S}  (TCP exponential backoff)"

# ── STEP 8: GENERATE HTML REPORT ─────────────────────────────
echo ""
echo "══ [8/8] Generating professional HTML report ═════════════════"
bash "${PROJECT_ROOT}/generate_report.sh"

# ── GENERATE PLOT IF MATPLOTLIB AVAILABLE ─────────────────────
echo ""
echo "── Generating latency comparison plot ───────────────────────"
python3 "${PROJECT_ROOT}/plot_results.py" 2>/dev/null && \
    echo "  ✓ Plot saved → ${RESULTS}/latency_comparison.png" || \
    echo "  (matplotlib not available — install with: sudo apt install python3-matplotlib -y)"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Pipeline complete: $(date)"
echo "║  Results saved in: ${RESULTS}/"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  View HTML report:"
echo "║    python3 -m http.server 8080 --directory ${RESULTS}"
echo "║    Then open: http://localhost:8080/report.html"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
ls -lh "${RESULTS}/"
