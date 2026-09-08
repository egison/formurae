#!/usr/bin/env python3
"""Build and check actual 3-D elastic propagation, serially.

The previously validated generated Formura programs are unchanged. New C
initialization supplies a compact Cartesian velocity pulse to each model.
"""
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'examples/elastic_curvilinear/results/propagation'
WORK=ROOT/'.build/elastic-propagation'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args,cwd,log):
    with log.open('w') as stream:
        subprocess.run(args,cwd=cwd,stdout=stream,stderr=subprocess.STDOUT,check=True)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report={'description':'Compact Cartesian x-velocity pulse; generated three-dimensional updates; physical meridional slices at t=0,0.2,0.4,0.6.',
            'compiler':subprocess.check_output(['cc','--version'],text=True).splitlines()[0],
            'platform':platform.platform(),'source_sha256':{},'build_sha256':{},'results':[]}
    definitions=[]
    for coordinate in ['cylindrical','spherical']:
        source=ROOT/f'examples/elastic_{coordinate}/elastic_{coordinate}.fme'
        definitions.append([line for line in source.read_text().splitlines() if line.startswith('def ')])
    assert len(definitions[0])==3 and definitions[0]==definitions[1]
    for source in [Path(__file__),ROOT/'examples/elastic_curvilinear/propagation_check.h',ROOT/'examples/elastic_curvilinear/elastic_check.h']:
        report['source_sha256'][str(source.relative_to(ROOT))]=sha(source)
    for coordinate in ['cylindrical','spherical']:
        name='elastic_'+coordinate;spherical=coordinate=='spherical'
        work=WORK/name;work.mkdir(parents=True,exist_ok=True)
        output=OUT/coordinate;output.mkdir(exist_ok=True)
        for suffix in ['fme','fmr']:
            source=ROOT/f'examples/{name}/{name}.{suffix}'
            report['source_sha256'][str(source.relative_to(ROOT))]=sha(source)
        shutil.copy2(ROOT/f'examples/{name}/{name}.fmr',work/f'{name}.fmr')
        dims=[49,49,128] if spherical else [49,128,49]
        lengths=[49/48,(math.pi-2)*49/48,2*math.pi] if spherical else [49/48,2*math.pi,49/48]
        boundary='[fixed 0.0, fixed 0.0, periodic]' if spherical else '[fixed 0.0, periodic, fixed 0.0]'
        (work/f'{name}.yaml').write_text(f'length_per_node: {lengths}\ngrid_per_node: {dims}\nmpi_shape: [1,1,1]\nboundary: {boundary}\n')
        header=ROOT/'examples/elastic_curvilinear/propagation_check.h'
        (work/'driver.c').write_text(f'#define SPHERICAL {int(spherical)}\n#include "{name}.h"\n#include "{header}"\n')
        command([str(ROOT/'bin/formura'),f'{name}.fmr'],work,work/'formura.log')
        command(['cc','-O2','-std=c11','-I.',f'-I{ROOT}/mpistub','driver.c',f'{name}.c','-lm','-o','check'],work,work/'cc.log')
        for filename in [f'{name}.fmr',f'{name}.yaml',f'{name}.c',f'{name}.h','driver.c','check']:
            report['build_sha256'][str((work/filename).relative_to(ROOT))]=sha(work/filename)
        print(name,'built',flush=True)
        start=time.monotonic();command([str(work/'check'),str(output)],work,work/'run.log')
        records=[json.loads(line) for line in (work/'run.log').read_text().splitlines() if line.startswith('{')]
        assert len(records)==1 and records[0]['ok']
        record=records[0];record['elapsed_seconds']=time.monotonic()-start
        record['data_sha256']={str(f.relative_to(OUT)):sha(f) for f in sorted(output.glob('*.dat'))}
        assert len(record['data_sha256'])==5
        report['results'].append(record)
        (OUT/'records.json').write_text(json.dumps(report,indent=2)+'\n')
        print(name,'all checks passed',flush=True)
    report['all_passed']=True
    (OUT/'records.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    main()
