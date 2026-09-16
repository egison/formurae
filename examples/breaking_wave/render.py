#!/usr/bin/env python3
"""Render saved water fractions. This script never evolves the simulation."""
import argparse
from pathlib import Path
import subprocess
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PAPER = "#eee6d4"
INK = "#123a60"


def read(path):
    with Path(path).open("rb") as file:
        nx, ny, step = np.fromfile(file, dtype="=i4", count=3)
        records = np.fromfile(file, dtype=np.dtype([("i", "=i4"), ("j", "=i4"),
                                                   ("values", "=f8", (7,))]))
        if len(records) != nx*ny:
            raise ValueError(f"incomplete frame: {path}")
        data = np.empty((nx, ny, 7))
        data[records["i"], records["j"]] = records["values"]
    return int(step), data


def draw(ax, data, step, limits=None):
    nx, ny, _ = data.shape
    water, _, wall = np.moveaxis(data[:, :, :3], 2, 0)
    ax.set_facecolor(PAPER)
    # Interpolation, contours and colors are exclusively for display.
    rgba = np.zeros((ny, nx, 4))
    rgba[:, :, :3] = matplotlib.colors.to_rgb(INK)
    rgba[:, :, 3] = np.clip(water.T, 0, 1)
    ax.imshow(rgba, origin="lower", extent=(-.5, nx-.5, -.5, ny-.5),
              interpolation="bilinear")
    coast = np.zeros_like(rgba)
    coast[:, :, :3] = matplotlib.colors.to_rgb("#c4b69a")
    coast[:, :, 3] = wall.T
    ax.imshow(coast, origin="lower", extent=(-.5, nx-.5, -.5, ny-.5),
              interpolation="nearest")
    surface = np.ma.array(water.T, mask=wall.T > .5)
    ax.contour(surface, levels=[.5], colors=["#fffdf2"], linewidths=1.2)
    ax.set_xlim(*(limits[:2] if limits else (3, nx-4)))
    ax.set_ylim(*(limits[2:] if limits else (3, ny-4)))
    ax.set_aspect("equal")
    ax.set_title(f"step {step:,}", loc="left", color=INK, fontsize=10)
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_visible(False)


def render(directory, output, video=True, snapshot_step=None):
    directory, output = Path(directory), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    files = sorted((directory / "data").glob("frame-*.bin"))
    if not files:
        raise ValueError("no frames")
    indices = np.linspace(0, len(files)-1, 6).round().astype(int)
    fig, axes = plt.subplots(3, 2, figsize=(12, 9), facecolor=PAPER)
    for ax, index in zip(axes.flat, indices):
        step, data = read(files[index])
        draw(ax, data, step)
    fig.suptitle("FORMURAE  /  A BREAKING WAVE", color=INK, fontsize=20, x=.07, ha="left")
    fig.text(.07, .025, "2D free-surface flow  ·  gravity and a sloping seabed\n"
             "White line: computed water surface; sand: fixed seabed", color=INK, fontsize=10)
    fig.subplots_adjust(left=.04, right=.98, bottom=.09, top=.92, hspace=.25, wspace=.08)
    fig.savefig(output / "sequence.png", dpi=160, facecolor=PAPER)
    plt.close(fig)
    if snapshot_step is not None:
        step, data = read(directory / "data" / f"frame-{snapshot_step:07d}.bin")
        fig, ax = plt.subplots(figsize=(12, 5), facecolor=PAPER)
        draw(ax, data, step)
        fig.suptitle("FORMURAE  /  A BREAKING WAVE", color=INK, fontsize=19,
                     x=.06, ha="left")
        fig.text(.06, .03, "2D free-surface simulation · gravity and a sloping seabed",
                 color=INK, fontsize=10)
        fig.subplots_adjust(left=.04, right=.98, bottom=.10, top=.88)
        fig.savefig(output / "wave.png", dpi=160, facecolor=PAPER)
        plt.close(fig)
    if video:
        fig, ax = plt.subplots(figsize=(12, 6), dpi=120, facecolor=PAPER)
        fig.subplots_adjust(left=.04, right=.96, bottom=.09, top=.88)
        fig.text(.04, .95, "FORMURAE  /  A BREAKING WAVE", color=INK, fontsize=19, va="top")
        fig.text(.04, .035, "Computed free surface · 2D water tank · all dynamics in Formurae",
                 color=INK, fontsize=10)
        width, height = fig.canvas.get_width_height()
        command = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-vcodec", "rawvideo",
                   "-pix_fmt", "rgba", "-s", f"{width}x{height}", "-r", "12", "-i", "-",
                   "-an", "-vcodec", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
                   "-movflags", "+faststart", str(output / "breaking-wave.mp4")]
        with subprocess.Popen(command, stdin=subprocess.PIPE) as encoder:
            for path in files:
                ax.clear()
                step, data = read(path)
                draw(ax, data, step)
                fig.canvas.draw()
                encoder.stdin.write(fig.canvas.buffer_rgba())
            encoder.stdin.close()
            if encoder.wait():
                raise RuntimeError("ffmpeg failed")
        plt.close(fig)
    print(output / "sequence.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", default=ROOT / ".build/breaking_wave/demo")
    parser.add_argument("--output", type=Path, default=HERE / "results")
    parser.add_argument("--no-video", action="store_true")
    parser.add_argument("--snapshot-step", type=int)
    args = parser.parse_args()
    render(args.directory, args.output, not args.no_video, args.snapshot_step)


if __name__ == "__main__":
    main()
