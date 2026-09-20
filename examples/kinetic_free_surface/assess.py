#!/usr/bin/env python3
"""Recheck saved experiments and record both passing and failing criteria."""
import argparse
import json
from pathlib import Path
import run
import verify


def inspect(directory, check, role=None):
    path = directory/'result.json'
    record = json.loads(path.read_text())
    assert record['source_sha256'] == run.sha(run.HERE/f'{run.NAME}.fme'), ('stale source', directory)
    for name, digest in record['files'].items():
        assert run.sha(directory/name) == digest, ('changed output', directory/name)
    result = dict(directory=str(directory.relative_to(run.ROOT)), check=check, role=role,
                  record_sha256=run.sha(path), record=record)
    try:
        result.update(passed=True, measurements=getattr(verify, check)(record))
    except AssertionError as error:
        result.update(passed=False, failure=str(error))
    if check == 'backwash':
        result['backwash'] = verify.backwash_measurements(record)
    return result


def assess(args):
    unit = run.directory_for(*args.wave_grid, args.wave_mpi)
    beach = run.directory_for(*args.beach_grid, args.beach_mpi)
    basis = run.directory_for(*args.foundation_grid, args.foundation_mpi)
    import foundation
    cases = [inspect(basis/label, check) for label, check, _ in foundation.CASES]
    foundation_count = len(cases)
    by_name = {Path(case['directory']).name:case for case in cases}
    full = by_name['relaxation']['record']['history']
    half = by_name['relaxation-half-step']['record']['history']
    ratio = max(r['relaxationError'] for r in half)/max(r['relaxationError'] for r in full)
    falling = run.directory_for(32, 32, [1, 1])
    for label in ['fall-quarter', 'fall-three-quarter', 'fall-resolved', 'fall-thick-partial']:
        cases.append(inspect(falling/label, 'falling'))
    for label in args.wave_labels:
        cases.append(inspect(unit/label, 'wave', 'standing-wave'))
    cases.append(inspect(beach/args.bed_rest_label, 'bed_rest', 'beach-rest'))
    cases.append(inspect(beach/args.beach_shear_label, 'shear', 'beach-shear'))
    if args.beach_label:
        cases.append(inspect(beach/args.beach_label, 'basic'))
        cases.append(inspect(beach/args.beach_label, 'backwash'))
    report = dict(source_sha256=run.sha(run.HERE/f'{run.NAME}.fme'),
                  assessor_sha256=run.sha(Path(__file__)),
                  verifier_sha256=run.sha(run.HERE/'verify.py'),
                  foundation_passed=all(c['passed'] for c in cases[:foundation_count]) and ratio < .3,
                  relaxation_half_step_error_ratio=ratio,
                  numerical_checks_passed=all(c['passed'] for c in cases) and ratio < .3,
                  # A cell counter cannot certify a connected crest/cavity/impact.
                  visual_breaking_review_required=True,
                  cases=cases)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    for case in cases:
        print(Path(case['directory']).name, case['check'], 'PASS' if case['passed'] else 'FAIL', case.get('failure', ''))
    print(args.output)
    if args.require_all and not report['numerical_checks_passed']:
        raise SystemExit(1)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--foundation-grid', type=int, nargs=2, default=[160, 64])
    parser.add_argument('--foundation-mpi', type=int, nargs=2, default=[2, 2])
    parser.add_argument('--beach-label')
    parser.add_argument('--beach-grid', type=int, nargs=2, default=[160, 64])
    parser.add_argument('--beach-mpi', type=int, nargs=2, default=[2, 2])
    parser.add_argument('--bed-rest-label', default='shared-height-bed-rest')
    parser.add_argument('--beach-shear-label', default='shared-height-beach-shear')
    parser.add_argument('--wave-grid', type=int, nargs=2, default=[64, 64])
    parser.add_argument('--wave-mpi', type=int, nargs=2, default=[2, 2])
    parser.add_argument('--wave-labels', nargs='+', default=['shared-height-wave', 'shared-height-small-wave'])
    parser.add_argument('--output', type=Path, default=run.HERE/'results/verification.json')
    parser.add_argument('--require-all', action='store_true', help='Return failure if any numerical acceptance check fails.')
    assess(parser.parse_args())
