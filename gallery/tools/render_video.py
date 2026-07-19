# -*- coding: utf-8 -*-
"""Render real simulation frames from gallery/data and encode gallery/video.

Run gallery/gen.sh first.  ffmpeg is used only for the final H.264 encoding;
all numerical field rendering continues to use the standard-library renderer.
"""
import glob
import math
import os
import re
import shutil
import subprocess
import tempfile

import render

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, '..', 'data')
VIDEO = os.path.join(HERE, '..', 'video')
FRAME_RE = re.compile(r'_v(\d+)_t(\d+)\.(?:mat|txt)$')


def video_files(name, infix='', extension='mat'):
    pattern = os.path.join(DATA, '%s%s_v????_t*.%s'
                           % (name, infix, extension))
    files = glob.glob(pattern)
    files.sort(key=lambda path: int(FRAME_RE.search(path).group(1)))
    if not files:
        raise RuntimeError('no video data for %s%s; run gallery/gen.sh first'
                           % (name, infix))
    return files


def value_range(mats, symmetric=False):
    lo = min(min(min(row) for row in matrix) for matrix in mats)
    hi = max(max(max(row) for row in matrix) for matrix in mats)
    if symmetric:
        bound = max(abs(lo), abs(hi)) or 1.0
        return -bound, bound
    return lo, hi


def ffmpeg_executable():
    configured = os.environ.get('FFMPEG')
    if configured:
        return configured
    found = shutil.which('ffmpeg')
    if found:
        return found
    raise RuntimeError(
        'ffmpeg was not found; install it or set FFMPEG=/path/to/ffmpeg')


def encode(name, render_frames):
    os.makedirs(VIDEO, exist_ok=True)
    output = os.path.join(VIDEO, name + '.mp4')
    with tempfile.TemporaryDirectory(prefix='formurae-%s-' % name) as frames:
        count = render_frames(frames)
        subprocess.run([
            ffmpeg_executable(), '-y', '-loglevel', 'error',
            '-framerate', '12', '-i', os.path.join(frames, '%04d.png'),
            '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p',
            '-c:v', 'libx264', '-crf', '25', '-preset', 'medium',
            '-movflags', '+faststart', output,
        ], check=True)
    print('video:', name, '(%d frames)' % count)


def heatmap_video(name, source=None, anchors=render.VIRIDIS, symmetric=False,
                  target=420):
    files = video_files(source or name)
    mats = [render.mat(os.path.basename(path)) for path in files]
    rng = value_range(mats, symmetric)

    def frames(outdir):
        for i, matrix in enumerate(mats):
            render.heatmap(matrix, os.path.join(outdir, '%04d.png' % i),
                           anchors=anchors, target=target, rng=rng)
        return len(mats)
    encode(name, frames)


def draw_line(image, x0, y0, x1, y1, color, width=2):
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    error = dx - dy
    while True:
        for oy in range(-width + 1, width):
            for ox in range(-width + 1, width):
                px, py = x0 + ox, y0 + oy
                if 0 <= py < len(image) and 0 <= px < len(image[0]):
                    image[py][px] = color
        if x0 == x1 and y0 == y1:
            break
        twice = 2 * error
        if twice > -dy:
            error -= dy
            x0 += sx
        if twice < dx:
            error += dx
            y0 += sy


def line_video(name, source=None, column=1, symmetric=False):
    files = video_files(source or name, extension='txt')
    tables = [render.cols(os.path.basename(path)) for path in files]
    xlo = min(min(table[0]) for table in tables)
    xhi = max(max(table[0]) for table in tables)
    ylo = min(min(table[column]) for table in tables)
    yhi = max(max(table[column]) for table in tables)
    if symmetric:
        bound = max(abs(ylo), abs(yhi)) or 1.0
        ylo, yhi = -bound, bound
    width, height = 560, 330
    left, right, top, bottom = 44, 14, 16, 30
    plot_width = width - left - right
    plot_height = height - top - bottom

    def frames(outdir):
        for frame, table in enumerate(tables):
            image = [[(255, 255, 255)] * width for _ in range(height)]
            for tick in range(6):
                x = left + round(plot_width * tick / 5)
                y = top + round(plot_height * tick / 5)
                draw_line(image, x, top, x, top + plot_height,
                          (229, 232, 236), width=1)
                draw_line(image, left, y, left + plot_width, y,
                          (229, 232, 236), width=1)
            draw_line(image, left, top, left, top + plot_height,
                      (80, 86, 94), width=1)
            draw_line(image, left, top + plot_height,
                      left + plot_width, top + plot_height,
                      (80, 86, 94), width=1)
            points = []
            for xvalue, yvalue in zip(table[0], table[column]):
                x = left + round((xvalue - xlo) / (xhi - xlo or 1) * plot_width)
                y = top + plot_height - round(
                    (yvalue - ylo) / (yhi - ylo or 1) * plot_height)
                points.append((x, y))
            for (x0, y0), (x1, y1) in zip(points, points[1:]):
                draw_line(image, x0, y0, x1, y1, (31, 119, 180), width=2)
            render.write_png(os.path.join(outdir, '%04d.png' % frame), image)
        return len(tables)
    encode(name, frames)


def surface_video(name, source, embed_for, wrapx, wrapy, step,
                  az=0.55, ax=1.05):
    files = video_files(source)
    mats = [render.mat(os.path.basename(path)) for path in files]
    rng = value_range(mats)

    def frames(outdir):
        for i, matrix in enumerate(mats):
            render.surface3d(
                matrix, embed_for(matrix), os.path.join(outdir, '%04d.png' % i),
                wrapx=wrapx, wrapy=wrapy, az=az, ax=ax, target=380,
                step=step, rng=rng)
        return len(mats)
    encode(name, frames)


def torus_embed(matrix):
    ny, nx = len(matrix), len(matrix[0])
    def embed(cx, cy):
        th = 2 * math.pi * cx / nx
        ph = 2 * math.pi * cy / ny
        return ((2 + math.cos(th)) * math.cos(ph),
                (2 + math.cos(th)) * math.sin(ph), math.sin(th))
    return embed


def sphere_embed(matrix):
    ny, nx = len(matrix), len(matrix[0])
    def embed(cx, cy):
        th = 1.0 + 1.1415926535897931 * cx / nx
        ph = 2 * math.pi * cy / ny
        return (math.sin(th) * math.cos(ph),
                math.sin(th) * math.sin(ph), math.cos(th))
    return embed


def polar_embed(matrix):
    ny, nx = len(matrix), len(matrix[0])
    def embed(cx, cy):
        radius = 1.0 + cx / (nx - 1.0)
        ph = 2 * math.pi * cy / ny
        return (radius * math.cos(ph), radius * math.sin(ph), 0.0)
    return embed


def shell_video():
    files = video_files('shell', '_x')
    raw = [render.mat(os.path.basename(path)) for path in files]
    mats = [[[matrix[j][k] for j in range(len(matrix))]
             for k in range(len(matrix[0]))] for matrix in raw]
    rng = value_range(mats)

    def frames(outdir):
        for frame, matrix in enumerate(mats):
            ny, nx = len(matrix), len(matrix[0])
            def embed(cx, cy):
                th = 1.0 + 1.1415926535897931 * cx / (nx - 1.0)
                ph = 2 * math.pi * cy / ny
                return (2 * math.sin(th) * math.cos(ph),
                        2 * math.sin(th) * math.sin(ph), 2 * math.cos(th))
            render.surface3d(
                matrix, embed, os.path.join(outdir, '%04d.png' % frame),
                wrapx=False, wrapy=True, az=0.5, ax=1.15,
                target=380, step=2, rng=rng)
        return len(mats)
    encode('shell', frames)


def yinyang_video():
    yin_files = video_files('yy_yin')
    yang_files = video_files('yy_yang')
    if len(yin_files) != len(yang_files):
        raise RuntimeError('Yin and Yang video frame counts differ')
    pairs = [(render.mat(os.path.basename(a)), render.mat(os.path.basename(b)))
             for a, b in zip(yin_files, yang_files)]
    rng = value_range([matrix for pair in pairs for matrix in pair])

    def frames(outdir):
        gap = [rng[0]] * 3
        for i, (yin, yang) in enumerate(pairs):
            combined = [a + gap + b for a, b in zip(yin, yang)]
            render.heatmap(combined, os.path.join(outdir, '%04d.png' % i),
                           target=470, rng=rng)
        return len(pairs)
    encode('yinyang', frames)


def main():
    heatmap_video('diffusion', target=400)
    heatmap_video('diffusion2d', target=400)
    heatmap_video('sbpdiff2d', target=400)
    heatmap_video('mhd', target=400)
    heatmap_video('cahnhilliard', anchors=render.DIVERGE, symmetric=True,
                  target=400)
    heatmap_video('tdgl', target=400)
    heatmap_video('hyp', target=400)
    heatmap_video('pearson', target=400)
    line_video('ks', symmetric=True)
    surface_video('metric', 'metric', torus_embed, True, True, step=3)
    surface_video('sphere', 'sphere', sphere_embed, False, True, step=2,
                  az=0.5, ax=1.15)
    surface_video('polar', 'polar', polar_embed, False, True, step=2,
                  az=0.0, ax=1.25)
    shell_video()
    yinyang_video()
    print('rendered videos into', VIDEO)


if __name__ == '__main__':
    main()
