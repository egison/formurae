#!/usr/bin/env python3
"""Draw isosurfaces of saved 3D water fractions; no simulation is done here."""
import argparse
import csv
from pathlib import Path
import subprocess
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import to_rgb
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from skimage.measure import marching_cubes
from scipy.ndimage import map_coordinates

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PAPER = '#eee6d4'
INK = '#123a60'


def read(path):
    with Path(path).open('rb') as f:
        nx, ny, nz, step = np.fromfile(f, dtype='=i4', count=4)
        records = np.fromfile(f, dtype=np.dtype([
            ('index', '=i4', (3,)), ('values', '=f4', (2,))]))
    if len(records) != nx * ny * nz:
        raise ValueError(f'incomplete frame: {path}')
    data = np.empty((nx, ny, nz, 2), dtype=np.float32)
    data[tuple(records['index'].T)] = records['values']
    return int(step), data


def mesh(ax, values, color, mask=None, offset=(0,0,0), wall=None):
    if not values.min() < .5 < values.max():
        return
    vertices, faces, _, _ = marching_cubes(values, level=.5, mask=mask,
                                            allow_degenerate=False)
    if wall is not None:
        # Omit the water/solid boundary: only the water/air surface is blue.
        near_wall = map_coordinates(wall, vertices.T, order=1, mode='nearest') > .01
        faces = faces[~near_wall[faces].any(axis=1)]
    # The simulation uses y for height; Matplotlib's vertical axis is z.
    triangles = (vertices + np.array(offset))[:, [0, 2, 1]][faces]
    normals = np.cross(triangles[:, 1]-triangles[:, 0], triangles[:, 2]-triangles[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1)[:, None], 1e-12)
    light = np.array([-.3, -.5, 1.])
    light /= np.linalg.norm(light)
    intensity = np.clip(np.abs(np.sum(normals * light, axis=1)), 0, 1)
    base = np.array(to_rgb(color))
    colors = np.clip(base[None, :] * (.55 + .5*intensity[:, None])
                     + .14*intensity[:, None]**8, 0, 1)
    ax.add_collection3d(Poly3DCollection(triangles, facecolors=colors,
                                       edgecolors='none', antialiased=False))


def draw(fig, data, step):
    fig.clear()
    nx, ny, nz, _ = data.shape
    water, wall = data[..., 0], data[..., 1]
    ax = fig.add_axes([.01, .15, .73, .72], projection='3d', computed_zorder=False)
    ax.set_facecolor(PAPER)
    # The mesh follows fraction=0.5, including folds and disconnected surfaces.
    # Cut away the outer wall cells to expose the water in this view.
    visible = wall < .5
    visible[:3] = False
    visible[-3:] = False
    visible[:, :3] = False
    visible[:, -3:] = False
    mesh(ax, wall[3:-3, :ny-3, :], '#bbad90', offset=(3,0,0))
    # Keep the water mesh in the same coordinates as the saved fields.
    # Close the two displayed spanwise cuts so the occupied water volume is
    # visible. These caps are only a cutaway drawing of the saved occupancy.
    mesh(ax, np.pad(water, ((0,0),(0,0),(1,1))), '#22608c',
         np.pad(visible, ((0,0),(0,0),(1,1)), mode='edge'), offset=(0,0,-1),
         wall=np.pad(wall, ((0,0),(0,0),(1,1)), mode='edge'))
    ax.set_xlim(3, nx-4)
    ax.set_ylim(-.5, nz-.5)
    ax.set_zlim(2, ny-4)
    ax.set_box_aspect((nx-7, nz-1, ny-6), zoom=1.35)
    ax.view_init(elev=23, azim=-62)
    ax.set_axis_off()
    for bottom, z, label in ((.53, 0, 'Span z = 0'), (.2, nz//2, 'Span z = L/2')):
        cut = fig.add_axes([.75, bottom, .23, .25])
        cut.set_facecolor(PAPER)
        cut.imshow(water[:, :, z].T, origin='lower', cmap='Blues', vmin=0, vmax=1,
                   extent=(-.5,nx-.5,-.5,ny-.5), interpolation='bilinear')
        coast = np.zeros((ny,nx,4))
        coast[..., :3] = to_rgb('#bbad90')
        coast[..., 3] = wall[:, :, z].T
        cut.imshow(coast, origin='lower', interpolation='nearest',
                   extent=(-.5,nx-.5,-.5,ny-.5))
        cut.contour(np.ma.array(water[:, :, z].T, mask=wall[:, :, z].T>.5),
                    levels=[.5], colors=['#fffdf2'], linewidths=.8)
        # Frame the crest in each saved image; this only chooses the view.
        occupied = np.argwhere(water[:, :, z] > .5)
        top = int(occupied[:, 1].max())
        crest = float(np.median(occupied[occupied[:, 1] == top, 0]))
        left = max(3, min(crest-32, nx-60))
        bottom_edge = max(3, min(top-27, ny-38))
        cut.set_xlim(left, min(left+56, nx-4))
        cut.set_ylim(bottom_edge, min(bottom_edge+34, ny-4))
        cut.set_title(label + ' / crest detail', fontsize=10, color=INK, loc='left')
        cut.set_xticks([])
        cut.set_yticks([])
        for s in cut.spines.values(): s.set_visible(False)
    fig.text(.045,.95,'FORMURAE / A THREE-DIMENSIONAL BREAKING WAVE',
             fontsize=19, color=INK, va='top')
    fig.text(.045,.892,f'D3Q19  |  {nx} × {ny} × {nz} grid points  |  step {step:,}',
             fontsize=11, color=INK)
    fig.text(.045,.095,'Water surface: computed fraction = 0.5.  Gravity + sloping seabed.',
             fontsize=10, color=INK)
    fig.text(.045,.057,'Periodic span; height and crest position vary across the span.  All dynamics in Formurae.',
             fontsize=10, color=INK)


def render(directory, output, video=True, snapshot_step=None):
    directory, output = Path(directory), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    files = sorted((directory/'data').glob('frame-*.bin'))
    if not files: raise ValueError('no frames')
    if snapshot_step is None:
        snapshot_step = int(files[-1].stem.split('-')[-1])
        if (directory/'stats.csv').exists():
            with (directory/'stats.csv').open() as f:
                peak = max(csv.DictReader(f), key=lambda row:float(row['overhang']))
            if float(peak['overhang']) > 0:
                snapshot_step = int(peak['step'])
    step, data = read(directory/'data'/f'frame-{snapshot_step:07d}.bin')
    fig = plt.figure(figsize=(12.8,7.2), dpi=120, facecolor=PAPER)
    draw(fig,data,step)
    fig.savefig(output/'wave3d.png',facecolor=PAPER)
    if video:
        width,height = fig.canvas.get_width_height()
        command=['ffmpeg','-y','-loglevel','error','-f','rawvideo','-vcodec','rawvideo',
                 '-pix_fmt','rgba','-s',f'{width}x{height}','-r','5','-i','-',
                 '-an','-vcodec','libx264','-crf','19','-pix_fmt','yuv420p',
                 '-movflags','+faststart',str(output/'breaking-wave3d.mp4')]
        with subprocess.Popen(command,stdin=subprocess.PIPE) as encoder:
            for path in files:
                step,data=read(path)
                draw(fig,data,step)
                fig.canvas.draw()
                encoder.stdin.write(fig.canvas.buffer_rgba())
            encoder.stdin.close()
            if encoder.wait(): raise RuntimeError('ffmpeg failed')
    plt.close(fig)
    print(output/'wave3d.png')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',nargs='?',type=Path,default=ROOT/'.build/breaking_wave3d/demo')
    p.add_argument('--output',type=Path,default=HERE/'results')
    p.add_argument('--no-video',action='store_true')
    p.add_argument('--snapshot-step',type=int)
    a=p.parse_args()
    render(a.directory,a.output,not a.no_video,a.snapshot_step)


if __name__=='__main__': main()
