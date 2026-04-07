#!/usr/bin/env python3
"""
plot_results.py — GRS Latency Comparison Chart
Reads baseline.csv, delay.csv, loss.csv → saves results/latency_comparison.png
"""

import subprocess, sys, os, stat

for pkg in ("matplotlib", "pandas"):
    try:
        __import__(pkg)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install",
                               pkg, "--break-system-packages", "--quiet"])

import pandas as pd
import matplotlib
matplotlib.use("Agg")          # headless — no display needed, no feh needed
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"
OUT = RESULTS_DIR / "latency_comparison.png"

# ── FIX 2: Safe file removal before save ─────────────────────
# When the pipeline runs under sudo, the previous PNG is owned by root.
# Running plot_results.py as a normal user then hits PermissionError.
# Solution: attempt to remove the existing file first; if removal fails
# (e.g. truly locked), fall back to a temp name so we never crash.
def safe_out_path(path):
    if path.exists():
        try:
            path.unlink()
        except PermissionError:
            # Cannot delete root-owned file — write to an alternate name instead
            alt = path.with_name("latency_comparison_new.png")
            print(f"[plot] WARNING: Cannot overwrite {path.name} (owned by root).")
            print(f"[plot]          Saving to {alt.name} instead.")
            return alt
    return path


def load(name):
    path = RESULTS_DIR / name
    if not path.exists():
        return None
    # read_csv with on_bad_lines='skip' ignores malformed rows.
    # usecols=[0,1] takes only the first two columns — safe against extra columns.
    try:
        df = pd.read_csv(path, usecols=[0, 1], on_bad_lines="skip")
    except TypeError:
        # on_bad_lines added in pandas 1.3; older versions use error_bad_lines
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

if all(x is None for x in (b, d, l)):
    print("[plot] No CSV data found in results/. Run the pipeline first.")
    sys.exit(0)

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

handles, lbls = ax1.get_legend_handles_labels()
if handles:
    legend = ax1.legend(fontsize=9, facecolor="#161b22", edgecolor="#30363d")
    for text in legend.get_texts():
        text.set_color("#c9d1d9")

if box_data:
    # FIX: tick_labels (matplotlib ≥3.9) vs labels (older) — try both for compatibility
    try:
        bp = ax2.boxplot(box_data, tick_labels=box_labels,
                         patch_artist=True, notch=False, widths=0.4)
    except TypeError:
        bp = ax2.boxplot(box_data, labels=box_labels,
                         patch_artist=True, notch=False, widths=0.4)
    for patch, c in zip(bp["boxes"], box_colors):
        patch.set_facecolor(c)
        patch.set_alpha(0.7)
    for elem in ["whiskers", "caps", "medians", "fliers"]:
        for item in bp[elem]:
            item.set_color("#8b949e")
    ax2.tick_params(axis="x", colors="#c9d1d9")

ax2.set_ylabel("Latency (ms)", color="#8b949e")
ax2.set_title("Distribution comparison", color="#e6edf3", fontsize=11)

plt.tight_layout()
RESULTS_DIR.mkdir(exist_ok=True)

# ── FIX 2: Safe save with permission handling ─────────────────
out_path = safe_out_path(OUT)
try:
    plt.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="#0f1117")
    print(f"[plot] Plot saved → {out_path}")
except PermissionError as e:
    print(f"[plot] ERROR: Cannot write plot — {e}")
    print("[plot] TIP: Run:  sudo chown $USER results/latency_comparison.png")
    print("[plot]      Then re-run:  python3 plot_results.py")
finally:
    plt.close()

# ── FIX 3: Headless display — skip feh silently ───────────────
# feh requires an X display. On a headless VM it fails with
# "Can't open X display". We skip the display attempt entirely —
# the PNG is always saved to results/ and can be transferred/viewed elsewhere.
display = os.environ.get("DISPLAY", "")
if display:
    print(f"[plot] To view:  feh {out_path}")
else:
    print(f"[plot] No display detected (headless VM). To view the PNG:")
    print(f"[plot]   Copy to Windows:  results/latency_comparison.png")
    print(f"[plot]   Or serve via:     python3 -m http.server 8080 --directory results/")

print("\n── Statistics ──────────────────────────────────────────────")
for df, lbl in [(b, "Baseline"), (d, "200ms Delay"), (l, "20% Loss")]:
    if df is None:
        continue
    lat = df["lat_ms"]
    print(f"  {lbl:15s}  mean={lat.mean():8.2f}ms  "
          f"median={lat.median():8.2f}ms  "
          f"p95={lat.quantile(0.95):8.1f}ms  "
          f"max={lat.max():8.1f}ms")
