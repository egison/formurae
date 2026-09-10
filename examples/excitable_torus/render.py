#!/usr/bin/env python3
"""Render saved solver output; all NumPy computations here are for display.

Requires numpy, matplotlib, pillow; video also requires ffmpeg or
imageio-ffmpeg. No rendered data is fed back into the simulation.
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
from matplotlib.collections import PolyCollection
from matplotlib.colors import Normalize

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LABELS = {"isotropic": "Isotropic", "oblique": "Anisotropic / fixed direction",
          "twisted": "Anisotropic / varying direction"}
DETAILS = {"isotropic": "Equal diffusion in every direction",
           "oblique": "4 : 1 diffusion, fibers at 45 degrees",
           "twisted": "4 : 1 diffusion, fibers turn across the tube"}
RECORD = np.dtype([("i", "=i4"), ("j", "=i4"), ("u", "=f8"), ("v", "=f8")])
NORM = Normalize(-2.1, 2.1)
CMAP = plt.get_cmap("magma")


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
        result[data["i"], data["j"]] = data["u"]
    if result is None or not np.isfinite(result).all():
        raise ValueError(f"missing or invalid frame: {directory}, step {step}")
    return result


def surface(ax, shape):
    """Fixed orthographic mesh; depth ordering and lighting are display only."""
    nx, ny = shape
    rows = np.arange(0, nx, 2)
    cols = np.arange(0, ny, 2)
    theta, phi = np.meshgrid(rows * 2*np.pi/nx, cols * 2*np.pi/ny, indexing="ij")
    x = (2 + np.cos(theta)) * np.cos(phi)
    y = (2 + np.cos(theta)) * np.sin(phi)
    z = np.sin(theta)
    az, tilt = -0.65, 0.92
    xx = np.cos(az)*x - np.sin(az)*y
    yy = np.sin(az)*x + np.cos(az)*y
    view = np.stack((xx, np.cos(tilt)*yy - np.sin(tilt)*z,
                     np.sin(tilt)*yy + np.cos(tilt)*z), axis=-1)
    corners = np.stack([view, np.roll(view, -1, axis=0),
                        np.roll(np.roll(view, -1, axis=0), -1, axis=1),
                        np.roll(view, -1, axis=1)], axis=-2).reshape(-1, 4, 3)
    order = np.argsort(corners[:, :, 2].mean(axis=1))
    light = np.clip(0.78 + 0.16*np.cos(theta) * np.cos(phi-1) + 0.1*np.sin(theta), 0.55, 1)
    collection = PolyCollection(corners[order, :, :2], edgecolors="none", antialiased=False)
    ax.add_collection(collection)
    ax.set(xlim=(-3.2, 3.2), ylim=(-2.65, 2.65), aspect="equal")
    ax.axis("off")

    def update(u):
        sampled = u[np.ix_(rows, cols)]
        colors = CMAP(NORM(sampled))
        colors[..., :3] *= light[..., None]
        collection.set_facecolor(colors.reshape(-1, 4)[order])
    return update


def unfolded(ax, u):
    centered = np.roll(u, (u.shape[0]//2, u.shape[1]//2), axis=(0, 1))
    image = ax.imshow(centered, origin="lower", extent=(-180, 180, -180, 180),
                      aspect="auto", cmap=CMAP, norm=NORM, interpolation="bilinear")
    ax.set(xlabel="Around the hole, phi (degrees)", ylabel="Around the tube, theta (degrees)",
           xticks=[-180, -90, 0, 90, 180], yticks=[-180, -90, 0, 90, 180])
    ax.tick_params(labelsize=8)
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / ".build/excitable_torus/demo")
    parser.add_argument("--output", type=Path, default=HERE / "results")
    parser.add_argument("--time", type=float, default=80.0)
    parser.add_argument("--video", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = list(LABELS)
    directories = [args.input / case for case in cases]
    metadata = [json.loads((directory / "metadata.json").read_text()) for directory in directories]
    provenance = {case: meta | {"run_log": (directory / "run.log").read_text().strip()}
                  for case, meta, directory in zip(cases, metadata, directories)}
    (args.output / "runs.json").write_text(json.dumps(provenance, indent=2) + "\n")
    dt = float(metadata[0]["parameters"]["dt"])
    stamps = sorted({int(path.name.split("-")[1]) for path in (directories[0]/"data").glob("*.bin")})
    for m in metadata:
        if float(m["parameters"]["dt"]) != dt or m["grid"] != metadata[0]["grid"]:
            raise ValueError("comparison requires matching times and grids")
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "savefig.facecolor": "#fafafa", "figure.facecolor": "#fafafa"})
    fig = plt.figure(figsize=(14, 8))
    grid = fig.add_gridspec(2, 3, height_ratios=[1.25, 1],
                           left=0.055, right=0.99, bottom=0.21, top=0.87,
                           hspace=0.17, wspace=0.20)
    title = fig.suptitle("Excitable waves on a torus", fontsize=19, fontweight="bold", y=0.98)
    surfaces, maps = [], []
    for i, (case, directory) in enumerate(zip(cases, directories)):
        u = load_field(directory, stamps[0])
        ax = fig.add_subplot(grid[0, i])
        ax.set_title(LABELS[case] + "\n" + DETAILS[case], fontsize=11)
        surfaces.append(surface(ax, u.shape))
        maps.append(unfolded(fig.add_subplot(grid[1, i]), u))
    cbar = fig.colorbar(plt.cm.ScalarMappable(norm=NORM, cmap=CMAP),
                        cax=fig.add_axes([0.33, 0.075, 0.36, 0.025]), orientation="horizontal")
    cbar.set_label("Activator u  |  dark: recovering / resting, bright: excited")

    def draw(step):
        title.set_text(f"Excitable waves on a torus   |   t = {step*dt:.1f}")
        for directory, update, image in zip(directories, surfaces, maps):
            u = load_field(directory, step)
            update(u)
            image.set_data(np.roll(u, (u.shape[0]//2, u.shape[1]//2), axis=(0, 1)))

    selected = min(stamps, key=lambda step: abs(step*dt-args.time))
    draw(selected)
    fig.savefig(args.output / "comparison.png", dpi=140)
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
                if i % 20 == 0:
                    print(f"video {i+1}/{len(stamps)}", flush=True)
    plt.close(fig)

    fig, axes = plt.subplots(3, 4, figsize=(14, 9), layout="constrained")
    requested = [12, 24, 60, 120]
    for row, directory in enumerate(directories):
        for col, moment in enumerate(requested):
            step = min(stamps, key=lambda step: abs(step*dt-moment))
            ax = axes[row, col]
            unfolded(ax, load_field(directory, step))
            ax.set_title(f"t = {step*dt:g}")
            if row != 2:
                ax.set_xlabel("")
            if col:
                ax.set_ylabel("")
            else:
                ax.set_ylabel(LABELS[cases[row]] + "\ntheta (degrees)")
    fig.suptitle("The same stimulus, three diffusion tensors", fontsize=18, fontweight="bold")
    fig.savefig(args.output / "timeline.png", dpi=140)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 4), layout="constrained")
    for case, directory in zip(cases, directories):
        with (directory / "stats.csv").open() as file:
            rows = list(csv.DictReader(file))
        # Both area and its threshold u > 0 were computed by the FME solver.
        ax.plot([int(r["step"])*dt for r in rows], [float(r["active"]) for r in rows], label=LABELS[case])
    ax.set(xlabel="Time", ylabel="Excited surface area (u > 0)", title="Continued excitation after the initial stimulus")
    ax.legend(frameon=False)
    fig.savefig(args.output / "activity.png", dpi=140)
    print(args.output, flush=True)


if __name__ == "__main__":
    main()
