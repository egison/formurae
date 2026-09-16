#!/usr/bin/env python3
"""Render saved water fractions. This script never evolves the simulation."""
import argparse
import csv
import json
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
                                                   ("values", "=f8", (9,))]))
        if len(records) != nx*ny:
            raise ValueError(f"incomplete frame: {path}")
        data = np.empty((nx, ny, 9))
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


def compose(fig, data, step, metadata, rows):
    fig.clear()
    parameters = metadata["parameters"]
    nx, ny, _ = data.shape
    ax = fig.add_axes([.045, .32, .91, .52])
    draw(ax, data, step)
    ax.set_title(f"step {step:,}", loc="left", color=INK, fontsize=11)
    ax.axvline(float(parameters["gaugeX"]), color="#a47d51", ls="--", lw=1, alpha=.7)
    # Only display saved velocities in water-filled cells. The same arrow
    # scale and sample locations are used in every frame.
    spacing = max(6, nx//32)
    xs = np.arange(spacing, nx-spacing, spacing)
    vertical_spacing = max(4, ny//12)
    ys = np.arange(vertical_spacing, ny-vertical_spacing, vertical_spacing)
    x, y = np.meshgrid(xs, ys, indexing="ij")
    sampled = data[x, y]
    visible = (sampled[:,:,0] > .5) & (sampled[:,:,2] < .5)
    u, v = sampled[:,:,7], sampled[:,:,8]
    visible &= u*u+v*v > .002**2
    scale = 100*nx/384
    ax.quiver(x[visible], y[visible], scale*u[visible], scale*v[visible],
              angles="xy", scale_units="xy", scale=1, color="#f3ebd5",
              width=.0015, headwidth=3.5, headlength=4, alpha=.8)
    chart = fig.add_axes([.09,.12,.83,.12])
    chart.set_facecolor(PAPER)
    steps = [r['step'] for r in rows]
    flux = [r['shore_flux'] for r in rows]
    chart.plot(steps,flux,color=INK,alpha=.18,lw=1)
    past = [r for r in rows if r['step']<=step]
    chart.plot([r['step'] for r in past],[r['shore_flux'] for r in past],color=INK,lw=1.5)
    chart.fill_between(steps,flux,0,where=np.asarray(flux)<0,color="#aa7046",alpha=.12)
    chart.axhline(0,color="#8c806b",lw=.7)
    chart.axvline(step,color=INK,lw=.8)
    chart.set_xlim(0,rows[-1]['step'])
    chart.set_ylabel('Water flux',color=INK,fontsize=10)
    chart.set_xlabel('Simulation step',color=INK,fontsize=9)
    chart.tick_params(colors=INK,labelsize=8)
    chart.spines[['top','right']].set_visible(False)
    chart.spines[['bottom','left']].set_color('#b8ac94')
    fig.text(.045,.96,'FORMURAE / ONE WAVE, THEN BACKWASH',color=INK,fontsize=23,va='top')
    fig.text(.045,.91,'Breaking, beach run-up and return flow  /  2D free surface  /  '
             f'{nx} × {ny} grid points',color=INK,fontsize=11)
    fig.text(.09,.265,'NEARSHORE GAUGE   ·   positive: toward the beach   /   negative: returning offshore',
             color=INK,fontsize=10)
    fig.text(.045,.035,'White contour: computed surface.  Arrows: computed velocity.  Dashed line: gauge location.',
             color=INK,fontsize=10)


def render(directory, output, video=True, snapshot_step=None, sequence_steps=None):
    directory, output = Path(directory), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    files = sorted((directory / "data").glob("frame-*.bin"))
    if not files:
        raise ValueError("no frames")
    metadata = json.loads((directory/'metadata.json').read_text())
    with (directory/'stats.csv').open() as file:
        rows = [{k:float(v) for k,v in row.items()} for row in csv.DictReader(file)]
    if sequence_steps is None:
        indices = np.linspace(0,len(files)-1,6).round().astype(int)
        sequence_steps = [int(files[i].stem.split('-')[-1]) for i in indices]
    fig, axes = plt.subplots(3,2,figsize=(12,9),facecolor=PAPER)
    for ax,step in zip(axes.flat,sequence_steps):
        step,data = read(directory/'data'/f'frame-{step:07d}.bin')
        draw(ax,data,step)
    fig.suptitle('ONE WAVE / BREAKING, RUN-UP AND BACKWASH',color=INK,fontsize=19,x=.05,ha='left')
    fig.text(.05,.03,'Computed water surface and fixed seabed. No added waves or foam.',color=INK,fontsize=10)
    fig.subplots_adjust(left=.04,right=.98,bottom=.09,top=.92,hspace=.25,wspace=.08)
    fig.savefig(output/'sequence.png',dpi=160,facecolor=PAPER)
    plt.close(fig)
    if snapshot_step is None:
        snapshot_step = int(max(rows,key=lambda r:r['overhang'])['step'])
    fig = plt.figure(figsize=(16,9),dpi=100,facecolor=PAPER)
    step,data = read(directory/'data'/f'frame-{snapshot_step:07d}.bin')
    compose(fig,data,step,metadata,rows)
    fig.savefig(output/'wave.png',facecolor=PAPER)
    if video:
        width,height = fig.canvas.get_width_height()
        command = ['ffmpeg','-y','-loglevel','error','-f','rawvideo','-vcodec','rawvideo',
                   '-pix_fmt','rgba','-s',f'{width}x{height}','-r','12','-i','-',
                   '-an','-vcodec','libx264','-crf','18','-pix_fmt','yuv420p',
                   '-movflags','+faststart',str(output/'breaking-wave.mp4')]
        with subprocess.Popen(command,stdin=subprocess.PIPE) as encoder:
            for path in files:
                step,data = read(path)
                compose(fig,data,step,metadata,rows)
                fig.canvas.draw()
                encoder.stdin.write(fig.canvas.buffer_rgba())
            encoder.stdin.close()
            if encoder.wait():
                raise RuntimeError('ffmpeg failed')
    plt.close(fig)
    (output/'rendering.json').write_text(json.dumps(dict(snapshot_step=snapshot_step,
          sequence_steps=sequence_steps,video_fps=12,video_frames=len(files)),indent=2)+'\n')
    print(output/'wave.png')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path,nargs='?',default=ROOT/'.build/breaking_wave/demo')
    parser.add_argument('--output',type=Path,default=HERE/'results')
    parser.add_argument('--no-video',action='store_true')
    parser.add_argument('--snapshot-step',type=int)
    parser.add_argument('--sequence-steps',type=int,nargs=6)
    args = parser.parse_args()
    render(args.directory,args.output,not args.no_video,args.snapshot_step,args.sequence_steps)


if __name__ == '__main__':
    main()
