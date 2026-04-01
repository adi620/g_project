# GRS — Kubernetes eBPF Networking Fault Diagnosis

> **Assignment:** Diagnose Kubernetes networking failures using kernel-level eBPF traces.  
> Observe packet drops, TCP retransmissions, and queue overflows across three conditions:  
> **Baseline → Controlled Delay → Controlled Packet Loss**

---

## Architecture

```
┌─────────────────────── KIND Node (Docker container) ──────────────────────┐
│                                                                             │
│  ┌──────────────────┐          ┌──────────────────┐                        │
│  │  traffic Pod     │  curl    │  web Pod (nginx) │                        │
│  │  (curlimages)    │ ──────── │  ClusterIP :80   │  ← tc netem applied   │
│  │                  │  HTTP    │                  │    on this pod's eth0  │
│  └──────────────────┘          └──────────────────┘                        │
│                                         ↑                                  │
│                          eBPF probes on kernel events                      │
│                     (tcp_retransmit_skb, kfree_skb)                        │
└─────────────────────────────────────────────────────────────────────────────┘

Fault injection path:  sudo ./fault_injection/inject_fault.sh delay 200
                           → nsenter into web pod's network namespace
                           → tc qdisc add dev eth0 root netem delay 200ms
```

**Why inject on the web pod's eth0?**  
Both pods run on the **same KIND node**. Traffic between them goes through veth pairs  
bridged inside the node — it never crosses the host's external interface.  
Injecting `tc netem` directly inside the web pod's network namespace via `nsenter`  
is the only reliable approach for same-node pod-to-pod traffic in KIND.

---

## Project Structure

```
GRS-Project/
├── run_full_pipeline.sh          ← Single command: runs everything
├── plot_results.py               ← Generates comparison chart
│
├── deployment/
│   ├── web-deployment.yaml       # nginx server pod (1 replica)
│   └── web-service.yaml          # ClusterIP service
│
├── traffic/
│   └── traffic.yaml              # curl-based traffic generator pod
│
├── fault_injection/
│   ├── inject_fault.sh           # Main injector: delay / loss / clear
│   └── get_web_netns_pid.sh      # /proc-based pod namespace finder (reference)
│
├── measurement/
│   └── measure_latency.sh        # Measures latency, saves timestamped CSV
│
├── ebpf/
│   ├── tcp_retransmissions.bt    # bpftrace: TCP retransmit events
│   └── packet_drops.bt           # bpftrace: kernel packet drops
│
├── experiments/
│   ├── run_baseline.sh           # 60s — no faults
│   ├── run_delay.sh              # 60s — 200ms delay on web pod
│   └── run_loss.sh               # 60s — 20% packet loss on web pod
│
└── results/                      # All CSV and log files land here
    ├── baseline.csv
    ├── delay.csv
    ├── loss.csv
    ├── retransmissions.log
    ├── packet_drops.log
    └── pipeline.log
```

---

## Prerequisites

```bash
# Required tools
sudo apt update
sudo apt install -y docker.io iproute2 bpftrace

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
sudo install -o root -g root -m 0755 kind /usr/local/bin/kind

# Python plotting (optional)
pip install matplotlib pandas
```

---

## Step-by-Step Execution

### 1. Create KIND cluster

```bash
kind create cluster --name grs
kubectl cluster-info --context kind-grs
```

### 2. Clone and prepare

```bash
git clone https://github.com/adi620/GRS-Project.git
cd GRS-Project
find . -name "*.sh" -exec chmod +x {} \;
```

### 3. Run the full pipeline

```bash
sudo ./run_full_pipeline.sh
```

That's it. The pipeline handles everything automatically.

---

## What the Pipeline Does

| Step | Action | Output |
|------|--------|--------|
| 1 | Deploy web + traffic pods, wait for Ready | pods running |
| 2 | HTTP connectivity check (expects 200) | confirmed |
| 3 | Start eBPF tracers in background | retransmissions.log, packet_drops.log |
| 4 | 60s baseline — no faults | baseline.csv |
| 5 | Inject 200ms delay → 60s measurement → clear | delay.csv |
| 6 | Inject 20% packet loss → 60s measurement → clear | loss.csv |
| 7 | Print summary statistics | terminal |

---

## How Fault Injection Works

```bash
# inject_fault.sh uses /proc to find the web pod's network namespace
# without any hardcoded interface names:

POD_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')

# Scan /proc for a PID whose net namespace contains the pod IP
for pid in /proc/*/net/fib_trie; do
    grep -q "$POD_IP" "$pid" && POD_PID=...
done

# Enter that network namespace and apply tc
nsenter -t $POD_PID -n -- tc qdisc add dev eth0 root netem delay 200ms
```

**No hardcoded interface names. No crictl label bugs. Works every run.**

---

## Running Experiments Individually

```bash
# Baseline only
sudo bash experiments/run_baseline.sh

# Delay only (custom value)
DELAY_MS=500 sudo bash experiments/run_delay.sh

# Loss only (custom value)
LOSS_PCT=30 sudo bash experiments/run_loss.sh

# Manual fault injection
sudo fault_injection/inject_fault.sh delay 200   # inject 200ms delay
sudo fault_injection/inject_fault.sh loss 20     # inject 20% loss
sudo fault_injection/inject_fault.sh clear       # remove all faults
```

---

## Expected Results

| Experiment | Expected Latency | Kernel Events |
|------------|-----------------|---------------|
| Baseline   | 1–5ms           | None |
| 200ms Delay | 200–210ms      | Rare retransmissions |
| 20% Loss   | 5–500ms (spikes) | High TCP retransmissions |

### Reading the CSV files

```
timestamp,latency_seconds
1775067223800,0.001798    ← 1.8ms — baseline
1775067446826,0.200853    ← 200ms — delay active ✓
1775067559220,0.043219    ← spike — retransmission due to loss ✓
```

### Reading eBPF logs

`results/retransmissions.log`:
```
TIME_NS              SADDR            SPORT  DADDR            EVENT
1712000000000000000  10.244.0.6       54321  10.244.0.5       RETRANSMIT
```

`results/packet_drops.log`:
```
TIME_NS              CALLER                         DROP_REASON
1712000000000000000  kfree_skb                      3
```

---

## Plotting

```bash
python3 plot_results.py
# Saves: results/latency_comparison.png
```

---

## Cleanup

```bash
kubectl delete -f deployment/web-deployment.yaml
kubectl delete -f deployment/web-service.yaml
kubectl delete -f traffic/traffic.yaml

# Delete cluster entirely
kind delete cluster --name grs
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Context 'kind-grs' not found` | Run `kind create cluster --name grs` first |
| `kubeconfig not found` | Don't run as pure root; use `sudo` from ubuntu user |
| `inject_fault.sh: pod IP not found` | Check pod is Running: `kubectl get pods` |
| `bpftrace: permission denied` | Script must run with `sudo` |
| delay.csv shows no change | Verify fault: `sudo fault_injection/inject_fault.sh delay 200` then `kubectl exec traffic -- curl -w "%{time_total}" http://web/` |
