#!/usr/bin/env python3
"""Compare recorded executions of the same model (no new model quantities)."""
import argparse
import json
from pathlib import Path
import numpy as np
import run
import verify


def compare(left, right):
    records = [json.loads((p/'result.json').read_text()) for p in (left, right)]
    for path, record in zip((left, right), records):
        for name, digest in record['files'].items():
            assert run.sha(path/name) == digest, ('changed output', path/name)
        verify.basic(record)
    for key in ('parameters', 'grid', 'length', 'arguments', 'source_sha256'):
        assert records[0][key] == records[1][key], ('different configuration', key)
    assert len(records[0]['history']) == len(records[1]['history'])
    diagnostic_error = {}
    for key in records[0]['history'][0]:
        a, b = [np.array([r[key] for r in record['history']]) for record in records]
        np.testing.assert_allclose(a, b, rtol=2e-11, atol=2e-11, err_msg=key)
        diagnostic_error[key] = float(np.max(np.abs(a-b)))
    with np.load(left/'frames.npz') as a, np.load(right/'frames.npz') as b:
        for key in ('updates', 'time', 'fields'):
            np.testing.assert_allclose(a[key], b[key], rtol=2e-11, atol=2e-11,
                                       err_msg=key)
        field_error = np.max(np.abs(a['fields']-b['fields']), axis=(0, 2, 3)).tolist()
    return dict(passed=True, source_sha256=records[0]['source_sha256'],
                mpi=[record['mpi'] for record in records],
                execution_seconds=[record['execution_seconds'] for record in records],
                maximum_field_differences=dict(zip(['fraction', 'density', 'ux', 'uy', 'solid'], field_error)),
                maximum_diagnostic_differences=diagnostic_error,
                result_sha256=[run.sha(p/'result.json') for p in (left, right)])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('left', type=Path)
    parser.add_argument('right', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = json.dumps(compare(args.left, args.right), indent=2)+'\n'
    if args.output:
        args.output.write_text(report)
    print(report, end='')
