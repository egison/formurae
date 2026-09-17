#!/usr/bin/env python3
"""Draw saved FME diagnostics; no fluid calculations are performed here."""
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import NullLocator
from gallery import load_report

HERE = Path(__file__).resolve().parent


def main():
    runs = load_report()["runs"]
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False,
                         "axes.spines.right": False, "svg.fonttype": "none",
                         "svg.hashsalt": "kinetic-viscosity"})
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.2), layout="constrained")
    for zeta, color in zip((0.002, 0.008, 0.02), ("#265b9a", "#13846c", "#b65f2d")):
        for chart in ("cartesian", "mapped"):
            run = next(r for r in runs if r["grid"]==64 and r["scenario"]=="shear"
                       and r["zeta"]==zeta and r["chart"]==chart and r["method"]=="muscl"
                       and r["time_scale"]==1)
            history = run["history"]
            time = [r["time"] for r in history]
            initial = history[0]["referenceMode"]
            if chart=="cartesian":
                axes[0].plot(time, [r["mode"]/initial for r in history], color=color,
                             label=f"τ = {run['final']['relaxationTime']:.3f}")
                axes[0].plot(time, [r["referenceMode"]/initial for r in history],
                             color="#555555", linestyle="--", linewidth=1)
            else:
                axes[0].plot(time[::8], [r["mode"]/initial for r in history[::8]],
                             color=color, linestyle="none", marker="o", markersize=4, markerfacecolor="white")
    axes[0].set_title("Shear decay with collisions (64 × 64)", loc="left")
    axes[0].set_xlabel("Physical time")
    axes[0].set_ylabel("Projected velocity / initial value")
    legend = axes[0].legend(frameon=False, fontsize=9, loc="lower left")
    axes[0].add_artist(legend)
    axes[0].legend(handles=[Line2D([], [], color="#555", label="Cartesian"),
                           Line2D([], [], color="#555", marker="o", markerfacecolor="white", linestyle="none", label="Mapped"),
                           Line2D([], [], color="#555", linestyle="--", label="Analytical decay")],
                   frameon=False, fontsize=8, loc="upper right")
    axes[0].grid(alpha=0.2)
    for chart, color, label in (("cartesian", "#265b9a", "Cartesian"), ("mapped", "#13846c", "Mapped")):
        for method, style, marker in (("upwind", ":", "o"), ("muscl", "-", "s")):
            selected = sorted((r for r in runs if r["chart"]==chart and r["scenario"]=="shear"
                               and r["zeta"]==0.008 and r["method"]==method and r["time_scale"]==1), key=lambda r:r["grid"])
            axes[1].loglog([r["grid"] for r in selected], [r["final"]["velocityErrorL1"] for r in selected],
                           color=color, linestyle=style, marker=marker, markersize=5,
                           markerfacecolor="white" if method=="upwind" else color,
                           label=f"{label}: {'MUSCL' if method=='muscl' else 'upwind'}")
    axes[1].set_title("Velocity error at t = 2π (τ ≈ 0.156)", loc="left")
    axes[1].set_xlabel("Cells per coordinate")
    axes[1].set_ylabel("Mean absolute velocity error")
    axes[1].set_xticks([16,32,64,128], ["16","32","64","128"])
    axes[1].xaxis.set_minor_locator(NullLocator())
    axes[1].legend(frameon=False, fontsize=8, loc="lower left")
    axes[1].grid(alpha=0.2)
    svg = HERE/"results/viscosity.svg"
    fig.savefig(svg, metadata={"Date": None})
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines())+"\n")
    fig.savefig(HERE/"results/viscosity.png", dpi=180)
    plt.close(fig)


if __name__=="__main__":
    main()
