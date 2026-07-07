# -*- coding: utf-8 -*-
# Render gallery/data/ into gallery/img/ using only the Python standard
# library: a minimal PNG writer (zlib) for field maps and hand-rolled
# SVG for line plots.  Run gen.sh first.
import io, math, os, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, '..', 'data')
IMG = os.path.join(HERE, '..', 'img')
os.makedirs(IMG, exist_ok=True)

# ---------- PNG ----------

def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b''.join(b'\x00' + bytes(v for px in r for v in px) for r in rows)
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 6))
    png += chunk(b'IEND', b'')
    open(path, 'wb').write(png)

VIRIDIS = [(68,1,84),(72,40,120),(62,74,137),(49,104,142),(38,130,142),
           (31,158,137),(53,183,121),(109,205,89),(180,222,44),(253,231,37)]
DIVERGE = [(33,102,172),(103,169,207),(209,229,240),(247,247,247),
           (253,219,199),(239,138,98),(178,24,43)]

def cmap(t, anchors):
    t = min(1.0, max(0.0, t))
    x = t * (len(anchors) - 1)
    i = min(int(x), len(anchors) - 2)
    f = x - i
    a, b = anchors[i], anchors[i + 1]
    return tuple(int(round(a[c] + f * (b[c] - a[c]))) for c in range(3))

def heatmap(mat, out, anchors=VIRIDIS, sym=False, target=420):
    h, w = len(mat), len(mat[0])
    lo = min(min(r) for r in mat); hi = max(max(r) for r in mat)
    if sym:
        m = max(abs(lo), abs(hi)) or 1.0
        lo, hi = -m, m
    if hi - lo < 1e-300: hi = lo + 1.0
    sx = max(1, target // w); sy = max(1, target // h)
    rows = []
    for r in mat:
        line = []
        for v in r:
            line.extend([cmap((v - lo) / (hi - lo), anchors)] * sx)
        rows.extend([line] * sy)
    write_png(out, rows)
    return lo, hi

# ---------- SVG ----------

def _ticks(lo, hi, n=5):
    if hi <= lo: hi = lo + 1
    span = hi - lo
    step = 10 ** math.floor(math.log10(span / n))
    for m in (1, 2, 2.5, 5, 10):
        if span / (step * m) <= n + 1:
            step *= m
            break
    t0 = math.ceil(lo / step) * step
    ts, t = [], t0
    while t <= hi + 1e-12 * span:
        ts.append(0.0 if abs(t) < step * 1e-9 else t)
        t += step
    return ts

def svg_plot(out, series, title='', xlabel='', ylabel='', w=560, h=330):
    ml, mr, mt, mb = 62, 14, 30, 42
    pw, ph = w - ml - mr, h - mt - mb
    xs = [x for s in series for x in s['x']]
    ys = [y for s in series for y in s['y']]
    xlo, xhi = min(xs), max(xs)
    ylo, yhi = min(ys), max(ys)
    pad = 0.06 * (yhi - ylo or 1)
    ylo -= pad; yhi += pad
    def X(x): return ml + (x - xlo) / (xhi - xlo or 1) * pw
    def Y(y): return mt + ph - (y - ylo) / (yhi - ylo or 1) * ph
    o = io.StringIO()
    o.write('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
            'viewBox="0 0 %d %d" font-family="Helvetica,Arial,sans-serif">\n' % (w, h, w, h))
    o.write('<rect width="%d" height="%d" fill="#ffffff"/>\n' % (w, h))
    o.write('<text x="%d" y="19" font-size="14" fill="#222">%s</text>\n' % (ml, title))
    for t in _ticks(xlo, xhi):
        x = X(t)
        o.write('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="#e5e5e5"/>\n'
                % (x, mt, x, mt + ph))
        o.write('<text x="%.1f" y="%d" font-size="10" fill="#555" text-anchor="middle">%g</text>\n'
                % (x, mt + ph + 14, round(t, 10)))
    for t in _ticks(ylo, yhi):
        y = Y(t)
        o.write('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#e5e5e5"/>\n'
                % (ml, y, ml + pw, y))
        o.write('<text x="%d" y="%.1f" font-size="10" fill="#555" text-anchor="end">%g</text>\n'
                % (ml - 6, y + 3.5, round(t, 10)))
    o.write('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#888"/>\n'
            % (ml, mt, pw, ph))
    o.write('<text x="%d" y="%d" font-size="11" fill="#333" text-anchor="middle">%s</text>\n'
            % (ml + pw // 2, h - 8, xlabel))
    o.write('<text x="14" y="%d" font-size="11" fill="#333" text-anchor="middle" '
            'transform="rotate(-90 14 %d)">%s</text>\n' % (mt + ph // 2, mt + ph // 2, ylabel))
    for s in series:
        pts = ' '.join('%.2f,%.2f' % (X(x), Y(y)) for x, y in zip(s['x'], s['y']))
        dash = ' stroke-dasharray="6 4"' if s.get('dash') else ''
        o.write('<polyline points="%s" fill="none" stroke="%s" stroke-width="1.8"%s/>\n'
                % (pts, s['color'], dash))
    lx, lyy = ml + 10, mt + 12
    for s in series:
        if not s.get('label'): continue
        dash = ' stroke-dasharray="6 4"' if s.get('dash') else ''
        o.write('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="2"%s/>\n'
                % (lx, lyy - 3, lx + 22, lyy - 3, s['color'], dash))
        o.write('<text x="%d" y="%d" font-size="11" fill="#333">%s</text>\n'
                % (lx + 27, lyy, s['label']))
        lyy += 15
    o.write('</svg>\n')
    open(out, 'w').write(o.getvalue())

# ---------- readers ----------

def cols(name):
    xs, xss = [], None
    for line in open(os.path.join(DATA, name)):
        vs = [float(v) for v in line.split()]
        if xss is None: xss = [[] for _ in vs]
        for i, v in enumerate(vs): xss[i].append(v)
    return xss

def mat(name):
    return [[float(v) for v in line.split()]
            for line in open(os.path.join(DATA, name)) if line.strip()]

def pgm(name):
    d = open(os.path.join(DATA, name), 'rb').read()
    if d[:2] == b'P2':                      # ASCII
        toks = d.split()
        w, h, mx = int(toks[1]), int(toks[2]), int(toks[3])
        vals = [int(t) for t in toks[4:4 + w * h]]
        return [[vals[y * w + x] / mx for x in range(w)] for y in range(h)]
    parts = d.split(None, 4)                # P5 binary
    w, h, mx = int(parts[1]), int(parts[2]), int(parts[3])
    px = parts[4]
    return [[px[y * w + x] / mx for x in range(w)] for y in range(h)]

C1, C2, C3, C4 = '#1f77b4', '#d62728', '#2ca02c', '#9467bd'

def line_panel(out, files, labels, colors, title, ylabel, col=1, dashes=None, extra=None):
    series = []
    for i, f in enumerate(files):
        c = cols(f)
        series.append({'x': c[0], 'y': c[col], 'color': colors[i], 'label': labels[i],
                       'dash': dashes[i] if dashes else False})
    if extra: series += extra
    svg_plot(os.path.join(IMG, out), series, title=title, xlabel='x', ylabel=ylabel)

def main():
    # 1 diffusion: slices t0 / t100
    heatmap(mat('diffusion_t0.mat'), os.path.join(IMG, 'diffusion_t0.png'))
    heatmap(mat('diffusion_t100.mat'), os.path.join(IMG, 'diffusion_t100.png'))

    # 2 maxwell + yee: Ey pulse before/after
    line_panel('maxwell.svg', ['maxwell_t0.txt', 'maxwell_t100.txt'],
               ['Ey (t=0)', 'Ey (t=100dt)'], ['#999999', C1],
               'Maxwell (collocated): pulse propagation', 'Ey', dashes=[True, False])
    line_panel('yee.svg', ['yee_t0.txt', 'yee_t100.txt'],
               ['Ey (t=0)', 'Ey (t=100dt)'], ['#999999', C1],
               'Yee-FDTD: pulse +50 cells', 'Ey', dashes=[True, False])

    # 3 pearson (PGM from the check run)
    heatmap(pgm('pearson_V.pgm'), os.path.join(IMG, 'pearson.png'))

    # 4 burgers vs Cole-Hopf
    nu, k = 0.05, 2.0 * math.pi
    c0, c1 = cols('burgers_t0.txt'), cols('burgers_t5000.txt')
    E = math.exp(-nu * k * k * 0.5)
    ex = [2 * nu * k * E * math.sin(k * x) / (2 + E * math.cos(k * x)) for x in c1[0]]
    svg_plot(os.path.join(IMG, 'burgers.svg'),
             [{'x': c0[0], 'y': c0[1], 'color': '#999999', 'label': 'u (t=0)', 'dash': True},
              {'x': c1[0], 'y': c1[1], 'color': C1, 'label': 'u (t=0.5)'},
              {'x': c1[0], 'y': ex, 'color': C2, 'label': 'Cole-Hopf exact', 'dash': True}],
             title='Burgers vs Cole-Hopf exact (max err 3.5e-5)', xlabel='x', ylabel='u')

    # 5 cahn-hilliard
    heatmap(mat('cahnhilliard_t25000.mat'), os.path.join(IMG, 'ch.png'), DIVERGE, sym=True)

    # 6 tdgl |psi|^2
    heatmap(mat('tdgl_t4000.mat'), os.path.join(IMG, 'tdgl.png'))

    # 7 mhd rho
    heatmap(mat('mhd_t1250.mat'), os.path.join(IMG, 'mhd.png'))

    # 8 elastic P/S
    ce = cols('elastic_t600.txt'); ce0 = cols('elastic_t0.txt')
    svg_plot(os.path.join(IMG, 'elastic.svg'),
             [{'x': ce0[0], 'y': ce0[1], 'color': '#999999', 'label': 'vx (t=0)', 'dash': True},
              {'x': ce[0], 'y': ce[1], 'color': C1, 'label': 'vx : P wave (vp=2)'},
              {'x': ce[0], 'y': ce[2], 'color': C2, 'label': 'vy : S wave (vs=1)'}],
             title='Elastic (Virieux): P and S pulses separate', xlabel='x', ylabel='v')

    # 9 metric torus
    heatmap(mat('metric_t0.mat'), os.path.join(IMG, 'metric_t0.png'))
    heatmap(mat('metric_t3000.mat'), os.path.join(IMG, 'metric_t3000.png'))

    # 10 klein-gordon kinks
    k0, k1, k2 = cols('kg_t0.txt'), cols('kg_t400.txt'), cols('kg_t800.txt')
    svg_plot(os.path.join(IMG, 'kg.svg'),
             [{'x': k0[0], 'y': k0[1], 'color': '#bbbbbb', 'label': 'phi (t=0)'},
              {'x': k1[0], 'y': k1[1], 'color': C3, 'label': 'phi (t=20)'},
              {'x': k2[0], 'y': k2[1], 'color': C1, 'label': 'phi (t=40)'}],
             title='phi^4 kink-antikink at v=+-0.2', xlabel='x', ylabel='phi')

    # 11 shallow water
    s0, s1 = cols('sw_t0.txt'), cols('sw_t400.txt')
    svg_plot(os.path.join(IMG, 'sw.svg'),
             [{'x': s0[0], 'y': s0[1], 'color': '#999999', 'label': 'h (t=0)', 'dash': True},
              {'x': s1[0], 'y': s1[1], 'color': C1, 'label': 'h (t=20)'}],
             title='Shallow water: bump splits at c=sqrt(gh)=1', xlabel='x', ylabel='h')

    # 12 lbm shear wave decay
    l0, l1 = cols('lbm_t0.txt'), cols('lbm_t1000.txt')
    svg_plot(os.path.join(IMG, 'lbm.svg'),
             [{'x': l0[0], 'y': l0[1], 'color': '#999999', 'label': 'rho*u_y (t=0)', 'dash': True},
              {'x': l1[0], 'y': l1[1], 'color': C1, 'label': 'rho*u_y (t=1000)'}],
             title='LBM D3Q19 shear wave: decay -> nu=0.10010', xlabel='x', ylabel='rho u_y')

    # 13 acoustic
    a0, a1 = cols('acoustic_t0.txt'), cols('acoustic_t600.txt')
    svg_plot(os.path.join(IMG, 'acoustic.svg'),
             [{'x': a0[0], 'y': a0[1], 'color': '#999999', 'label': 'p (t=0)', 'dash': True},
              {'x': a1[0], 'y': a1[1], 'color': C1, 'label': 'p (t=0.3)'}],
             title='Acoustics: impedance-matched pulse, c=1', xlabel='x', ylabel='p')

    # 14 sod vs exact riemann
    def rho_exact(xi):
        cL, tail = 1.18322, -0.07027
        if xi < -cL: return 1.0
        if xi < tail:
            c = (2.0 / 2.4) * (cL - 0.2 * xi)
            return (c / cL) ** 5.0
        if xi < 0.92745: return 0.42632
        if xi < 1.75215: return 0.26557
        return 0.125
    sd = cols('sod_t120.txt')
    ex = [rho_exact((x - 12.0) / 1.2) for x in sd[0]]
    svg_plot(os.path.join(IMG, 'sod.svg'),
             [{'x': sd[0], 'y': sd[1], 'color': C1, 'label': 'rho (computed)'},
              {'x': sd[0], 'y': ex, 'color': C2, 'label': 'rho (exact Riemann)', 'dash': True},
              {'x': sd[0], 'y': sd[2], 'color': C3, 'label': 'p'},
              {'x': sd[0], 'y': sd[3], 'color': C4, 'label': 'u'}],
             title='Sod shock tube at t=1.2 (right diaphragm)', xlabel='x', ylabel='')

    # 15 KS space-time
    km = mat('ks_strip.mat')
    heatmap(km, os.path.join(IMG, 'ks.png'), DIVERGE, sym=True, target=480)

    # 16 dirichlet profiles
    dm = mat('dirichlet_strip.mat')
    h = 1.0 / 64
    xs = [i * h for i in range(len(dm[0]))]
    cs = ['#bbbbbb', C3, C1, C4, C2]
    series = [{'x': xs, 'y': row, 'color': cs[i % 5], 'label': 't=%g' % (i * 2500 * 0.00002)}
              for i, row in enumerate(dm)]
    svg_plot(os.path.join(IMG, 'dirichlet.svg'), series,
             title='Dirichlet walls: eigenmode decays as (1+lam dt)^n', xlabel='x', ylabel='u')

    # 17 high-order symbol errors
    hh = 2 * math.pi / 64
    ks_ = [0.25 * i for i in range(2, 81)]
    e2, e4 = [], []
    for kv in ks_:
        l2 = -(4.0 / hh / hh) * math.sin(kv * hh / 2) ** 2
        l4 = (-2.5 + (8.0 / 3.0) * math.cos(kv * hh) - (1.0 / 6.0) * math.cos(2 * kv * hh)) / hh / hh
        e2.append(math.log10(abs(l2 + kv * kv) + 1e-30))
        e4.append(math.log10(abs(l4 + kv * kv) + 1e-30))
    svg_plot(os.path.join(IMG, 'hi4.svg'),
             [{'x': ks_, 'y': e2, 'color': '#999999', 'label': '2nd order (dC2)'},
              {'x': ks_, 'y': e4, 'color': C1, 'label': '4th order (CAS-derived)'}],
             title='Laplacian symbol error |lam(k)+k^2|', xlabel='k', ylabel='log10 error')

    print('rendered into', IMG)

if __name__ == '__main__':
    main()
