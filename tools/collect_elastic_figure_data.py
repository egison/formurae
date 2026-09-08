#!/usr/bin/env python3
"""Record actual generated solutions and energy traces for paper figures.

Uses the committed Formura sources already checked by the full-pipeline
validation. Only Formura-to-C and C compilation are repeated, serially.
"""
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'examples/elastic_curvilinear/results/figures'
WORK = ROOT / '.build/elastic-figures'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, cwd, log, env=None):
    with log.open('w') as stream:
        subprocess.run(args, cwd=cwd, env=env, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)


def build(coordinate):
    name = 'elastic_' + coordinate
    work = WORK / name
    work.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / f'examples/{name}/{name}.fmr', work / f'{name}.fmr')
    spherical = coordinate == 'spherical'
    dims = [33, 17, 16] if spherical else [33, 16, 17]
    lengths = [33/32, (math.pi-2)*17/16, 2*math.pi] if spherical else [33/32, 2*math.pi, 17/16]
    boundary = '[fixed 0.0, fixed 0.0, periodic]' if spherical else '[fixed 0.0, periodic, fixed 0.0]'
    (work/f'{name}.yaml').write_text(f'length_per_node: {lengths}\ngrid_per_node: {dims}\nmpi_shape: [1,1,1]\nboundary: {boundary}\n')
    header = ROOT / 'examples/elastic_curvilinear/elastic_check.h'
    (work/'driver.c').write_text(f'#define SPHERICAL {int(spherical)}\n#include "{name}.h"\n#include "{header}"\n')
    command([str(ROOT/'bin/formura'), f'{name}.fmr'], work, work/'formura.log')
    command(['cc', '-O2', '-std=c11', '-I.', f'-I{ROOT}/mpistub',
             'driver.c', f'{name}.c', '-lm', '-o', 'check'], work, work/'cc.log')
    return work


def run(work, mode, steps, variable, output):
    env = dict(os.environ)
    # Each run records precisely the requested output, independently of a
    # caller's environment variables for another visualization run.
    env.pop('FORMURAE_ELASTIC_TRACE', None)
    env.pop('FORMURAE_ELASTIC_PROFILE', None)
    env[variable] = str(output)
    log = work / (output.stem + '.log')
    command([str(work/'check'), mode, str(steps)], work, log, env)
    records = [json.loads(line) for line in log.read_text().splitlines() if line.startswith('{')]
    assert len(records) == 1 and records[0]['ok']
    record = records[0]
    with output.open() as stream:
        rows = list(csv.DictReader(stream, delimiter=' '))
    assert rows and all(math.isfinite(float(x)) for row in rows for x in row.values())
    if mode == 'stability':
        assert len(rows) == 202 and int(rows[-1]['step']) == 10000
        drift = max(abs(float(row['modified_relative'])) for row in rows)
        assert abs(drift-record['modified_energy_drift']) < 1e-25
        assert max(float(row['energy_relative']) for row in rows) < 3e-5
    else:
        assert len(rows) == 33
        record['profile_max_absolute_error'] = max(abs(float(row['generated'])-float(row['exact'])) for row in rows)
    record['data_file'] = output.name
    record['data_sha256'] = sha(output)
    print(coordinate_label(record), output.name, 'passed', flush=True)
    return record


def coordinate_label(record):
    return record['coordinate'] + ' ' + record['mode']


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    validation = ROOT / 'examples/elastic_curvilinear/results/validation.json'
    previous = json.loads(validation.read_text())
    report = {'description': 'Two 10000-step generated-C energy traces and four torsional-mode profiles; analytic profiles use the actual sample times.',
              'platform': platform.platform(),
              'compiler': subprocess.check_output(['cc', '--version'], text=True).splitlines()[0],
              'source_sha256': {str(validation.relative_to(ROOT)): sha(validation),
                                'examples/elastic_curvilinear/elastic_check.h': sha(ROOT/'examples/elastic_curvilinear/elastic_check.h'),
                                str(Path(__file__).relative_to(ROOT)): sha(Path(__file__))},
              'build_sha256': {}, 'results': []}
    for coordinate in ['cylindrical', 'spherical']:
        name = 'elastic_' + coordinate
        work = build(coordinate)
        for suffix in ['fme', 'fmr']:
            source = ROOT / f'examples/{name}/{name}.{suffix}'
            report['source_sha256'][str(source.relative_to(ROOT))] = sha(source)
        for file in [f'{name}.fmr', f'{name}.yaml', f'{name}.c', f'{name}.h', 'driver.c', 'check']:
            report['build_sha256'][str((work/file).relative_to(ROOT))] = sha(work/file)
        old = next(x for x in previous['results'] if x['coordinate'] == coordinate and x['mode'] == 'stability')
        record = run(work, 'stability', 10000, 'FORMURAE_ELASTIC_TRACE', OUT/f'{coordinate}-energy.dat')
        for key in ['energy_min_ratio', 'energy_max_ratio', 'modified_energy_drift']:
            assert abs(record[key]-old[key]) < 1e-12, (coordinate, key)
        report['results'].append(record)
        for numerator in [1, 3]:
            steps = math.ceil((numerator/8)*2*math.pi/(old['wave_number']*old['dt']))
            record = run(work, 'accuracy', steps, 'FORMURAE_ELASTIC_PROFILE', OUT/f'{coordinate}-profile-{numerator}.dat')
            record['target_period_fraction'] = numerator/8
            record['actual_period_fraction'] = record['time']*record['wave_number']/(2*math.pi)
            report['results'].append(record)
    report['all_passed'] = True
    (OUT/'records.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
