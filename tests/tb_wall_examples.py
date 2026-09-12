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
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.build/tb-walls'
FORMURA = ROOT / 'bin/formura'
EXAMPLES = ['sbp_diffusion1d', 'sbp_wave1d', 'sbp_neumann', 'sbp_wave_open', 'sbp_highorder4',
            'sbp_diffusion2d', 'dirichlet_diffusion', 'polar2d', 'hyperbolic', 'metric_sphere',
            'spherical3d', 'yinyang_diffusion', 'elastic_spherical', 'elastic_shell']
INTERVALS = [2, 3]
FORWARDS = 6      # blocked forwards; the plain run does FORWARDS * interval
# decompositions to try (per example, when the grid divides and the
# per-rank axes satisfy the halo constraints); interval 0 means no blocking
DECOMPOSITIONS = {
    'dirichlet_diffusion': [((2, 1, 1), 0), ((2, 1, 1), 2), ((2, 2, 1), 2)],
    'sbp_diffusion2d': [((2, 2), 0), ((2, 2), 2)],
    'spherical3d': [((2, 2, 2), 0), ((2, 2, 2), 2)],
    'polar2d': [((2, 2, 1), 2)],
    'elastic_spherical': [((3, 1, 1), 0), ((3, 1, 1), 2)],
    'elastic_shell': [((3, 1, 1), 0), ((1, 3, 2), 2)],
}
MPIRUN = shutil.which('mpirun')
MPICC = shutil.which('mpicc')


def yaml_of(path):
    return dict(re.findall(r'^(\w+):\s*(.*)$', path.read_text(), flags=re.MULTILINE))


def fields_of(header):
    text = header.read_text()
    m = re.search(r'typedef struct \{\n(.*?)\n\} Formura_Grid_Struct;', text, flags=re.DOTALL)
    return re.findall(r'double (\w+)\[', m.group(1))


def axes_of(header):
    return re.findall(r'int total_grid_(\w+);', header.read_text())


def dumper(axes, fields):
    # every rank walks its own slots and reports global cells; the seed and
    # the records use the global cell, so decompositions agree with the
    # single-rank run record by record
    loops = ''.join(f'for (int i{a} = n.lower_{a}; i{a} < n.upper_{a}; i{a}++) ' for a in axes)
    cells_of = ''.join(f'int c{a} = (i{a} + n.offset_{a}) % n.total_grid_{a}; ' for a in axes)
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
  char path[512];
  snprintf(path, sizeof path, "%s.%d", argv[2], n.my_rank);
  FILE *out = fopen(path, "w");
  if (!out) {{ perror(path); return 2; }}
  /* a deterministic perturbation of every field, so that examples whose
     init leaves the state zero still exercise every stencil */
  {loops}{{ {cells_of} {seed} }}
  for (int f = 0; f < forwards; f++) {{
    Formura_Forward(&n);
    {loops}{{ {cells_of}
      fprintf(out, "%d {cells} {vals}\\n", n.time_step, {cargs}, {vargs}); }}
  }}
  if (fclose(out)) {{ perror(path); return 2; }}
  Formura_Finalize();
  return 0;
}}
'''


def build(example, tag, extra_yaml, shape=None):
    """Generate and compile; `shape` decomposes the example's grid over MPI ranks."""
    src = ROOT / 'examples' / example
    d = WORK / example / tag
    d.mkdir(parents=True, exist_ok=True)
    (d / 'model.fmr').write_text((src / f'{example}.fmr').read_text())
    yaml = (src / f'{example}.yaml').read_text()
    yaml = re.sub(r'^grid_per_block:.*\n|^temporal_blocking_interval:.*\n', '', yaml, flags=re.MULTILINE)
    if shape:
        cfg = dict(re.findall(r'^(\w+):\s*(.*)$', yaml, flags=re.MULTILINE))
        grid = [int(x) for x in re.findall(r'\d+', cfg['grid_per_node'])]
        length = [float(x) for x in re.findall(r'[-\d.eE+]+', cfg['length_per_node'])]
        assert all(n % p == 0 for n, p in zip(grid, shape)), (example, shape)
        yaml = re.sub(r'^grid_per_node:.*$', 'grid_per_node: ' + str([n // p for n, p in zip(grid, shape)]),
                      yaml, flags=re.MULTILINE)
        yaml = re.sub(r'^length_per_node:.*$', 'length_per_node: ' + str([l / p for l, p in zip(length, shape)]),
                      yaml, flags=re.MULTILINE)
        yaml = re.sub(r'^mpi_shape:.*$', 'mpi_shape: ' + str(list(shape)), yaml, flags=re.MULTILINE)
    (d / 'model.yaml').write_text(yaml.rstrip('\n') + '\n' + extra_yaml)
    with (d / 'generate.log').open('w') as log:
        r = subprocess.run([str(FORMURA), 'model.fmr'], cwd=d, stdout=log, stderr=subprocess.STDOUT)
    if r.returncode:
        raise SystemExit(f'{example}/{tag}: formura failed:\n' + (d / 'generate.log').read_text()[-2000:])
    fields = fields_of(d / 'model.h')
    (d / 'dump.c').write_text(dumper(axes_of(d / 'model.h'), fields))
    compiler = [MPICC] if shape else ['cc', '-I', str(ROOT / 'mpistub')]
    subprocess.run(compiler + ['-std=c11', '-O1', '-ffp-contract=off', '-I.', 'dump.c', 'model.c', '-lm', '-o', 'dump'],
                   cwd=d, check=True)
    return d


def run(d, forwards, ranks=1):
    """Run the dumper and return the sorted records (time step, global cell, values)."""
    for old in d.glob('cells.*'):
        old.unlink()
    if ranks > 1:
        subprocess.run([MPIRUN, *os.environ.get('MPIRUN_ARGS', '--bind-to none').split(), '-n', str(ranks),
                        str(d / 'dump'), str(forwards), str(d / 'cells')], cwd=d, check=True)
    else:
        subprocess.run([str(d / 'dump'), str(forwards), str(d / 'cells')], cwd=d, check=True)
    lines = []
    for part in sorted(d.glob('cells.*')):
        lines.extend(part.read_text().splitlines())
    return sorted(lines, key=lambda l: [int(x) for x in l.split()[:1 + len(axes_of(d / 'model.h'))]])


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
            reference = run(plain, FORWARDS * nt)
            expected = [line for line in reference if int(line.split()[0]) % nt == 0]
            got = run(blocked, FORWARDS)
            same = expected == got
            magnitude = sum(abs(float.fromhex(v)) for line in got for v in line.split()[1 + len(grid):])
            assert magnitude > 0, (example, tag, 'trivial state')
            results[tag] = {'sleeve': sleeve, 'floor': floor, 'identical': same,
                            'records': len(got), 'steps': FORWARDS * nt, 'sum_abs': magnitude}
            if not same:
                diffs = [(a, b) for a, b in zip(expected, got) if a != b][:3]
                results[tag]['first_differences'] = diffs
            print(example, tag, 'sleeve', sleeve, 'floor', floor, 'identical' if same else 'DIFFERS', flush=True)
        # decomposed runs: the same records must come out of several ranks
        for shape, nt in DECOMPOSITIONS.get(example, []):
            if not (MPIRUN and MPICC):
                print(example, 'decomposition skipped: no mpicc/mpirun', flush=True)
                break
            tag = 'mpi' + 'x'.join(map(str, shape)) + (f'-tb{nt}' if nt else '-plain')
            per_rank = [n // p for n, p in zip(grid, shape)]
            if nt and any((bc == 'periodic' and n < 2 * sleeve * nt) or (bc != 'periodic' and p > 1 and n < sleeve * nt)
                          for bc, n, p in zip(bcs, per_rank, shape)):
                print(example, tag, 'skipped: per-rank axis shorter than the halo', flush=True)
                continue
            extra = (f'grid_per_block: {[n + 2 * sleeve * nt for n in per_rank]}\ntemporal_blocking_interval: {nt}\n'
                     if nt else '')
            d = build(example, tag, extra, shape)
            steps = FORWARDS * (nt or 1)
            reference = run(plain, steps)
            expected = [line for line in reference if int(line.split()[0]) % (nt or 1) == 0]
            got = run(d, FORWARDS if nt else steps, ranks=int(__import__('math').prod(shape)))
            same = expected == got
            results[tag] = {'sleeve': sleeve, 'shape': list(shape), 'identical': same, 'records': len(got), 'steps': steps}
            if not same:
                results[tag]['first_differences'] = [(a, b) for a, b in zip(expected, got) if a != b][:3]
            print(example, tag, 'sleeve', sleeve, 'identical' if same else 'DIFFERS', flush=True)
        report[example] = results
    bad = [(e, t) for e, r in report.items() for t, v in r.items() if not v['identical']]
    (WORK / 'report.json').write_text(__import__('json').dumps(report, indent=1) + '\n')
    if bad:
        raise SystemExit(f'differences: {bad}')
    print('all wall-bounded examples reproduce the plain run under temporal blocking')


if __name__ == '__main__':
    main()
