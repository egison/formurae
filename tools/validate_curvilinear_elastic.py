#!/usr/bin/env python3
"""Serial, full-pipeline convergence and energy checks. Standard library only.

Generated kernels and build logs stay in .build. JSON and data tables in
examples/elastic_curvilinear/results are the reproducible numerical record.
No Haskell builds or numerical jobs are started in parallel.
"""
import array
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / 'examples/elastic_curvilinear/results'
RESULTS.mkdir(exist_ok=True)
REVISION = '1a0298c67cc487dd4a73d96f526f3042b74d6570'


def command(args, cwd=ROOT, output=None):
    if output is None:
        return subprocess.check_output(args, cwd=cwd, text=True).strip()
    with open(output, 'w') as log:
        subprocess.run(args, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True)


def build(name, nr, factor, full=False):
    spherical = name.endswith('spherical')
    key = f'{name}-{nr}-{factor:g}'+('-full' if full else '')
    work = ROOT / '.build' / key
    work.mkdir(exist_ok=True)
    source = (ROOT / f'examples/{name}/{name}.fmr').read_text()
    source = source.replace('double :: dt = 0.05*dr', f'double :: dt = {factor:.17g}*dr')
    (work / f'{name}.fmr').write_text(source)
    # Fixed angular/axial resolutions isolate radial convergence of the
    # exact torsional mode, which is constant in coordinate components on
    # those axes. The separate all-component energy test varies all axes.
    dims = [nr, 17, 16] if spherical else [nr, 16, 17]
    lengths = [nr/(nr-1), (math.pi-2)*17/16, 2*math.pi] if spherical else [nr/(nr-1), 2*math.pi, 17/16]
    if full:
        dims = [nr, nr, nr-1] if spherical else [nr, nr-1, nr]
        lengths = [nr/(nr-1), (math.pi-2)*nr/(nr-1), 2*math.pi] if spherical else [nr/(nr-1), 2*math.pi, nr/(nr-1)]
    boundary = '[fixed 0.0, fixed 0.0, periodic]' if spherical else '[fixed 0.0, periodic, fixed 0.0]'
    (work / f'{name}.yaml').write_text(f'length_per_node: {lengths}\ngrid_per_node: {dims}\nmpi_shape: [1,1,1]\nboundary: {boundary}\n')
    header = ROOT / 'examples/elastic_curvilinear/elastic_check.h'
    (work/'driver.c').write_text(f'#define SPHERICAL {int(spherical)}\n#include "{name}.h"\n#include "{header}"\n')
    command([str(ROOT/'bin/formura'), f'{name}.fmr'], work, work/'formura.log')
    command(['cc', '-O2', '-std=c11', f'-DDT_FACTOR={factor:.17g}', '-I.', f'-I{ROOT}/mpistub', '-o', 'check', 'driver.c', f'{name}.c', '-lm'], work, work/'cc.log')
    return work


def run(work, mode, steps=None, dump=None):
    args = [str(work/'check'), mode]
    if steps is not None: args.append(str(steps))
    if dump is not None: args.append(str(dump))
    suffix = f'{mode}-{steps or "default"}'
    log = work / (suffix+'.log')
    start = time.monotonic()
    command(args, work, log)
    records = [json.loads(line) for line in log.read_text().splitlines() if line.startswith('{')]
    assert len(records) == 1 and records[0]['ok'], log
    record = records[0]
    record['elapsed_seconds'] = time.monotonic()-start
    record['log'] = str(log.relative_to(ROOT))
    print(json.dumps(record), flush=True)
    return record


def snapshot(path):
    result = array.array('d')
    with open(path, 'rb') as stream: result.frombytes(stream.read())
    assert all(math.isfinite(x) for x in result)
    return result


def temporal_orders(temporal):
    """Three-level differences remove the error of a common fine reference."""
    for i, ((record, coarse), (_, fine)) in enumerate(zip(temporal, temporal[1:])):
        assert len(coarse) == len(fine)
        difference = math.sqrt(sum((x-y)**2 for x, y in zip(coarse, fine)))
        record['successive_temporal_difference'] = difference
        if i:
            previous = temporal[i-1][0]['successive_temporal_difference']
            order = math.log(previous/difference, 2)
            record['successive_temporal_order'] = order
            assert 1.8 < order < 2.2, record


def main():
    names = ['elastic_cylindrical', 'elastic_spherical']
    definitions = [[line for line in (ROOT/f'examples/{name}/{name}.fme').read_text().splitlines()
                    if line.startswith('def ')] for name in names]
    assert len(definitions[0]) == 3 and definitions[0] == definitions[1]
    egison = command([str(ROOT/'tools/prepare_elastic_validation.sh')])
    records = []
    sources = {}
    for name in names:
        base = ROOT/f'examples/{name}/{name}'
        command(['cabal', 'run', '-v0', 'formurae-pre', '--', str(base.with_suffix('.fme').relative_to(ROOT))], output=base.with_suffix('.egi'))
        command([str(ROOT/'tools/run_formurae_normalization.sh'), egison, str(base.with_suffix('.egi'))], output=base.with_suffix('.feir'))
        command(['cabal', 'run', '-v0', 'formurae-post', '--', str(base.with_suffix('.feir').relative_to(ROOT))], output=base.with_suffix('.fmr'))
        sources[name] = hashlib.sha256(base.with_suffix('.fme').read_bytes()).hexdigest()
        accuracy = []
        built = {}
        for nr in [17, 33, 65]:
            work = build(name, nr, 0.05)
            built[(nr, 0.05)] = work
            result = run(work, 'accuracy')
            if accuracy:
                result['observed_radial_order'] = math.log(accuracy[-1]['relative_error']/result['relative_error'], 2)
                assert result['observed_radial_order'] > 1.8, result
            accuracy.append(result); records.append(result)
        records.append(run(built[(33, 0.05)], 'stability'))
        # Fixed spatial grid and physical end time T=0.2; compare three
        # time steps with a fourth, finer integration of that same grid.
        temporal = []
        for factor in [0.1, 0.05, 0.025, 0.0125]:
            work = built.get((33, factor)) or build(name, 33, factor)
            steps = round(0.2/(factor/32))
            dump = work/'temporal.bin'
            result = run(work, 'accuracy', steps, dump)
            result['mode'] = 'temporal'
            temporal.append((result, snapshot(dump)))
        temporal_orders(temporal)
        fine = temporal[-1][1]
        norm = sum(x*x for x in fine)
        for i,(result,values) in enumerate(temporal[:-1]):
            assert len(values) == len(fine)
            result['relative_temporal_difference'] = math.sqrt(sum((x-y)**2 for x,y in zip(values,fine))/norm)
            if i:
                previous = temporal[i-1][0]['relative_temporal_difference']
                result['observed_temporal_order'] = math.log(previous/result['relative_temporal_difference'],2)
                assert result['observed_temporal_order'] > 1.8, result
            records.append(result)
        records.append(temporal[-1][0])
        covariance = []
        for nr in [17, 33, 65]:
            result = run(build(name, nr, 0.05, full=True), 'covariance')
            if covariance:
                result['observed_spatial_order'] = math.log(covariance[-1]['interior_rate_error']/result['interior_rate_error'],2)
                assert result['observed_spatial_order'] > 1.8, result
            covariance.append(result); records.append(result)
        # Persist partial progress as well as final results after each model.
        report = {'egison_revision': REVISION, 'platform': platform.platform(), 'source_sha256': sources, 'results': records}
        (RESULTS/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
        (RESULTS/f'{name}-convergence.dat').write_text('intervals error\n'+''.join(f'{x["nr"]-1} {x["relative_error"]:.12g}\n' for x in accuracy))
    print('All curvilinear elastic validation checks passed.', flush=True)


if __name__ == '__main__': main()
