# GRS eBPF Kubernetes Networking Observability

Diagnoses Kubernetes networking failures using **kernel-level eBPF tracing**.  
The system deploys a microservice pair, generates continuous traffic, injects controlled network faults, and correlates kernel events with application-level latency.

```
Traffic Pod → K8s Service → Web Pod (nginx)
                                   ↓
                         Linux Networking Stack
                                   ↓
                          eBPF Tracing (bpftrace)
                                   ↓
                    Retransmissions / Drop events → results/
```

---

## Project Structure

```
GRS-Project/
├── deployment/
│   ├── web-deployment.yaml       # nginx Deployment (1 replica)
│   └── web-service.yaml          # ClusterIP Service
├── traffic/
│   └── traffic.yaml              # curl-based traffic generator Pod
├── fault_injection/
│   ├── get_interface.sh          # Auto-discovers KIND bridge (no hardcoding)
│   ├── inject_delay.sh           # tc netem delay injection
│   ├── inject_loss.sh            # tc netem packet loss injection
│   └── clear_rules.sh            # Removes all tc rules
├── measurement/
│   └── measure_latency.sh        # Measures latency, saves timestamped CSV
├── ebpf/
│   ├── tcp_retransmissions.bt    # bpftrace: TCP retransmission events
│   └── packet_drops.bt           # bpftrace: kernel packet drop events
├── experiments/
│   ├── run_baseline.sh           # 60s baseline measurement
│   ├── run_delay.sh              # 60s with 100ms delay
│   └── run_loss.sh               # 60s with 10% packet loss
├── results/                      # All CSVs and eBPF logs land here
├── run_full_pipeline.sh          # ← Single command to run everything
└── plot_results.py               # Plots all 3 experiments side-by-side
```

---

## Requirements

| Tool        | Purpose                        | Install                              |
|-------------|--------------------------------|--------------------------------------|
| Docker      | Container runtime              | `sudo apt install docker.io`         |
| kind        | Kubernetes in Docker           | https://kind.sigs.k8s.io/            |
| kubectl     | K8s CLI                        | `sudo apt install kubectl`           |
| bpftrace    | eBPF kernel tracing            | `sudo apt install bpftrace`          |
| iproute2    | `tc` for fault injection       | `sudo apt install iproute2`          |
| Python 3    | Plotting (optional)            | `sudo apt install python3`           |
| matplotlib  | Plotting (optional)            | `pip install matplotlib pandas`      |

---

## Setup

### 1. Create a KIND cluster

```bash
kind create cluster --name grs
kubectl cluster-info --context kind-grs
```

### 2. Clone and enter the project

```bash
git clone https://github.com/adi620/GRS-Project.git
cd GRS-Project
```

### 3. Make all scripts executable

```bash
find . -name "*.sh" -exec chmod +x {} \;
```

---

## Running the Full Pipeline (Recommended)

One command runs everything — deploy, baseline, delay, loss, eBPF tracing, and cleanup:

```bash
sudo ./run_full_pipeline.sh
```

> `sudo` is required for `bpftrace` and `tc` (kernel-level access).

**What it does, in order:**

1. Deploys nginx and traffic generator pods
2. Waits for pods to be `Ready`
3. Runs connectivity check
4. Starts eBPF tracing in the background
5. Runs 60s baseline measurement → `results/baseline.csv`
6. Injects 100ms delay → runs 60s → `results/delay.csv` → clears fault
7. Injects 10% packet loss → runs 60s → `results/loss.csv` → clears fault
8. Stops eBPF tracing → saves to `results/retransmissions.log` and `results/packet_drops.log`

---

## Running Experiments Individually

### Baseline only

```bash
bash experiments/run_baseline.sh
```

### Delay experiment (custom delay)

```bash
DELAY_MS=200 bash experiments/run_delay.sh
```

### Packet loss experiment (custom loss %)

```bash
LOSS_PCT=20 bash experiments/run_loss.sh
```

### Manual fault injection

```bash
# Inject 150ms delay
sudo fault_injection/inject_delay.sh 150

# Inject 5% packet loss
sudo fault_injection/inject_loss.sh 5

# Clear all rules
sudo fault_injection/clear_rules.sh
```

---

## Plotting Results

After experiments complete, generate the comparison chart:

```bash
python3 plot_results.py
# Output: results/latency_comparison.png
```

The plot shows:
- **Line chart**: latency over time per experiment
- **Box plot**: distribution summary (mean, median, p95, max)

---

## Understanding the Results

| Experiment    | Expected Latency         | Expected Kernel Events          |
|---------------|--------------------------|---------------------------------|
| Baseline      | < 5ms (loopback)         | None                            |
| 100ms Delay   | ~100ms+ (stable)         | Rare or no retransmissions      |
| 10% Loss      | Variable, spikes >200ms  | High TCP retransmissions        |

### How Fault Injection Works

The scripts use `tc netem` on the **KIND bridge interface** (`br-<id>`), which is the stable Layer 2 bridge that all KIND node containers attach to. Unlike per-pod `veth` interfaces (which change every run), the bridge is constant for the lifetime of the cluster.

```bash
# What get_interface.sh does automatically:
BRIDGE_ID=$(docker network inspect kind --format '{{.Id}}' | cut -c1-12)
IFACE="br-${BRIDGE_ID}"   # e.g. br-3f4a12c8d901
```

### Reading eBPF Logs

`results/retransmissions.log` — one line per TCP retransmission:
```
TIME_NS              SADDR                SPORT  DPORT  EVENT
1712000000000000000  10.244.0.5           54321  80     RETRANSMIT
```

`results/packet_drops.log` — one line per kernel drop:
```
TIME_NS              LOCATION             DROP_REASON
1712000000000000000  kfree_skb            3
```

---

## Cleanup

```bash
kubectl delete -f deployment/web-deployment.yaml
kubectl delete -f deployment/web-service.yaml
kubectl delete -f traffic/traffic.yaml

# Optionally destroy the cluster
kind delete cluster --name grs
```

---

## Troubleshooting

**Pod stuck in `Pending`:**
```bash
kubectl describe pod <pod-name>
# Usually: cluster not running or image pull issue
```

**`get_interface.sh` fails:**
```bash
docker network ls           # Check 'kind' network exists
docker network inspect kind # Verify bridge ID
```

**bpftrace permission denied:**
```bash
# Must run with sudo
sudo bpftrace ebpf/tcp_retransmissions.bt
```

**Fault injection has no visible effect:**
```bash
# Verify the rule was applied
sudo tc qdisc show dev $(fault_injection/get_interface.sh)
```
