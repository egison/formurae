#!/usr/bin/env python3
"""Render saved solver output; all NumPy computations here are for display.

Requires numpy, matplotlib; video also requires ffmpeg or imageio-ffmpeg.
The director drawn as line segments is the eigenvector of the saved Q, a
display-only conversion. No rendered data is fed back into the simulation.
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
from matplotlib.collections import LineCollection, PolyCollection
from matplotlib.colors import Normalize

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LABELS = {"random": "Random start", "favored": "Four defects, +1/2 outside",
          "disfavored": "Four defects, +1/2 inside"}
DETAILS = {"random": "defects nucleate, sort and annihilate",
           "favored": "the curvature-preferred arrangement",
           "disfavored": "the opposite arrangement"}
RECORD = np.dtype([("i", "=i4"), ("j", "=i4"), ("q11", "=f8"), ("q12", "=f8"),
                   ("q22", "=f8"), ("order", "=f8"), ("winding", "=f8")])
NORM = Normalize(0.0, 1.05)
CMAP = plt.get_cmap("viridis")


def load_frame(directory, step):
    result = None
    for path in sorted((directory / "data").glob(f"frame-{step:07d}-rank-*.bin")):
        with path.open("rb") as file:
            nx, ny, stamp = np.fromfile(file, dtype="=i4", count=3)
            if stamp != step:
                raise ValueError("frame stamp mismatch")
            data = np.fromfile(file, dtype=RECORD)
        if result is None:
            result = {name: np.full((nx, ny), np.nan) for name in ("q11", "q12", "q22", "order", "winding")}
        for name in result:
            result[name][data["i"], data["j"]] = data[name]
    if result is None or not all(np.isfinite(v).all() for v in result.values()):
        raise ValueError(f"missing or invalid frame: {directory}, step {step}")
    return result


def director(frame, R, r):
    """Doubled director angle 2α from the saved tensor in the orthonormal frame."""
    nx, ny = frame["order"].shape
    theta = np.arange(nx)[:, None] * 2*np.pi/nx
    g11 = r*r
    g22 = (R + r*np.cos(theta))**2
    volume = r*(R + r*np.cos(theta))
    mx = g11*frame["q11"] - g22*frame["q22"]
    my = 2*volume*frame["q12"]
    return 0.5*np.arctan2(my, mx)


def surface(ax, shape, R, r):
    nx, ny = shape
    stride = max(1, nx // 48)
    rows = np.arange(0, nx, stride)
    cols = np.arange(0, ny, stride)
    theta, phi = np.meshgrid(rows*2*np.pi/nx, cols*2*np.pi/ny, indexing="ij")
    scale = 1.0 / R
    x = (R + r*np.cos(theta))*np.cos(phi)*scale
    y = (R + r*np.cos(theta))*np.sin(phi)*scale
    z = r*np.sin(theta)*scale
    az, tilt = -0.65, 0.92
    xx = np.cos(az)*x - np.sin(az)*y
    yy = np.sin(az)*x + np.cos(az)*y
    view = np.stack((xx, np.cos(tilt)*yy - np.sin(tilt)*z, np.sin(tilt)*yy + np.cos(tilt)*z), axis=-1)
    corners = np.stack([view, np.roll(view, -1, axis=0),
                        np.roll(np.roll(view, -1, axis=0), -1, axis=1),
                        np.roll(view, -1, axis=1)], axis=-2).reshape(-1, 4, 3)
    order = np.argsort(corners[:, :, 2].mean(axis=1))
    light = np.clip(0.78 + 0.16*np.cos(theta)*np.cos(phi-1) + 0.1*np.sin(theta), 0.55, 1)
    collection = PolyCollection(corners[order, :, :2], edgecolors="none", antialiased=False)
    ax.add_collection(collection)
    lines = LineCollection([], colors="white", linewidths=0.5)
    ax.add_collection(lines)
    plus = ax.scatter([], [], s=18, c="#ff5533", marker="o", zorder=5, edgecolors="black", linewidths=0.4)
    minus = ax.scatter([], [], s=18, c="#33aaff", marker="D", zorder=5, edgecolors="black", linewidths=0.4)
    lim = (R + r)*scale*1.05
    ax.set(xlim=(-lim, lim), ylim=(-lim*0.83, lim*0.83), aspect="equal")
    ax.axis("off")

    def project(th, ph):
        px = (R + r*np.cos(th))*np.cos(ph)*scale
        py = (R + r*np.cos(th))*np.sin(ph)*scale
        pz = r*np.sin(th)*scale
        qx = np.cos(az)*px - np.sin(az)*py
        qy = np.sin(az)*px + np.cos(az)*py
        return qx, np.cos(tilt)*qy - np.sin(tilt)*pz, np.sin(tilt)*qy + np.cos(tilt)*pz

    def update(frame):
        sampled = frame["order"][np.ix_(rows, cols)]
        colors = CMAP(NORM(sampled))
        colors[..., :3] *= light[..., None]
        collection.set_facecolor(colors.reshape(-1, 4)[order])
        # director segments on the visible (front) half
        alpha = director(frame, R, r)[np.ix_(rows, cols)]
        length = 0.55*stride*2*np.pi/nx
        dth = np.cos(alpha)*length
        dph = np.sin(alpha)*length*r/(R + r*np.cos(theta))
        a = project(theta - dth/2, phi - dph/2)
        b = project(theta + dth/2, phi + dph/2)
        front = ((a[2] + b[2]) > 0).reshape(-1)
        segments = np.stack([np.stack([a[0], a[1]], -1), np.stack([b[0], b[1]], -1)], -2).reshape(-1, 2, 2)
        lines.set_segments(segments[front])
        for artist, sign in ((plus, 1), (minus, -1)):
            ii, jj = np.nonzero(sign*frame["winding"] > 0.5)
            th, ph = (ii + 0.5)*2*np.pi/nx, (jj + 0.5)*2*np.pi/ny
            px, py, pz = project(th, ph)
            keep = pz > 0
            artist.set_offsets(np.stack([px[keep], py[keep]], -1) if keep.any() else np.empty((0, 2)))
    return update


def unfolded(ax, frame):
    image = ax.imshow(np.roll(frame["order"], (frame["order"].shape[0]//2, frame["order"].shape[1]//2), axis=(0, 1)),
                      origin="lower", extent=(-180, 180, -180, 180), aspect="auto", cmap=CMAP, norm=NORM,
                      interpolation="bilinear")
    plus = ax.scatter([], [], s=14, c="#ff5533", marker="o", edgecolors="black", linewidths=0.4)
    minus = ax.scatter([], [], s=14, c="#33aaff", marker="D", edgecolors="black", linewidths=0.4)
    ax.set(xlabel="Around the hole, phi (degrees)", ylabel="Around the tube, theta (degrees)",
           xticks=[-180, -90, 0, 90, 180], yticks=[-180, -90, 0, 90, 180])
    ax.tick_params(labelsize=8)

    def update(frame):
        nx, ny = frame["order"].shape
        image.set_data(np.roll(frame["order"], (nx//2, ny//2), axis=(0, 1)))
        for artist, sign in ((plus, 1), (minus, -1)):
            ii, jj = np.nonzero(sign*frame["winding"] > 0.5)
            th = ((ii + 0.5)*360/nx + 180) % 360 - 180
            ph = ((jj + 0.5)*360/ny + 180) % 360 - 180
            artist.set_offsets(np.stack([ph, th], -1) if len(ii) else np.empty((0, 2)))
    return update


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / ".build/nematic_torus/demo")
    parser.add_argument("--output", type=Path, default=HERE / "results")
    parser.add_argument("--time", type=float, default=30.0)
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
    R, r = (float(metadata[0]["parameters"][k]) for k in ("R", "r"))
    stamps = sorted({int(path.name.split("-")[1]) for path in (directories[0]/"data").glob("*.bin")})
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "savefig.facecolor": "#fafafa", "figure.facecolor": "#fafafa"})
    fig = plt.figure(figsize=(14, 8))
    grid = fig.add_gridspec(2, 3, height_ratios=[1.25, 1], left=0.055, right=0.99, bottom=0.21, top=0.87,
                           hspace=0.17, wspace=0.20)
    title = fig.suptitle("Nematic liquid crystal on a torus", fontsize=19, fontweight="bold", y=0.98)
    surfaces, maps = [], []
    for i, (case, directory) in enumerate(zip(cases, directories)):
        frame = load_frame(directory, stamps[0])
        ax = fig.add_subplot(grid[0, i])
        ax.set_title(LABELS[case] + "\n" + DETAILS[case], fontsize=11)
        surfaces.append(surface(ax, frame["order"].shape, R, r))
        maps.append(unfolded(fig.add_subplot(grid[1, i]), frame))
    cbar = fig.colorbar(plt.cm.ScalarMappable(norm=NORM, cmap=CMAP),
                        cax=fig.add_axes([0.33, 0.075, 0.36, 0.025]), orientation="horizontal")
    cbar.set_label("Nematic order |Q|²  (0 at a defect core)   ●  +1/2 defect   ◆  −1/2 defect")

    def draw(step):
        title.set_text(f"Nematic liquid crystal on a torus   |   t = {step*dt:.1f}")
        for directory, update_surface, update_map in zip(directories, surfaces, maps):
            frame = load_frame(directory, step)
            update_surface(frame)
            update_map(frame)

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

    fig, axes = plt.subplots(1, 3, figsize=(15, 4), layout="constrained")
    for case, directory in zip(cases, directories):
        with (directory / "stats.csv").open() as file:
            rows = list(csv.DictReader(file))[1:]
        times = [int(r["step"])*dt for r in rows]
        # Counts and energies are reductions computed by the FME solver.
        axes[0].plot(times, [float(r["plus"]) for r in rows], label=LABELS[case])
        axes[1].plot(times, [float(r["plusOuter"]) - float(r["minusOuter"]) for r in rows], label=LABELS[case])
        axes[2].plot(times, [float(r["energy"]) for r in rows], label=LABELS[case])
    axes[0].set(xlabel="Time", ylabel="Number of +1/2 defects (= number of −1/2)")
    axes[1].set(xlabel="Time", ylabel="(+1/2 outside) − (−1/2 outside)")
    axes[2].set(xlabel="Time", ylabel="Free energy")
    axes[0].legend(frameon=False)
    fig.savefig(args.output / "defects.png", dpi=140)
    print(args.output, flush=True)


if __name__ == "__main__":
    main()
