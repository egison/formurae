#!/usr/bin/env python3
"""Render saved solver output; all NumPy computations here are for display.

Requires numpy, matplotlib; video also requires ffmpeg or imageio-ffmpeg.
No rendered data is fed back into the simulation.
"""
import argparse
import csv
import json
from pathlib import Path
import shutil

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.colors import Normalize
from matplotlib.patches import Circle

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LABELS = {"vacuum": "Vacuum", "obstacle": "Bare conducting cylinder",
          "cloak": "Cloaked cylinder", "rotator": "Field rotator"}
DETAILS = {"vacuum": "reference pulse", "obstacle": "shadow and reflection",
           "cloak": "radial map r' = R2 (r - R1')/(R2 - R1')", "rotator": "angular map phi' = phi + f(r), a quarter turn"}
RECORD = np.dtype([("i", "=i4"), ("j", "=i4"), ("e", "=f8"), ("ev", "=f8")])
NORM = Normalize(-1.0, 1.0)
CMAP = plt.get_cmap("RdBu_r")


def load_field(directory, step):
    result = None
    for path in sorted((directory / "data").glob(f"frame-{step:07d}-rank-*.bin")):
        with path.open("rb") as file:
            nx, ny, stamp = np.fromfile(file, dtype="=i4", count=3)
            if stamp != step:
                raise ValueError("frame stamp mismatch")
            data = np.fromfile(file, dtype=RECORD)
        if result is None:
            result = np.full((nx, ny), np.nan)
        result[data["i"], data["j"]] = data["e"]
    if result is None or not np.isfinite(result).all():
        raise ValueError(f"missing or invalid frame: {directory}, step {step}")
    return result


def panel(ax, u, parameters, title, detail):
    image = ax.imshow(u.T, origin="lower", extent=(0, 16, 0, 12), cmap=CMAP, norm=NORM,
                      interpolation="bilinear")
    cx, cy = 8.0, 6.0
    r1, r2 = float(parameters["R1"]), float(parameters["R2"])
    if float(parameters["rotator"]) > 0 or float(parameters["cloak"]) > 0:
        ax.add_patch(Circle((cx, cy), r2, fill=False, color="black", lw=0.8, ls="--"))
    if float(parameters["obstacle"]) > 0:
        ax.add_patch(Circle((cx, cy), r1, fill=True, color="#555555"))
    elif float(parameters["rotator"]) > 0:
        ax.add_patch(Circle((cx, cy), r1, fill=False, color="black", lw=0.8, ls="--"))
    ax.set(title=title + "\n" + detail, xticks=[], yticks=[], aspect="equal")
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / ".build/transformation_optics/demo")
    parser.add_argument("--output", type=Path, default=HERE / "results")
    parser.add_argument("--time", type=float, default=8.0)
    parser.add_argument("--video", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = list(LABELS)
    directories = [args.input / case for case in cases]
    metadata = [json.loads((directory / "metadata.json").read_text()) for directory in directories]
    provenance = {case: meta | {"run_log": (directory / "run.log").read_text().strip()}
                  for case, meta, directory in zip(cases, metadata, directories)}
    (args.output / "runs.json").write_text(json.dumps(provenance, indent=2) + "\n")
    dt = float(metadata[0]["parameters"]["dt"].split("*")[0]) * 16.0 / metadata[0]["grid"][0]
    stamps = sorted({int(path.name.split("-")[1]) for path in (directories[0]/"data").glob("*.bin")})
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "savefig.facecolor": "#fafafa", "figure.facecolor": "#fafafa"})
    fig, axes = plt.subplots(2, 2, figsize=(12, 9.6), layout="constrained")
    title = fig.suptitle("Transformation optics on a Cartesian grid", fontsize=17, fontweight="bold")
    images = []
    for ax, case, directory, meta in zip(axes.flat, cases, directories, metadata):
        images.append(panel(ax, load_field(directory, stamps[0]), meta["parameters"], LABELS[case], DETAILS[case]))
    fig.colorbar(images[0], ax=axes, orientation="horizontal", fraction=0.04, pad=0.03, label="Electric field Ez")

    def draw(step):
        title.set_text(f"Transformation optics on a Cartesian grid   |   t = {step*dt:.1f}")
        for image, directory in zip(images, directories):
            image.set_data(load_field(directory, step).T)

    selected = min(stamps, key=lambda step: abs(step*dt-args.time))
    draw(selected)
    fig.savefig(args.output / "comparison.png", dpi=130)
    if args.video:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            import imageio_ffmpeg
            ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
        matplotlib.rcParams["animation.ffmpeg_path"] = ffmpeg
        writer = FFMpegWriter(fps=12, codec="libx264", extra_args=["-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
        with writer.saving(fig, args.output / "comparison.mp4", dpi=100):
            for i, step in enumerate(stamps):
                draw(step)
                writer.grab_frame()
                if i % 10 == 0:
                    print(f"video {i+1}/{len(stamps)}", flush=True)
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(11, 4), layout="constrained")
    for case, directory in zip(cases, directories):
        with (directory / "stats.csv").open() as file:
            rows = list(csv.DictReader(file))
        times = [int(r["step"])*dt for r in rows]
        # Both sums were computed by the FME solver outside the device.
        axes[0].plot(times, [float(r["scatter"])/max(float(r["incident"]), 1e-300) for r in rows], label=LABELS[case])
        axes[1].plot(times, [float(r["energy"]) for r in rows], label=LABELS[case])
    axes[0].set(xlabel="Time", ylabel="Scattered / incident field energy outside r > R2 + 0.5", yscale="log", ylim=(1e-7, 2))
    axes[1].set(xlabel="Time", ylabel="Electromagnetic energy")
    axes[0].legend(frameon=False)
    fig.savefig(args.output / "scattering.png", dpi=140)
    print(args.output, flush=True)


if __name__ == "__main__":
    main()
