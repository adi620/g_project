#!/usr/bin/env python3
"""
plot_results.py — GRS Latency Comparison Chart
Reads baseline.csv, delay.csv, loss.csv → saves results/latency_comparison.png
"""

import subprocess, sys

for pkg in ("matplotlib", "pandas"):
    try:
        __import__(pkg)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install",
                               pkg, "--break-system-packages", "--quiet"])

import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"
OUT = RESULTS_DIR / "latency_comparison.png"

def load(name):
    path = RESULTS_DIR / name
    if not path.exists():
        return None
    # FIX: read_csv with on_bad_lines='skip' silently ignores malformed rows.
    # usecols=[0,1] ensures we only take the first two columns regardless of
    # how many columns the file has, preventing crashes on inconsistent CSVs.
    try:
        df = pd.read_csv(path, usecols=[0, 1], on_bad_lines="skip")
    except TypeError:
        # on_bad_lines added in pandas 1.3; older versions use error_bad_lines=False
        df = pd.read_csv(path, usecols=[0, 1], error_bad_lines=False)
    df.columns = ["ts_ms", "lat_s"]
    df = df[df["lat_s"] != "timeout"].copy()
    df["lat_s"] = pd.to_numeric(df["lat_s"], errors="coerce")
    df = df.dropna(subset=["lat_s"])
    if df.empty:
        return None
    df["ts_ms"] = pd.to_numeric(df["ts_ms"], errors="coerce")
    df = df.dropna(subset=["ts_ms"])
    df["elapsed_s"] = (df["ts_ms"] - df["ts_ms"].iloc[0]) / 1000.0
    df["lat_ms"] = df["lat_s"] * 1000
    return df

b = load("baseline.csv")
d = load("delay.csv")
l = load("loss.csv")

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 8),
                                gridspec_kw={"height_ratios": [2.5, 1]})
fig.patch.set_facecolor("#0f1117")
fig.suptitle("GRS — Kubernetes eBPF Networking\nLatency: Baseline vs 200ms Delay vs 20% Packet Loss",
             fontsize=13, fontweight="bold", color="#e6edf3")

COLORS = {"Baseline": "#3fb950", "200ms Delay": "#d29922", "20% Loss": "#f85149"}

for ax in (ax1, ax2):
    ax.set_facecolor("#161b22")
    ax.tick_params(colors="#8b949e")
    ax.grid(True, linestyle="--", alpha=0.3, color="#30363d")
    for spine in ax.spines.values():
        spine.set_edgecolor("#30363d")

box_data, box_labels, box_colors = [], [], []
for df, lbl in [(b, "Baseline"), (d, "200ms Delay"), (l, "20% Loss")]:
    if df is None:
        continue
    c = COLORS[lbl]
    ax1.plot(df["elapsed_s"], df["lat_ms"],
             label=f"{lbl}  (mean={df['lat_ms'].mean():.1f}ms, max={df['lat_ms'].max():.1f}ms)",
             color=c, linewidth=1.5, marker="o", markersize=3, alpha=0.9)
    box_data.append(df["lat_ms"].values)
    box_labels.append(lbl)
    box_colors.append(c)

ax1.set_yscale("log")
ax1.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:.0f}ms"))
ax1.set_xlabel("Elapsed time (s)", color="#8b949e")
ax1.set_ylabel("Latency (ms) — log scale", color="#8b949e")
ax1.set_title("Latency over time", color="#e6edf3", fontsize=11)
legend = ax1.legend(fontsize=9, facecolor="#161b22", edgecolor="#30363d")
for text in legend.get_texts():
    text.set_color("#c9d1d9")

if box_data:
    # FIX: tick_labels was added in matplotlib 3.9; use labels for older versions.
    # Try tick_labels first (3.9+), fall back to labels (< 3.9) for compatibility.
    try:
        bp = ax2.boxplot(box_data, tick_labels=box_labels,
                         patch_artist=True, notch=False, widths=0.4)
    except TypeError:
        bp = ax2.boxplot(box_data, labels=box_labels,
                         patch_artist=True, notch=False, widths=0.4)
    for patch, c in zip(bp["boxes"], box_colors):
        patch.set_facecolor(c); patch.set_alpha(0.7)
    for elem in ["whiskers", "caps", "medians", "fliers"]:
        for item in bp[elem]:
            item.set_color("#8b949e")
    ax2.tick_params(axis="x", colors="#c9d1d9")

ax2.set_ylabel("Latency (ms)", color="#8b949e")
ax2.set_title("Distribution comparison", color="#e6edf3", fontsize=11)

plt.tight_layout()
RESULTS_DIR.mkdir(exist_ok=True)
plt.savefig(OUT, dpi=150, bbox_inches="tight", facecolor="#0f1117")
print(f"Plot saved → {OUT}")

print("\n── Statistics ──────────────────────────────────────────────")
for df, lbl in [(b, "Baseline"), (d, "200ms Delay"), (l, "20% Loss")]:
    if df is None:
        continue
    lat = df["lat_ms"]
    print(f"  {lbl:15s}  mean={lat.mean():8.2f}ms  "
          f"median={lat.median():8.2f}ms  "
          f"p95={lat.quantile(0.95):8.1f}ms  "
          f"max={lat.max():8.1f}ms")
