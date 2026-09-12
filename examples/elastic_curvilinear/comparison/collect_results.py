#!/usr/bin/env python3
"""Validate and collect the actual comparison outputs; does not rerun compilers."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
REVISIONS = {
    'opensbli': 'e37dc377fa9b27d6bfa6e9da2968b96bcd736f1d',
    'nrpyplus': 'a32e120f5642bee00e32e9e04dd8cb4c58ae661c',
    'kranc': 'b4b2b40103a706a29f8f6b3910110a30afff75aa',
}


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, default=ROOT/'.build/related-work/results')
    parser.add_argument('--output', type=Path, default=HERE/'results.json')
    args = parser.parse_args()
    reports = {name: json.loads((args.input/(name+'.json')).read_text())
               for name in ['formurae', 'nrpylatex', 'devito', 'opensbli', 'nrpyplus']}
    f = reports['formurae']['results']
    assert len(f) == 14 and reports['formurae']['all_expected']
    errors = []
    for record in f.values():
        assert record['matches_expectation']
        assert digest(ROOT/record['source']) == record['source_sha256']
        if 'numerical' in record:
            errors.append(record['numerical']['max_error'])
    for name in ['nrpylatex', 'devito', 'opensbli']:
        errors.extend(v['max_error'] for v in reports[name]['results']['coordinates'].values())
    assert len(errors) == 8 and max(errors) < 1e-12
    d = reports['devito']['results']
    n = reports['nrpylatex']['results']
    o = reports['opensbli']['results']
    assert d['asymmetric_update']['accepted'] and not d['asymmetric_update']['rhs_is_symmetric']
    assert d['asymmetric_update']['rhs_q01'] != d['asymmetric_update']['rhs_q10']
    assert d['asymmetric_update']['stored_q01'] == d['asymmetric_update']['stored_q10']
    assert n['anisotropic_symmetric']
    assert n['asymmetric_update']['accepted'] and not n['asymmetric_update']['result_is_symmetric']
    assert not n['invalid_contraction']['accepted']
    assert not o['unbalanced_indices']['accepted'] and o['component_equations'] == 9
    assert not o['asymmetric_update']['symmetric_output_declaration_in_this_api']
    assert f['flux_collocated']['whole_flux_centered_value'] == 80
    assert d['nonlinear_flux']['whole_flux_centered_value'] == 80
    assert n['nonlinear_flux']['value_with_centered_field_derivative'] == 64
    assert reports['nrpyplus']['results']['materialized_flux']['generated_centered_difference']
    assert d['placement_policy']['accepted_explicit_half_location_to_node']
    sources = ROOT/'.build/related-work/sources'
    for name, revision in REVISIONS.items():
        assert git('-C', str(sources/name), 'rev-parse', 'HEAD') == revision
        assert not git('-C', str(sources/name), 'status', '--porcelain', '--untracked-files=no')
    tracked_evidence = [*HERE.glob('*.py'), *HERE.glob('requirements-*.txt'),
                        *(HERE/'fixtures').glob('*.fme'),
                        ROOT/'lib/formurae-tensor.egi',
                        ROOT/'src/Formurae/Pre/EmitEgison.hs',
                        ROOT/'src/Formurae/Post/Compile.hs',
                        ROOT/'src/Formurae/Post/FMR.hs',
                        ROOT/'src/Formurae/Post/Stencil.hs',
                        ROOT/'examples/elastic_spherical/elastic_spherical.fme']
    report = {
        'protocol_date': '2026-09-07',
        'platform': platform.platform(),
        'formurae_git_head': git('-C', str(ROOT), 'rev-parse', 'HEAD'),
        'formurae_worktree_has_changes': bool(git('-C', str(ROOT), 'status', '--porcelain')),
        'source_revisions': REVISIONS,
        'source_sha256': {str(p.relative_to(ROOT)): digest(p)
                          for p in sorted(tracked_evidence)},
        'summary': {'formurae_cases': len(f), 'all_observations_verified': True,
                    'constitutive_max_error': max(errors),
                    'constitutive_evaluations': len(errors),
                    'kranc_evidence': 'source inspection, not Mathematica execution'},
        'systems': reports,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
