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


def compose(fig, data, step, metadata, rows):
    fig.clear()
    nx, ny, _ = data.shape
    parameters = metadata['parameters']
    beach = float(parameters['beachStart'])
    offshore = float(parameters['gaugeOffshoreX'])
    surf = float(parameters['gaugeSurfX'])
    overview = fig.add_axes([.05, .62, .90, .24])
    draw(overview, data, step)
    overview.set_title('THE WHOLE TANK', loc='left', color=INK, fontsize=11)
    for position, color in ((offshore, '#438fa3'), (surf, '#aa7046')):
        overview.axvline(position, color=color, linewidth=.9, linestyle='--', alpha=.75)
    if step == 0:
        center = float(parameters['center'])
        spacing = float(parameters['waveSpacing'])
        height = float(parameters['depth']) + float(parameters['amplitude']) + 4
        for number in range(int(float(parameters['waveCount']))):
            overview.text(center-number*spacing, height, str(number+1),
                          ha='center', color=INK, fontsize=11)
    close = fig.add_axes([.05, .18, .63, .36])
    draw(close, data, step, (max(3, beach-2*float(parameters['width'])), nx-4, 3, ny-4))
    close.set_title('THE BREAKING REGION', loc='left', color=INK, fontsize=11)

    gauge = fig.add_axes([.75, .20, .20, .31])
    gauge.set_facecolor(PAPER)
    for name, label, color in [('gauge_offshore', 'Offshore', '#438fa3'),
                               ('gauge_surf', 'Shallow water', '#aa7046')]:
        gauge.plot([r['step'] for r in rows], [r[name] for r in rows],
                   color=color, alpha=.20, linewidth=1)
        past = [r for r in rows if r['step'] <= step]
        gauge.plot([r['step'] for r in past], [r[name] for r in past],
                   color=color, linewidth=1.8, label=label)
    gauge.axvline(step, color=INK, linewidth=.8)
    gauge.set_xlim(0, rows[-1]['step'])
    gauge.set_ylim(0, max(r[k] for r in rows for k in ('gauge_offshore','gauge_surf'))*1.12)
    gauge.set_title('WATER AT TWO GAUGES', loc='left', fontsize=11, color=INK, pad=10)
    gauge.set_xlabel('Simulation step', fontsize=9, color=INK)
    gauge.set_ylabel('Water column (grid units)', fontsize=9, color=INK)
    gauge.tick_params(labelsize=8, colors=INK)
    gauge.spines[['top','right']].set_visible(False)
    gauge.spines[['bottom','left']].set_color('#b8ac94')
    gauge.grid(alpha=.15)
    gauge.legend(loc='upper right', frameon=False, fontsize=8)
    fig.text(.05,.95,'FORMURAE / THREE SUCCESSIVE WAVES', color=INK, fontsize=23, va='top')
    fig.text(.05,.898,f'2D free-surface flow   /   D2Q9   /   {nx} × {ny} grid points   /   step {step:,}',
             color=INK, fontsize=11)
    fig.text(.05,.075,'White contour: computed water surface.  Sand: fixed seabed.  Dashed lines: gauge locations.',
             color=INK, fontsize=10)
    fig.text(.05,.043,'Three initial crests advance toward the beach.  Initial conditions, flow and diagnostics are all computed in Formurae.',
             color=INK, fontsize=10)


def render(directory, output, video=True, snapshot_step=None, sequence_steps=None):
    directory, output = Path(directory), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    files = sorted((directory/'data').glob('frame-*.bin'))
    if not files:
        raise ValueError('no saved frames')
    metadata = json.loads((directory/'metadata.json').read_text())
    with (directory/'stats.csv').open() as f:
        rows = [{k:float(v) for k,v in row.items()} for row in csv.DictReader(f)]
    if snapshot_step is None:
        snapshot_step = int(max(rows,key=lambda r:r['shore_overhang'])['step'])
    fig = plt.figure(figsize=(16,9), dpi=100, facecolor=PAPER)
    step, data = read(directory/'data'/f'frame-{snapshot_step:07d}.bin')
    compose(fig,data,step,metadata,rows)
    fig.savefig(output/'wave-train.png',facecolor=PAPER)
    if video:
        width,height = fig.canvas.get_width_height()
        command=['ffmpeg','-y','-loglevel','error','-f','rawvideo','-vcodec','rawvideo',
                 '-pix_fmt','rgba','-s',f'{width}x{height}','-r','12','-i','-',
                 '-an','-vcodec','libx264','-crf','18','-pix_fmt','yuv420p',
                 '-movflags','+faststart',str(output/'wave-train.mp4')]
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
    if sequence_steps is None:
        indices = np.linspace(0,len(files)-1,6).round().astype(int)
        sequence_steps = [int(files[i].stem.split('-')[-1]) for i in indices]
    if len(sequence_steps) != 6:
        raise ValueError('six sequence steps required')
    fig, axes = plt.subplots(3,2,figsize=(13,8),facecolor=PAPER)
    for ax,step in zip(axes.flat,sequence_steps):
        saved_step,data = read(directory/'data'/f'frame-{step:07d}.bin')
        draw(ax,data,saved_step)
    fig.suptitle('FORMURAE / THREE SUCCESSIVE WAVES',x=.05,ha='left',fontsize=20,color=INK)
    fig.text(.05,.035,'Computed free surface: three crests moving toward a sloping seabed.',fontsize=10,color=INK)
    fig.subplots_adjust(left=.04,right=.98,bottom=.09,top=.90,wspace=.08,hspace=.24)
    fig.savefig(output/'sequence.png',dpi=150,facecolor=PAPER)
    plt.close(fig)
    (output/'rendering.json').write_text(json.dumps({'snapshot_step':snapshot_step,
          'sequence_steps':sequence_steps,'video_fps':12,'video_frames':len(files)},indent=2)+'\n')
    print(output/'wave-train.png')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',nargs='?',type=Path,default=ROOT/'.build/wave_train/demo')
    p.add_argument('--output',type=Path,default=HERE/'results')
    p.add_argument('--no-video',action='store_true')
    p.add_argument('--snapshot-step',type=int)
    p.add_argument('--sequence-steps',type=int,nargs=6)
    a=p.parse_args()
    render(a.directory,a.output,not a.no_video,a.snapshot_step,a.sequence_steps)


if __name__=='__main__': main()
