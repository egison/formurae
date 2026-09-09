#!/usr/bin/env python3
"""Serial Formurae comparisons, including positive controls and C execution."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
WORK = ROOT / '.build/related-work/formurae'


def egison_revision(directory):
    marker = directory / '.formurae-revision'
    if marker.is_file():
        return marker.read_text().strip()
    return subprocess.check_output(
        ['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()


def invoke(command, stdout, stderr, cwd=ROOT):
    # No Haskell compiler/interpreter processes overlap in this runner.
    with stdout.open('w') as out, stderr.open('w') as err:
        result = subprocess.run(command, cwd=cwd, text=True, stdout=out, stderr=err)
    return result.returncode


def pipeline(source, egison):
    stages = [('pre', ['cabal','run','-v0','formurae-pre','--',str(source)], '.egi'),
              ('egison', [str(ROOT/'tools/run_formurae_normalization.sh'),
                          str(egison),str(source.with_suffix('.egi'))], '.feir'),
              ('post', ['cabal','run','-v0','formurae-post','--',
                        str(source.with_suffix('.feir'))], '.fmr')]
    for stage, command, extension in stages:
        out = source.with_suffix(extension)
        err = source.with_suffix(extension+'.stderr')
        status = invoke(command, out, err)
        if status:
            diagnostic = err.read_text().split('  stack trace:')[0]
            return {'accepted': False, 'stage': stage, 'status': status,
                    'diagnostic': diagnostic.replace(str(ROOT)+'/', '')}
    return {'accepted': True, 'stage': 'Formura source'}


def execute_constitutive(source, spherical):
    directory = source.parent / (source.stem+'-c')
    directory.mkdir(exist_ok=True)
    (directory/'model.fmr').write_text(source.with_suffix('.fmr').read_text())
    # Values are checked at index (2,1,1): R=1.5 and T=1.25.
    (directory/'model.yaml').write_text('''length_per_node: [1.25, 1.25, 1.25]
grid_per_node: [5, 5, 5]
mpi_shape: [1, 1, 1]
boundary: [fixed 0.0, fixed 0.0, fixed 0.0]
''')
    subprocess.run([str(ROOT/'bin/formura'), 'model.fmr'], cwd=directory,
                   stdout=(directory/'generation.log').open('w'),
                   stderr=subprocess.STDOUT, check=True)
    pairs = [(0,0),(1,1),(2,2),(0,1),(0,2),(1,2)]
    accesses = ','.join('formura_data.q_up%d_up%d[2][1][1]' % (i+1,j+1)
                        for i,j in pairs)
    (directory/'check.c').write_text('''#include "model.h"
int main(int argc,char **argv) {
  Formura_Navi n;
  Formura_Init(&argc,&argv,&n);
  Formura_Forward(&n);
  printf("[%.17g,%.17g,%.17g,%.17g,%.17g,%.17g]\\n",'''+accesses+''');
  Formura_Finalize();
  return 0;
}
''')
    subprocess.run(['cc','-O2','-std=c11','-I'+str(ROOT/'mpistub'),
                    'check.c','model.c','-lm','-o','check'],cwd=directory,check=True)
    raw = subprocess.check_output([str(directory/'check')],text=True,cwd=directory)
    values = json.loads(next(line for line in raw.splitlines() if line.startswith('[')))
    e = [[1,2,3],[2,4,5],[3,5,6]]
    d = [1,1/1.5**2,1/(1.5*math.sin(1.25))**2 if spherical else 1]
    trace = sum(d[i]*e[i][i] for i in range(3))
    target = [(2*d[i]*trace if i==j else 0)+2*d[i]*d[j]*e[i][j]
              +(0.5*e[0][0] if i==j==0 else 0) for i,j in pairs]
    return {'values_in_order_00_11_22_01_02_12':values,
            'max_error':max(abs(a-b) for a,b in zip(values,target)),
            'compiled_c_executed':True}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--egison-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    egison=args.egison_dir.resolve()
    WORK.mkdir(parents=True,exist_ok=True)
    cases={p.stem:p.read_text() for p in sorted((HERE/'fixtures').glob('*.fme'))}
    spherical=cases['anisotropic_good'].replace('axes r, θ, z','axes r, θ, φ')
    spherical=spherical.replace('metric scale [1, 1+r, 1]',
        'metric scale [1, 1+r, `(1+r) * sin (1+θ)]')
    cases['anisotropic_spherical_good']=spherical
    for coordinate in ['spherical']:
        text=(ROOT/f'examples/elastic_{coordinate}/elastic_{coordinate}.fme').read_text()
        text=text.replace('param λ = 2.0','param α = 0.5\nparam λ = 2.0')
        old=next(line for line in text.splitlines() if line.startswith('def stressRate'))
        new=old[:-1]+(' + α * ([| 1, 0, 0 |]~i * [| 1, 0, 0 |]~j)'
                     ' * (([| 1, 0, 0 |]~k * [| 1, 0, 0 |]~l) . E_k_l))')
        text=text.replace(old,new)
        cases['elastic_'+coordinate+'_good']=text
        cases['elastic_'+coordinate+'_bad']=text.replace('[| 1, 0, 0 |]~j',
                                                        '[| 0, 1, 0 |]~j')
    results={}
    for name,text in cases.items():
        source=WORK/(name+'.fme');source.write_text(text)
        record=pipeline(source,egison)
        record['source_sha256']=hashlib.sha256(text.encode()).hexdigest()
        record['source']=str(source.relative_to(ROOT))
        expected_reject=name.endswith('_bad')
        record['matches_expectation'] = record['accepted'] != expected_reject
        if expected_reject:
            message=record.get('diagnostic','')
            marker=('placement mismatch' if name.startswith('placement')
                    else 'tensor metadata mismatch' if name.startswith('variance')
                    else 'symmetric tensor layout mismatch')
            record['matches_expectation'] &= marker in message and 'expanded from' in message
        if name in ['anisotropic_good','anisotropic_spherical_good'] and record['accepted']:
            record['numerical']=execute_constitutive(source,'spherical' in name)
            record['matches_expectation'] &= record['numerical']['max_error']<1e-12
        if name=='flux_collocated' and record['accepted']:
            output=source.with_suffix('.fmr').read_text()
            update=next(line.strip() for line in output.splitlines() if "q'[i] =" in line)
            record['generated_update']=update
            # Execute the compiler's scalar expression on the common three samples.
            expression=update.split(' = ',1)[1]
            expression=expression.replace('u[i-1]','1.0').replace('u[i+1]','9.0')
            expression=expression.replace('u[i]','4.0').replace('dx','0.25')
            record['whole_flux_centered_value']=eval(expression,{'__builtins__':{}})
            record['matches_expectation'] &= record['whole_flux_centered_value']==80
        results[name]=record
        print(name, 'accepted' if record['accepted'] else 'rejected', flush=True)
    report={'system':'Formurae','egison_revision':egison_revision(egison),
            'results':results,'all_expected':all(r['matches_expectation'] for r in results.values())}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    if not report['all_expected']: raise SystemExit('a comparison expectation failed')


if __name__=='__main__':
    main()
