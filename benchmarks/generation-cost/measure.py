#!/usr/bin/env python3
"""Measure the cost of every generation stage for representative examples.

Usage: python3 benchmarks/generation-cost/measure.py  (EGISON_DIR selects the
Egison checkout; default ../egison).  Results: .build/generation-cost/
generation-cost.json; copy it next to this script as results.json.

Stages: formurae-pre, Egison normalization, formurae-post, Formura, C compile.
Each stage is timed as one tool process (wall-clock `real` of /usr/bin/time -l)
and its peak resident memory is recorded.  Everything runs sequentially: no two
Haskell processes overlap.
"""
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EGISON = Path(os.environ.get('EGISON_DIR', ROOT.parent / 'egison')).resolve()
WORK = ROOT / '.build/generation-cost'
EXAMPLES = ['diffusion3d', 'maxwell_dec', 'elastic3d', 'mhd_ot',
            'transformation_optics', 'elastic_pulse', 'elastic_shell']
REPS = 3
LIBS = [ROOT / line for line in
        (ROOT / 'spec/egison-normalization.list').read_text().split()[1:]]


def log(*args):
    print(time.strftime('%H:%M:%S'), *args, flush=True)


def run(cmd, cwd, **kw):
    log('$', ' '.join(map(str, cmd)))
    return subprocess.run([str(c) for c in cmd], cwd=cwd, check=True, text=True, **kw)


def timed(cmd, cwd, stdout_path=None):
    out = open(stdout_path, 'w') if stdout_path else subprocess.DEVNULL
    try:
        env = dict(os.environ, formurae_datadir=str(ROOT), egison_datadir=str(EGISON))
        p = subprocess.run(['/usr/bin/time', '-l'] + [str(c) for c in cmd], cwd=cwd, env=env,
                           stdout=out, stderr=subprocess.PIPE, text=True)
    finally:
        if stdout_path:
            out.close()
    if p.returncode:
        print(p.stderr[-4000:], flush=True)
        raise SystemExit(f'failed: {cmd}')
    real = float(re.search(r'([\d.]+)\s+real', p.stderr).group(1))
    rss = int(re.search(r'(\d+)\s+maximum resident set size', p.stderr).group(1))
    return {'real': real, 'max_rss_bytes': rss, 'stderr_tail': p.stderr[-1500:]}


def strip_markers(raw, dest):
    text = Path(raw).read_text()
    for bad in ('Type error', 'Warning', 'Parse error', 'Parser error', 'Evaluation error',
                'Desugar error', 'Egison error', 'Assertion failed'):
        if re.search(r'^' + re.escape(bad) + ':', text, flags=re.MULTILINE):
            raise SystemExit(f'Egison reported {bad} in {raw}')
    lines = [l for l in text.splitlines(keepends=True)
             if not re.match(r'^@@FORMURAE_ACTIVE_ORIGIN:\d+@@$', l.rstrip('\n'))]
    Path(dest).write_text(''.join(lines))


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    run(['cabal', 'build', '-v0', 'formurae-pre', 'formurae-post'], ROOT)
    run(['cabal', 'build', '-v0', 'exe:egison'], EGISON)
    pre = run(['cabal', 'list-bin', 'formurae-pre'], ROOT, stdout=subprocess.PIPE).stdout.strip()
    post = run(['cabal', 'list-bin', 'formurae-post'], ROOT, stdout=subprocess.PIPE).stdout.strip()
    egison = run(['cabal', 'list-bin', 'exe:egison'], EGISON, stdout=subprocess.PIPE).stdout.strip()
    info = {
        'machine': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
        'memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
        'os': platform.mac_ver()[0],
        'cc': subprocess.check_output(['cc', '--version'], text=True).splitlines()[0],
        'egison_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=EGISON, text=True).strip(),
        'formurae_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'binaries': {'formurae-pre': pre, 'formurae-post': post, 'egison': egison},
        'repetitions': REPS,
    }
    results = {}
    # Equivalence of the direct Egison binary and the cabal-run path used by the Makefile.
    for name in EXAMPLES:
        d = WORK / name
        d.mkdir(exist_ok=True)
        for ext in ('.fme', '.yaml'):
            shutil.copy2(ROOT / 'examples' / name / (name + ext), d / (name + ext))
        rel = d.relative_to(ROOT)
        samples = {s: [] for s in ('pre', 'egison', 'post', 'formura', 'cc')}
        for rep in range(REPS):
            log(name, 'rep', rep)
            samples['pre'].append(timed([pre, rel / (name + '.fme')], ROOT, d / (name + '.egi')))
            raw = d / (name + '.feir.raw')
            samples['egison'].append(timed(
                [egison, '--type-check-strict'] + sum([['-l', str(l)] for l in LIBS], [])
                + ['-l', str(d / (name + '.egi')), '-c', 'main []', '+RTS', '-M4G', '-RTS'],
                EGISON, raw))
            strip_markers(raw, d / (name + '.feir'))
            samples['post'].append(timed([post, rel / (name + '.feir')], ROOT, d / (name + '.fmr')))
            samples['formura'].append(timed([ROOT / 'bin/formura', name + '.fmr'], d, d / 'formura.log'))
            samples['cc'].append(timed(['cc', '-O2', '-std=c11', '-I.', '-I', ROOT / 'mpistub',
                                        '-c', name + '.c', '-o', name + '.o'], d))
        entry = {'stages': {}}
        for stage, values in samples.items():
            entry['stages'][stage] = {
                'real_median_s': statistics.median(v['real'] for v in values),
                'real_all_s': [v['real'] for v in values],
                'max_rss_max_bytes': max(v['max_rss_bytes'] for v in values),
                'max_rss_all_bytes': [v['max_rss_bytes'] for v in values],
            }
        entry['lines'] = {ext: sum(1 for _ in open(d / (name + ext)))
                          for ext in ('.fme', '.egi', '.fmr', '.c')}
        entry['bytes'] = {ext: (d / (name + ext)).stat().st_size
                          for ext in ('.fme', '.egi', '.feir', '.fmr', '.c')}
        committed = ROOT / 'examples' / name / (name + '.fmr')
        if committed.is_file():
            mask = lambda t: re.sub(r'\S*' + re.escape(name) + r'\.fme', 'SRC', t)
            entry['fmr_identical_to_repository'] = mask(committed.read_text()) == mask((d / (name + '.fmr')).read_text())
        results[name] = entry
        log(name, json.dumps({s: round(entry['stages'][s]['real_median_s'], 3) for s in entry['stages']}))
    # cabal-run overhead of the Makefile path, for reference (one small example).
    t = timed([ROOT / 'tools/run_formurae_normalization.sh', EGISON,
               WORK / 'diffusion3d/diffusion3d.egi'], ROOT, WORK / 'diffusion3d/diffusion3d.feir.cabal')
    info['cabal_run_egison_diffusion3d_real_s'] = t['real']
    strip_markers(WORK / 'diffusion3d/diffusion3d.feir.cabal', WORK / 'diffusion3d/diffusion3d.feir.cabal2')
    info['direct_binary_matches_cabal_run'] = (
        (WORK / 'diffusion3d/diffusion3d.feir').read_text() == (WORK / 'diffusion3d/diffusion3d.feir.cabal2').read_text())
    (WORK / 'generation-cost.json').write_text(json.dumps({'info': info, 'results': results}, indent=2) + '\n')
    log('done')


if __name__ == '__main__':
    main()
