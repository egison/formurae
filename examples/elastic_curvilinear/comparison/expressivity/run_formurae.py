#!/usr/bin/env python3
"""Compile user-defined indexed operators serially, then execute generated C."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE.parent))
from formurae_probes import egison_revision, pipeline

WORK = ROOT/'.build/related-work/expressivity-final'


def c_check(source, dimension, assignments, outputs, expected, sample_indices=None):
    folder = source.parent/(source.stem+'-c')
    folder.mkdir(exist_ok=True)
    (folder/'model.fmr').write_text(source.with_suffix('.fmr').read_text())
    (folder/'model.yaml').write_text(
        'length_per_node: '+str([1.75]*dimension)+'\n'
        'grid_per_node: '+str([7]*dimension)+'\n'
        'mpi_shape: '+str([1]*dimension)+'\n'
        'boundary: ['+', '.join(['fixed 0.0']*dimension)+']\n')
    with (folder/'generation.log').open('w') as log:
        subprocess.run([str(ROOT/'bin/formura'), 'model.fmr'], cwd=folder,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    fill_index = '[i][j][k]' if dimension == 3 else '[i][j]'
    sample_indices = sample_indices or [2]*dimension
    read_index = ''.join('['+str(i)+']' for i in sample_indices)
    fill = ''.join('formura_data.'+name+fill_index+'='+expression+';\n'
                   for name, expression in assignments.items())
    loops = 'for(int i=0;i<7;i++) for(int j=0;j<7;j++) '
    if dimension == 3:
        loops += 'for(int k=0;k<7;k++) '
    locations = 'double x=i*0.25,y=j*0.25,z='+('k*0.25' if dimension == 3 else '0')+';'
    accesses = ','.join('formura_data.'+name+read_index for name in outputs)
    (folder/'check.c').write_text('#include "model.h"\n'
        'int main(int argc,char **argv) { Formura_Navi nav;\n'
        'Formura_Init(&argc,&argv,&nav);\n'+loops+'{'+locations+fill+'}\n'
        'Formura_Forward(&nav);\n'
        'printf("['+','.join(['%.17g']*len(outputs))+']\\n",'+accesses+');\n'
        'Formura_Finalize(); return 0; }\n')
    subprocess.run(['cc','-O2','-std=c11','-I'+str(ROOT/'mpistub'),
                    'check.c','model.c','-lm','-o','check'], cwd=folder, check=True)
    raw = subprocess.check_output([str(folder/'check')], cwd=folder, text=True)
    values = json.loads(next(s for s in raw.splitlines() if s.startswith('[')))
    difference = max(abs(a-b) for a,b in zip(values,expected))
    assert len(values) == len(expected) and difference < 1e-12, (source.name,values,expected)
    return {'compiled_c_executed':True, 'sample_indices':sample_indices, 'component_names':outputs,
            'values':values, 'expected':expected, 'max_error':difference}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--egison-dir', type=Path, required=True)
    args = parser.parse_args()
    egison = args.egison_dir.resolve()
    WORK.mkdir(parents=True, exist_ok=True)
    cases = {p.stem:p.read_text() for p in sorted(HERE.glob('*.fme'))}
    cases['curl_renamed'] = cases['curl'].replace('rotation','swirl').replace(
        'withSymbols [i,j,k] (epsilon_i~j~k . ∂/∂ X_k coordinates~j)',
        'withSymbols [p,q,s] (epsilon_p~q~s . ∂/∂ X_s coordinates~q)')
    results = {}
    for name, text in cases.items():
        source = WORK/(name+'.fme')
        source.write_text(text)
        record = pipeline(source, egison)
        assert record['accepted'], record
        record['input_sha256'] = hashlib.sha256(text.encode()).hexdigest()
        print(name, 'normalized', flush=True)
        if name == 'indexed_functions':
            outputs = ['aligned_down'+str(i) for i in range(1,4)]
            outputs += ['pairs_down%d_down%d'%(i,j) for i in range(1,4) for j in range(1,4)]
            outputs += ['reduced']+['%s_up%d'%(q,i) for q in ['q','r'] for i in range(1,4)]
            outputs += ['S_down%d_down%d'%(i,j) for i,j in [(1,1),(2,2),(3,3),(1,2),(1,3),(2,3)]]
            flux = lambda a,b:(a*a+a*b+b*b)/6
            expected = [flux(a,b) for a,b in zip([1,2,3],[4,5,6])]
            expected += [flux(a,b) for a in [1,2,3] for b in [4,5,6]]
            expected += [20.5,224,256,288,224,256,288,1,5,9,3,5,7]
            record['numerical'] = c_check(source,3,{},outputs,expected)
        elif name == 'exterior_3d':
            assignments = {'f':'x*y*z', 'A_1':'(x+0.125)*y',
                'A_2':'(y+0.125)*z', 'A_3':'(z+0.125)*x',
                'B_1_2':'(x+0.125)*z', 'B_1_3':'y*(z+0.125)',
                'B_2_3':'x*(y+0.125)'}
            outputs = ['G_1','G_2','G_3','H_1_2','H_1_3','H_2_3','K_1_2_3',
                       'Z_1_2','Z_1_3','Z_2_3','J_1','J_2','J_3',
                       'Y_1_2','Y_1_3','Y_2_3','W_1_2_3']
            expected = [0.25]*3+[-0.625,0.625,-0.625,0.625]+[0]*3+[0.25]*3+[0]*4
            record['numerical'] = c_check(source,3,assignments,outputs,expected)
            # Y = d(G') and W = d(H') differentiate the stored arrays of the
            # same step: d(d f) and d(d A) through storage, zero to rounding.
            record['numerical']['stored_dd_max_abs'] = max(
                abs(v) for v in record['numerical']['values'][-4:])
        elif name == 'exterior_2d':
            assignments = {'f':'x*y','A_1':'(x+0.125)*y','A_2':'x*(y+0.125)'}
            record['numerical'] = c_check(source,2,assignments,
                ['G_1','G_2','H_1_2','Z_1_2','Y_1_2'],[0.5,0.5,0,0,0])
            record['numerical']['stored_dd_max_abs'] = abs(record['numerical']['values'][-1])
        else:
            assignments = {'A_down1':'x*y','A_down2':'y*z','A_down3':'z*x'}
            outputs = ['%s_down%d'%(q,i) for q in ['R','S'] for i in range(1,4)]
            record['numerical'] = c_check(source,3,assignments,outputs,
                                         [-0.75,-1.0,-0.5]*2,[2,3,4])
        results[name] = record
    identical = (WORK/'curl.fmr').read_bytes() == (WORK/'curl_renamed.fmr').read_bytes()
    assert identical
    # The exterior-derivative definition itself is shared unchanged across dimensions.
    bodies = [cases[n].split('def exterior A =\n')[1].split('\n\n')[0].split('\ndef ')[0]
              for n in ['exterior_2d','exterior_3d']]
    assert bodies[0] == bodies[1]
    files = [*HERE.glob('*.fme'),Path(__file__).resolve(),
             ROOT/'src/Formurae/Pre/EmitEgison.hs',ROOT/'lib/formurae-operators.egi',
             ROOT/'src/Formurae/Post/FMR.hs',
             ROOT/'lib/formurae-tensor.egi']
    report = {'egison_revision':egison_revision(egison),
              'all_passed':True, 'renaming_preserves_generated_formura':identical,
              'exterior_definition_shared_between_dimensions':True,
              'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted(files)},'results':results}
    (HERE/'results-formurae.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('All',len(results),'generated C programs passed.',flush=True)


if __name__ == '__main__':
    main()
