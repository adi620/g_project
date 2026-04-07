#!/usr/bin/env python3
"""
plot_results_extended.py — GRS Extended Latency Chart
All 6 faults: Baseline, Delay, Loss, Bandwidth, Reordering, CPU Stress
Saves: results/latency_comparison_extended.png
"""

import subprocess, sys, os

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
OUT = RESULTS_DIR / "latency_comparison_extended.png"


def safe_out_path(path):
    """Remove existing file safely before saving — avoids PermissionError on root-owned PNG."""
    if path.exists():
        try:
            path.unlink()
        except PermissionError:
            alt = path.with_name(path.stem + "_new.png")
            print(f"[plot] WARNING: Cannot overwrite {path.name} (root-owned). Saving to {alt.name}")
            return alt
    return path


def load(name):
    path = RESULTS_DIR / name
    if not path.exists():
        return None
    try:
        df = pd.read_csv(path, usecols=[0, 1], on_bad_lines="skip")
    except TypeError:
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


# ── Load all datasets ─────────────────────────────────────────
DATASETS = [
    ("baseline.csv",   "Baseline",    "#3fb950"),
    ("delay.csv",      "200ms Delay", "#d29922"),
    ("loss.csv",       "20% Loss",    "#f85149"),
    ("bandwidth.csv",  "1mbit BW",    "#a371f7"),
    ("reordering.csv", "Reorder 25%", "#79c0ff"),
    ("cpu_stress.csv", "CPU Stress",  "#ff9e64"),
]

loaded = [(load(f), lbl, c) for f, lbl, c in DATASETS]
present = [(df, lbl, c) for df, lbl, c in loaded if df is not None]

if not present:
    print("[plot] No CSV data found in results/. Run the pipeline first.")
    sys.exit(0)

# ── Layout: 3 rows — timeline (tall), box (medium), stats table (short) ──
fig = plt.figure(figsize=(14, 10))
fig.patch.set_facecolor("#0f1117")
fig.suptitle(
    "GRS Extended — Kubernetes eBPF Networking\n"
    "Latency Comparison: All Fault Types",
    fontsize=13, fontweight="bold", color="#e6edf3", y=0.98
)

gs = fig.add_gridspec(2, 1, hspace=0.38, height_ratios=[2.5, 1],
                      top=0.93, bottom=0.07, left=0.08, right=0.97)
ax1 = fig.add_subplot(gs[0])
ax2 = fig.add_subplot(gs[1])

for ax in (ax1, ax2):
    ax.set_facecolor("#161b22")
    ax.tick_params(colors="#8b949e", labelsize=9)
    ax.grid(True, linestyle="--", alpha=0.3, color="#30363d")
    for spine in ax.spines.values():
        spine.set_edgecolor("#30363d")

# ── Timeline ──────────────────────────────────────────────────
for df, lbl, c in present:
    ax1.plot(df["elapsed_s"], df["lat_ms"],
             label=f"{lbl}  (mean={df['lat_ms'].mean():.1f}ms)",
             color=c, linewidth=1.4, marker="o", markersize=2.5, alpha=0.9)

ax1.set_yscale("log")
ax1.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:.0f}ms"))
ax1.set_xlabel("Elapsed time (s)", color="#8b949e", fontsize=9)
ax1.set_ylabel("Latency (ms) — log scale", color="#8b949e", fontsize=9)
ax1.set_title("Latency over time — all fault types", color="#e6edf3", fontsize=11)

handles, lbls = ax1.get_legend_handles_labels()
if handles:
    legend = ax1.legend(fontsize=8, facecolor="#161b22", edgecolor="#30363d",
                        ncol=2, loc="upper left")
    for text in legend.get_texts():
        text.set_color("#c9d1d9")

# ── Box plot — use labels= (works on all matplotlib versions) ──
box_data   = [df["lat_ms"].values for df, _, _ in present]
box_labels = [lbl for _, lbl, _ in present]
box_colors = [c   for _, _, c   in present]

# Try tick_labels (≥3.9) first, fall back to labels (older) — never crash
try:
    bp = ax2.boxplot(box_data, tick_labels=box_labels,
                     patch_artist=True, notch=False, widths=0.5)
except TypeError:
    bp = ax2.boxplot(box_data, labels=box_labels,
                     patch_artist=True, notch=False, widths=0.5)

for patch, c in zip(bp["boxes"], box_colors):
    patch.set_facecolor(c)
    patch.set_alpha(0.72)
for elem in ["whiskers", "caps", "medians", "fliers"]:
    for item in bp[elem]:
        item.set_color("#8b949e")

ax2.tick_params(axis="x", colors="#c9d1d9", labelsize=8)
ax2.set_ylabel("Latency (ms)", color="#8b949e", fontsize=9)
ax2.set_title("Distribution per fault type", color="#e6edf3", fontsize=11)

# ── Save ──────────────────────────────────────────────────────
plt.tight_layout()
RESULTS_DIR.mkdir(exist_ok=True)
out_path = safe_out_path(OUT)
try:
    plt.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="#0f1117")
    print(f"[plot] Extended plot saved → {out_path}")
except PermissionError as e:
    print(f"[plot] ERROR: {e}")
    print("[plot] TIP: sudo chown $USER results/latency_comparison_extended.png")
finally:
    plt.close()

display = os.environ.get("DISPLAY", "")
if not display:
    print("[plot] Headless VM — serve with: python3 -m http.server 8080 --directory results/")

# ── Statistics ────────────────────────────────────────────────
print("\n── Extended Statistics ─────────────────────────────────────")
for df, lbl, _ in present:
    lat = df["lat_ms"]
    print(f"  {lbl:15s}  mean={lat.mean():8.2f}ms  "
          f"median={lat.median():8.2f}ms  "
          f"p95={lat.quantile(0.95):8.1f}ms  "
          f"max={lat.max():8.1f}ms  n={len(lat)}")
