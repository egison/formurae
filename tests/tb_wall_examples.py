#!/usr/bin/env python3
"""Temporal blocking on the wall-bounded Formurae examples.

Usage: python3 tests/tb_wall_examples.py [work directory]  (needs bin/formura)

For every example whose yaml declares a wall, build the generated Formura
program twice from the committed .fmr: without blocking and with temporal
blocking (one block per axis, the given interval), run both for the same
number of time steps with a generic dumper, and require every state variable
of every cell to agree bit for bit.  Periodic axes drift under blocking, so
cells are matched through n.offset_*.  Nothing here touches the example
directories.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.build/tb-walls'
FORMURA = ROOT / 'bin/formura'
EXAMPLES = ['sbp_diffusion1d', 'sbp_wave1d', 'sbp_neumann', 'sbp_wave_open', 'sbp_highorder4',
            'sbp_diffusion2d', 'dirichlet_diffusion', 'polar2d', 'hyperbolic', 'metric_sphere',
            'spherical3d', 'yinyang_diffusion', 'elastic_spherical']
INTERVALS = [2, 3]
FORWARDS = 6      # blocked forwards; the plain run does FORWARDS * interval


def yaml_of(path):
    return dict(re.findall(r'^(\w+):\s*(.*)$', path.read_text(), flags=re.MULTILINE))


def fields_of(header):
    text = header.read_text()
    m = re.search(r'typedef struct \{\n(.*?)\n\} Formura_Grid_Struct;', text, flags=re.DOTALL)
    return re.findall(r'double (\w+)\[', m.group(1))


def axes_of(header):
    return re.findall(r'int total_grid_(\w+);', header.read_text())


def dumper(axes, fields):
    loops = ''.join(f'for (int c{a} = 0; c{a} < n.total_grid_{a}; c{a}++) ' for a in axes)
    slots = ''.join(f'int i{a} = (c{a} - n.offset_{a} + n.total_grid_{a}) % n.total_grid_{a}; ' for a in axes)
    idx = ''.join(f'[i{a}]' for a in axes)
    cells = ' '.join(f'%d' for _ in axes)
    cargs = ', '.join(f'c{a}' for a in axes)
    vals = ' '.join('%a' for _ in fields)
    vargs = ', '.join(f'formura_data.{f}{idx}' for f in fields)
    phase = ' + '.join(f'{k} * c{a}' for k, a in zip((1.7, 0.3, 0.9), axes))
    seed = ' '.join(f'formura_data.{f}{idx} += 1e-3 * sin({phase} + {m});' for m, f in enumerate(fields))
    return f'''#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "model.h"
int main(int argc, char **argv) {{
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  int forwards = atoi(argv[1]);
  /* a deterministic perturbation of every field, so that examples whose
     init leaves the state zero still exercise every stencil */
  {loops}{{ {slots} {seed} }}
  for (int f = 0; f < forwards; f++) {{
    Formura_Forward(&n);
    printf("time_step %d\\n", n.time_step);
    {loops}{{ {slots}
      printf("{cells} {vals}\\n", {cargs}, {vargs}); }}
  }}
  Formura_Finalize();
  return 0;
}}
'''


def build(example, tag, extra_yaml):
    src = ROOT / 'examples' / example
    d = WORK / example / tag
    d.mkdir(parents=True, exist_ok=True)
    (d / 'model.fmr').write_text((src / f'{example}.fmr').read_text())
    (d / 'model.yaml').write_text((src / f'{example}.yaml').read_text().rstrip('\n') + '\n' + extra_yaml)
    with (d / 'generate.log').open('w') as log:
        r = subprocess.run([str(FORMURA), 'model.fmr'], cwd=d, stdout=log, stderr=subprocess.STDOUT)
    if r.returncode:
        raise SystemExit(f'{example}/{tag}: formura failed:\n' + (d / 'generate.log').read_text()[-2000:])
    fields = fields_of(d / 'model.h')
    (d / 'dump.c').write_text(dumper(axes_of(d / 'model.h'), fields))
    subprocess.run(['cc', '-std=c11', '-O1', '-ffp-contract=off', '-I.', '-I', str(ROOT / 'mpistub'),
                    'dump.c', 'model.c', '-lm', '-o', 'dump'], cwd=d, check=True)
    return d


def run(d, forwards):
    return subprocess.check_output([str(d / 'dump'), str(forwards)], cwd=d, text=True)


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    report = {}
    for example in EXAMPLES:
        cfg = yaml_of(ROOT / 'examples' / example / f'{example}.yaml')
        grid = [int(x) for x in re.findall(r'\d+', cfg['grid_per_node'])]
        plain = build(example, 'plain', '')
        sleeve = int(re.search(r'#define Ns (\d+)', (plain / 'model.h').read_text()).group(1))
        bcs = re.findall(r'(periodic|mirror|fixed [-\d.]+)', cfg['boundary'])
        results = {}
        for nt in INTERVALS:
            # a blocked step copies a one-sided halo of 2*sleeve*nt from the
            # neighbor along every periodic axis, which must fit in the grid
            if any(bc == 'periodic' and n < 2 * sleeve * nt for bc, n in zip(bcs, grid)):
                print(example, f'tb{nt}', 'skipped: periodic axis shorter than the halo', flush=True)
                continue
            floor = [n + 2 * sleeve * nt for n in grid]
            tag = f'tb{nt}'
            blocked = build(example, tag,
                            f'grid_per_block: {floor}\ntemporal_blocking_interval: {nt}\n')
            expected_lines = [l for l in run(plain, FORWARDS * nt).splitlines()]
            keep, expected = False, []
            for line in expected_lines:
                if line.startswith('time_step'):
                    keep = int(line.split()[1]) % nt == 0
                if keep:
                    expected.append(line)
            got = run(blocked, FORWARDS).splitlines()
            same = expected == got
            magnitude = sum(abs(float.fromhex(v)) for line in got[1:] for v in line.split()[len(grid):] if not line.startswith('time_step'))
            assert magnitude > 0, (example, tag, 'trivial state')
            results[tag] = {'sleeve': sleeve, 'floor': floor, 'identical': same,
                            'records': len(got), 'steps': FORWARDS * nt, 'sum_abs': magnitude}
            if not same:
                diffs = [(a, b) for a, b in zip(expected, got) if a != b][:3]
                results[tag]['first_differences'] = diffs
            print(example, tag, 'sleeve', sleeve, 'floor', floor, 'identical' if same else 'DIFFERS', flush=True)
        report[example] = results
    bad = [(e, t) for e, r in report.items() for t, v in r.items() if not v['identical']]
    (WORK / 'report.json').write_text(__import__('json').dumps(report, indent=1) + '\n')
    if bad:
        raise SystemExit(f'differences: {bad}')
    print('all wall-bounded examples reproduce the plain run under temporal blocking')


if __name__ == '__main__':
    main()
