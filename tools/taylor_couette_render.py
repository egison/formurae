"""Render saved Formurae Taylor--Couette velocities; never synthesize patterns."""
import argparse
import json
import os

import imageio_ffmpeg
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.colors import Normalize
from matplotlib.font_manager import FontProperties
from matplotlib.patches import Ellipse
import numpy as np

from taylor_couette import ROOT, WORK, RESULTS


def render_unwrapped(data, reports, output, norm, cmap):
    fig, axes = plt.subplots(1, len(data), figsize=(4.4*len(data), 5.2),
                             sharey=True, layout='constrained', squeeze=False)
    for ax, d, report in zip(axes[0], data, reports):
        velocity = d['velocity'][-1]
        im = ax.imshow(velocity[0, velocity.shape[1]//2].T, origin='lower',
                       extent=[0, 360, 0, float(d['length'])], aspect='auto',
                       interpolation='nearest', cmap=cmap, norm=norm)
        ax.set_title(f'Re = {report["reynolds"]:g}　t U/d = {d["time"][-1]:.0f}')
        ax.set(xlabel='円周方向の角度（度）', xticks=[0, 90, 180, 270, 360])
    axes[0, 0].set_ylabel('軸方向 z / 隙間幅')
    fig.suptitle('半径中央の円筒面を一周分ひらいた流れ', fontsize=17)
    fig.colorbar(im, ax=list(axes[0]), shrink=.85, extend='both',
                 label='半径方向の速度 / 内壁速度')
    fig.savefig(output/'azimuthal-patterns.png', dpi=160)
    plt.close(fig)


def render(names):
    output = ROOT/'gallery/taylor-couette'
    output.mkdir(parents=True, exist_ok=True)
    font = '/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc'
    if os.path.exists(font):
        plt.rcParams['font.family'] = FontProperties(fname=font).get_name()
    plt.rcParams.update({'font.size': 10, 'axes.unicode_minus': False,
                         'figure.facecolor': '#f4f6fa', 'axes.facecolor': '#ffffff',
                         'text.color': '#162437', 'axes.labelcolor': '#162437'})
    data = []
    for name in names:
        with np.load(WORK/name/'frames.npz') as archive:
            data.append({key:archive[key] for key in archive.files})
    reports = [json.loads((RESULTS/f'taylor-couette-{name}.json').read_text()) for name in names]
    count = len(names)
    fig = plt.figure(figsize=(4.4*count, 8.3), dpi=120)
    fig.text(.05, .955, '回転速度で変わるテイラー・クエット流れ', fontsize=20, weight='bold')
    fig.text(.05, .916, 'Formurae の三次元計算｜Re は回転速度に比例する無次元数｜半径比 0.75・外筒固定・上下は周期境界', fontsize=11)
    cmap, norm = plt.get_cmap('RdBu_r'), Normalize(-.15, .15)
    artists = []
    for c, (d, report) in enumerate(zip(data, reports)):
        x = .045+c*.92/count
        width = .92/count
        re = int(report['reynolds'])
        fig.text(x, .87, f'Re = {re}  ｜  回転 {re/60:g} 倍', fontsize=16, weight='bold')
        descriptions = {60:'円周に沿う流れ：渦が減衰', 150:'ほぼ輪状のテイラー渦', 600:'円周方向に波打って移動する渦'}
        fig.text(x, .837, descriptions.get(re, '保存された三次元の速度場'), fontsize=11)
        ax = fig.add_axes([x, .37, width*.46, .425])
        sec = fig.add_axes([x+width*.60, .37, width*.32, .425])
        ntheta, nz = d['velocity'].shape[-2:]
        t = np.linspace(-np.pi/2, np.pi/2, ntheta//2+1)
        z = np.linspace(0, float(d['length']), nz+1)
        indices = ((np.arange(ntheta//2)-ntheta//4) % ntheta)
        nr = d['velocity'].shape[2]
        values = d['velocity'][0, 0, nr//2, indices].T
        T, Z = np.meshgrid(t, z)
        mesh = ax.pcolormesh(.45*np.sin(T), Z-.08*np.cos(T), values, shading='flat', cmap=cmap, norm=norm)
        ax.add_patch(Ellipse((0, z[-1]), .90, .16, facecolor='none', edgecolor='#77889c', lw=.8, zorder=4))
        ax.add_patch(Ellipse((0, 0), .90, .16, facecolor='none', edgecolor='#77889c', lw=.8, zorder=4))
        ax.set(xlim=(-.47, .47), ylim=(-.1, z[-1]+.1), xticks=[], ylabel='軸方向 z / 隙間幅')
        if c:
            ax.set_ylabel('')
            ax.tick_params(labelleft=False, left=False)
        ax.set_title('半径中央の円筒面', fontsize=10)
        ax.spines[['top', 'right', 'bottom']].set_visible(False)
        rr = d['radius']-3
        zz = (np.arange(nz)+.5)*float(d['length'])/nz
        slice_mesh = sec.imshow(d['velocity'][0, 0, :, 0].T, origin='lower',
                                extent=[0, 1, 0, z[-1]], aspect='auto', cmap=cmap, norm=norm)
        rs, zs = slice(1, nr, max(1, nr//6)), slice(1, nz, max(1, nz//16))
        XX, YY = np.meshgrid(rr[rs], zz[zs])
        arrows = sec.quiver(XX, YY, d['velocity'][0, 0, rs, 0, zs].T,
                            d['velocity'][0, 2, rs, 0, zs].T, angles='xy', scale_units='xy',
                            scale=.55, width=.009, color='#1c3047')
        sec.set(yticks=[], xticks=[0, 1], xticklabels=['内筒', '外筒'])
        sec.set_title('縦断面の流れ', fontsize=10)
        text = fig.text(x, .332, '', fontsize=9.5, va='top')
        artists.append((mesh, slice_mesh, arrows, text, indices, rs, zs))
    colorax = fig.add_axes([.36, .255, .28, .017])
    fig.colorbar(plt.cm.ScalarMappable(norm=norm, cmap=cmap), cax=colorax, orientation='horizontal', extend='both',
                 label='半径方向の速度 / 内壁速度　青：内向き　赤：外向き')
    history = fig.add_axes([.08, .105, .63, .085])
    cursors = []
    for report, color in zip(reports, ('#5479bd', '#b47c20', '#b84755', '#637f57')):
        t = [r['time'] for r in report['observations']]
        rms = [r['secondary_rms'] for r in report['observations']]
        history.semilogy(t, rms, color=color, label=f'Re={report["reynolds"]:g}')
        cursor, = history.plot([], [], 'o', color=color, markersize=5)
        cursors.append(cursor)
    history.set(xlabel='無次元時間  t U / d', ylabel='渦の速度の RMS', ylim=(1e-14, 1))
    history.grid(alpha=.15)
    history.legend(loc='center left', bbox_to_anchor=(1.02, .5), frameon=False)
    fig.text(.05, .025, 'U は内壁速度、d は隙間幅。RMS は二乗平均平方根。色と矢印は計算値で、各列を同じ無次元時刻で比較。', fontsize=9)
    nframes = min(len(d['time']) for d in data)
    def update(frame):
        for d, report, artist, cursor in zip(data, reports, artists, cursors):
            mesh, section, arrows, text, indices, rs, zs = artist
            v = d['velocity'][frame]
            mesh.set_array(v[0, v.shape[1]//2, indices].T)
            section.set_data(v[0, :, 0].T)
            arrows.set_UVC(v[0, rs, 0, zs].T, v[2, rs, 0, zs].T)
            r = report['observations'][frame]
            mean_swirl = np.average(v[1].mean(axis=(1, 2)), weights=d['radius'])
            text.set_text(f't U/d = {r["time"]:.1f}　円周方向の平均速度 {mean_swirl:.2f} U\n渦の速度 {r["secondary_rms"]:.3g}　円周方向の変動 {r["nonaxisymmetric_rms"]:.3g}')
            cursor.set_data([r['time']], [r['secondary_rms']])
    update(nframes-1)
    fig.savefig(output/'comparison.png', dpi=160)
    matplotlib.rcParams['animation.ffmpeg_path'] = imageio_ffmpeg.get_ffmpeg_exe()
    writer = FFMpegWriter(fps=15, codec='libx264', bitrate=2200,
                         extra_args=['-pix_fmt', 'yuv420p', '-threads', '2', '-movflags', '+faststart'])
    with writer.saving(fig, str(output/'comparison.mp4'), dpi=120):
        for i in range(nframes):
            update(i)
            writer.grab_frame()
    plt.close(fig)
    render_unwrapped(data, reports, output, norm, cmap)
    print(output/'comparison.mp4')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='+')
    render(parser.parse_args().names)
