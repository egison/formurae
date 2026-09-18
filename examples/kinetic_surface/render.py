#!/usr/bin/env python3
"""Draw saved surface displacement; never evolve or prescribe the wave here."""
import argparse
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.patches import Polygon
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / ".build/kinetic-surface"


def render(report_path, output):
    report = json.loads(report_path.read_text())
    source = hashlib.sha256((HERE / "kinetic_surface.fme").read_bytes()).hexdigest()
    if report["source_sha256"] != source:
        raise ValueError("saved results do not match the model")
    waves = [r for r in report["runs"] if r["scenario"] == "wave" and r["gravity"] == 0.02
             and r["time_scale"] == 1 and r["boundary_slope"] == 1]
    size = max(r["grid"][0] for r in waves)
    chosen = [next(r for r in waves if r["grid"][0] == size and r["chart"] == chart) for chart in ("cartesian", "mapped")]
    datasets = []
    for record in chosen:
        archive = (BUILD / record["csv"]).with_name("frames.npz")
        if "frames_sha256" in record and hashlib.sha256(archive.read_bytes()).hexdigest() != record["frames_sha256"]:
            raise ValueError("saved frames changed")
        with np.load(archive) as data:
            datasets.append({key: data[key] for key in data.files})
    np.testing.assert_array_equal(datasets[0]["time"], datasets[1]["time"])
    times = datasets[0]["time"]
    x = (np.arange(size)+0.5)*2*np.pi/size
    height = [np.pi+data["fields"][:, 0, -2] for data in datasets]
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "text.color": "#203c4d", "axes.labelcolor": "#344f61"})
    fig = plt.figure(figsize=(12, 7.2), dpi=100, facecolor="#f5f8fa")
    fig.text(0.065, 0.94, "A free surface driven by D2Q9 transport", size=20, weight="bold")
    fig.text(0.065, 0.892, "Linearized small-amplitude waves  /  Same equations in two coordinate systems", size=11)
    clock = fig.text(0.94, 0.94, "", ha="right", size=13, family="monospace")
    artists = []
    for i, (label, water_height) in enumerate(zip(("Cartesian grid", "Curved grid"), height)):
        ax = fig.add_axes([0.075+0.485*i, 0.46, 0.395, 0.32])
        floor, top = np.pi-0.013, np.pi+0.013
        ax.set(xlim=(0, 2*np.pi), ylim=(floor, top), xlabel="Physical x", ylabel="Surface height")
        ax.set_title(label, loc="left", fontsize=13, pad=12)
        ax.set_xticks([0, np.pi, 2*np.pi], ["0", "π", "2π"])
        ax.ticklabel_format(axis="y", useOffset=False)
        ax.set_facecolor("#edf4f8")
        water = Polygon([[0, floor], [2*np.pi, floor]], closed=True, color="#57acc9", alpha=0.8)
        ax.add_patch(water)
        line, = ax.plot(x, water_height[0], lw=2.5, color="#09668e")
        ax.axhline(np.pi, color="#7a94a5", ls="--", lw=1)
        artists.append((water, line, floor))
    fig.text(0.065, 0.375, "Surface detail: vertical variation enlarged; dashed line is the undisturbed level.", size=10)
    ax = fig.add_axes([0.075, 0.13, 0.88, 0.18])
    colors = ("#087398", "#d18a36")
    for record, color, label in zip(chosen, colors, ("Cartesian", "Curved")):
        ax.plot([r["elapsed"] for r in record["history"]], [r["surfaceMode"] for r in record["history"]],
                color=color, lw=2, label=label, ls="-" if label == "Cartesian" else "--")
    ax.axhline(0, color="#a5b9c5", lw=0.8)
    ax.set(xlabel="Simulation time", ylabel="Wave amplitude", xlim=(0, times[-1]))
    ax.legend(frameon=False, ncol=2, loc="upper right")
    cursor = ax.axvline(times[0], color="#647b89", lw=1)
    fig.text(0.065, 0.025, "FORMURAE  /  Recorded surface displacement; no prescribed animation", size=10, color="#637c8b")
    output.mkdir(parents=True, exist_ok=True)
    writer = FFMpegWriter(fps=15, codec="libx264", extra_args=["-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
    with writer.saving(fig, str(output / "surface.mp4"), dpi=100):
        for index, time in enumerate(times):
            clock.set_text(f"t = {time:7.3f}")
            for values, (water, line, floor) in zip(height, artists):
                y = values[index]
                water.set_xy(np.column_stack((np.r_[x[0], x, x[-1]], np.r_[floor, y, floor])))
                line.set_ydata(y)
            cursor.set_xdata([time, time])
            if index == len(times)//3:
                fig.savefig(output / "surface.png", dpi=100)
            writer.grab_frame(facecolor=fig.get_facecolor())
    plt.close(fig)
    metadata = dict(source_sha256=source, verification_sha256=hashlib.sha256(report_path.read_bytes()).hexdigest(),
                    renderer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    grid=[size, size//2], frames=len(times), fps=15,
                    physical_time=[float(times[0]), float(times[-1])],
                    media={suffix: hashlib.sha256((output / f"surface.{suffix}").read_bytes()).hexdigest()
                           for suffix in ("mp4", "png")})
    (output / "rendering.json").write_text(json.dumps(metadata, indent=2)+"\n")
    print(output / "surface.mp4")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true")
    args = parser.parse_args()
    render(BUILD / "probe.json" if args.probe else HERE / "results/verification.json",
           BUILD / "preview" if args.probe else HERE / "results")
