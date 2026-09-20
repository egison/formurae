#!/usr/bin/env python3
"""Run the stationary, transport, collision and viscosity checks sequentially."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
import run
import verify


CASES = [
    ('rest-cartesian', 'rest', ['--duration', '.5']),
    ('rest-mapped', 'rest', ['--duration', '.5', '--warp', '.045', '.03']),
    ('translation-cartesian', 'translation', ['--scenario', '1', '--periodic', '--gravity', '0', '--duration', '1']),
    ('translation-mapped', 'translation', ['--scenario', '1', '--periodic', '--gravity', '0', '--duration', '1', '--warp', '.045', '.03']),
    ('relaxation', 'relaxation', ['--scenario', '6', '--periodic', '--gravity', '0', '--amplitude', '.1', '--tau', '.02', '--duration', '.1']),
    ('relaxation-half-step', 'relaxation', ['--scenario', '6', '--periodic', '--gravity', '0', '--amplitude', '.1', '--tau', '.02', '--duration', '.1', '--time-scale', '.5']),
    ('stiff-relaxation', 'stiff', ['--scenario', '6', '--periodic', '--gravity', '0', '--amplitude', '.1', '--tau', '.0003', '--duration', '.05']),
    ('stiff-relaxation-faster', 'stiff', ['--scenario', '6', '--periodic', '--gravity', '0', '--amplitude', '.1', '--tau', '.00015', '--duration', '.05']),
    ('shear', 'shear', ['--scenario', '5', '--periodic', '--gravity', '0', '--speed', '.01', '--tau', '.02', '--duration', '2']),
    ('shear-low-viscosity', 'shear', ['--scenario', '5', '--periodic', '--gravity', '0', '--speed', '.01', '--tau', '.0006', '--duration', '2']),
]


def main(args):
    # These reference and fast-relaxation cases need different timestep ratios.
    # Check the run configuration before starting the generated solver.
    hx,hy=[length/n for length,n in zip(args.length,args.grid)]
    dt=.1*hx*hy/(hx+hy)
    assert 0<dt/.02<=.1, 'grid/timestep must resolve the accuracy reference'
    directory = run.directory_for(*args.grid, args.mpi)
    report = dict(passed=False, scope='Foundation checks; not breaking-wave completion',
                  grid=args.grid,length=args.length,mpi=args.mpi,
                  source_sha256=run.sha(run.HERE/f'{run.NAME}.fme'),
                  suite_sha256=run.sha(Path(__file__)), verifier_sha256=run.sha(run.HERE/'verify.py'), cases=[])
    destination = directory/'foundation.json'
    destination.write_text(json.dumps(report, indent=2)+'\n')
    for label, check, options in CASES:
        options=list(options)
        if check=='stiff':
            # Run configuration: keep two fixed fast-relaxation ratios when
            # changing the physical domain or grid. FME computes the reference.
            index=options.index('--tau')+1
            options[index]=str(dt/(8 if label.endswith('faster') else 4))
        command = [sys.executable, str(run.HERE/'experiment.py'), label,
                   '--grid', *map(str, args.grid), '--mpi', *map(str, args.mpi),
                   '--length', *map(str,args.length), '--level', str(args.length[1]/2),
                   '--reports', '100', '--height-method', str(args.height_method),
                   '--method', str(args.method), *options]
        print(label, flush=True)
        with (directory/(label+'.log')).open('w') as log:
            subprocess.run(command, cwd=run.ROOT, stdout=log, stderr=subprocess.STDOUT,
                           check=True)
        output = directory/label
        record = json.loads((output/'result.json').read_text())
        for name, digest in record['files'].items():
            assert run.sha(output/name) == digest, ('changed output', name)
        entry = dict(label=label, command=command, check=check, record=record)
        try:
            entry.update(passed=True, result=getattr(verify, check)(record))
        except AssertionError as error:
            entry.update(passed=False, failure=str(error))
        report['cases'].append(entry)
        destination.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({key:entry[key] for key in ['label', 'passed']}, ensure_ascii=False), flush=True)
        if not entry['passed']:
            raise AssertionError(entry['failure'])
    by_label = {case['label']:case for case in report['cases']}
    full = by_label['relaxation']['result']['maximum_stress_error']
    half = by_label['relaxation-half-step']['result']['maximum_stress_error']
    report['relaxation_half_step_error_ratio'] = half/full
    assert half/full < .3, ('collision timestep refinement', half/full)
    report['passed'] = True
    destination.write_text(json.dumps(report, indent=2)+'\n')
    print(destination, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--grid', type=int, nargs=2, default=[64, 64])
    parser.add_argument('--length', type=float, nargs=2, default=[1, 1])
    parser.add_argument('--mpi', type=int, nargs=2, default=[2, 2])
    parser.add_argument('--height-method', type=int, choices=[0, 1, 2, 3, 4, 5], default=2)
    parser.add_argument('--method', type=int, choices=[0, 1, 2, 3, 4], default=2)
    main(parser.parse_args())
