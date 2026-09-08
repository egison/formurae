#!/usr/bin/env python3
"""Generate, validate and time Formurae against independently written Formura.

All generation, compilation and measurements are serial. --prepare performs
the compiler work; --measure performs only validation and timing.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / '.build/abstraction-benchmark'
CASES = {
    'diffusion3d': ['u'],
    'pearson3d': ['U', 'V'],
    'maxwell3d_yee': ['E_down1', 'E_down2', 'E_down3', 'B_down1', 'B_down2', 'B_down3'],
    'elastic3d': ['v_up1', 'v_up2', 'v_up3', 'sigma_up1_up1', 'sigma_up2_up2',
                  'sigma_up3_up3', 'sigma_up1_up2', 'sigma_up1_up3', 'sigma_up2_up3'],
    'mhd_ot': ['rho', 'mx', 'my', 'mz', 'bx', 'by', 'bz', 'en'],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, cwd, log):
    with log.open('w') as out:
        subprocess.run(args, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, check=True)


def seed(case, name, n):
    if case == 'diffusion3d':
        return '1.0+0.1*sin(x)*cos(y)+0.05*cos(z)'
    if case == 'pearson3d':
        return '0.7+0.1*sin(x)*sin(y)' if name == 'U' else '0.15+0.02*cos(z)*cos(x)'
    if case == 'mhd_ot':
        return {'rho': '1.0+0.02*sin(x)*cos(y)*cos(z)',
                'mx': '0.05*sin(y)*cos(z)', 'my': '0.04*sin(z)*cos(x)',
                'mz': '0.03*sin(x)*cos(y)', 'bx': '0.1+0.01*sin(y)',
                'by': '0.1+0.01*sin(z)', 'bz': '0.1+0.01*sin(x)',
                'en': '2.0+0.02*cos(x)*cos(y)*cos(z)'}[name]
    return f'0.02*(sin(x+{n+1}.0)*cos(y)+cos(y+{n+2}.0)*sin(z)+cos(z+{n+3}.0)*sin(x))'


def driver(case, fields):
    fill = '\n'.join(f'formura_data.{f}[i][j][k]={seed(case,f,n)};'
                     for n, f in enumerate(fields))
    access = ','.join(f'formura_data.{f}[i][j][k]' for f in fields)
    dumps = '\n'.join(f'if (fwrite(formura_data.{f},sizeof(double),L1*L2*L3,fp)!=L1*L2*L3) return 5;'
                      for f in fields)
    return r'''#define _POSIX_C_SOURCE 200809L
#include "model.h"
#include <time.h>
static double now(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec+1e-9*t.tv_nsec;
}
int main(int argc,char **argv) {
  int steps=argc>1?atoi(argv[1]):256, warm=argc>2?atoi(argv[2]):32;
  if(steps<=0 || steps%4 || warm%4) return 2;
  const char *dump=argc>3?argv[3]:NULL;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  for(int i=0;i<L1;i++) for(int j=0;j<L2;j++) for(int k=0;k<L3;k++) {
    double x=6.283185307179586*i/L1,y=6.283185307179586*j/L2,z=6.283185307179586*k/L3;
''' + fill + r'''
  }
  while(n.time_step<warm) Formura_Forward(&n);
  int start=n.time_step;
  double begin=now();
  while(n.time_step<start+steps) Formura_Forward(&n);
  double elapsed=now()-begin;
  double checksum=0.0;
  for(int i=0;i<L1;i++) for(int j=0;j<L2;j++) for(int k=0;k<L3;k++) {
    double v[]={''' + access + r'''};
    for(unsigned f=0;f<sizeof(v)/sizeof(v[0]);f++) {
      if(!isfinite(v[f])) return 3;
      checksum+=v[f]*(1+0.001*f);
    }
  }
  if(dump) {
    FILE *fp=fopen(dump,"wb"); if(!fp) return 4;
''' + dumps + r'''
    fclose(fp);
  }
  printf("{\"seconds\":%.17g,\"steps\":%d,\"warmup_steps\":%d,\"checksum\":%.17g}\n",
         elapsed,n.time_step-start,start,checksum);
  Formura_Finalize(); return 0;
}
'''


def prepare(cases, sizes, egison):
    manifest = {'cases': cases, 'sizes': sizes, 'temporal_blocking': 4, 'spatial_block': [8,8,8],
                'compiler_flags': ['-O2','-std=c11'], 'processes': 1,
                'egison_revision': subprocess.check_output(['git','rev-parse','HEAD'],cwd=egison,text=True).strip(),
                'formura_sha256': sha(ROOT/'bin/formura'), 'source_sha256': {}, 'builds': {}}
    for case in cases:
        folder=WORK/case; folder.mkdir(parents=True,exist_ok=True)
        source=ROOT/f'examples/{case}/{case}.fme'
        copied=folder/'model.fme'; shutil.copy2(source,copied)
        manifest['source_sha256'][str(source.relative_to(ROOT))]=sha(source)
        ref=HERE/f'manual/{case}.fmr'
        manifest['source_sha256'][str(ref.relative_to(ROOT))]=sha(ref)
        for args,suffix in [(['cabal','run','-v0','formurae-pre','--',str(copied)],'.egi'),
                            ([str(ROOT/'tools/run_formurae_normalization.sh'),str(egison),str(copied.with_suffix('.egi'))],'.feir'),
                            (['cabal','run','-v0','formurae-post','--',str(copied.with_suffix('.feir'))],'.fmr')]:
            with copied.with_suffix(suffix).open('w') as out, copied.with_suffix(suffix+'.stderr').open('w') as err:
                subprocess.run(args,cwd=ROOT,stdout=out,stderr=err,check=True)
        print(case, 'normalized', flush=True)
        for size in sizes:
            for variant in ['generated','manual']:
                dest=folder/f'{size}/{variant}';dest.mkdir(parents=True,exist_ok=True)
                shutil.copy2(copied.with_suffix('.fmr') if variant=='generated' else ref,dest/'model.fmr')
                length=size*0.001 if case=='pearson3d' else 1.0
                config=f'length_per_node: {[length]*3}\ngrid_per_node: {[size]*3}\ngrid_per_block: [8,8,8]\ntemporal_blocking_interval: 4\nmpi_shape: [1,1,1]\n'
                (dest/'model.yaml').write_text(config)
                (dest/'driver.c').write_text(driver(case,CASES[case]))
                command([str(ROOT/'bin/formura'),'model.fmr'],dest,dest/'formura.log')
                command(['cc','-O2','-std=c11','-I'+str(ROOT/'mpistub'),'driver.c','model.c','-lm','-o','run'],dest,dest/'cc.log')
                manifest['builds'][f'{case}/{size}/{variant}']={f:sha(dest/f) for f in ['model.fmr','model.yaml','model.c','model.h','driver.c','run']}
                print(case,size,variant,'built',flush=True)
    for directory in ['src','lib','spec']:
        for f in sorted((ROOT/directory).rglob('*')):
            if f.is_file():manifest['source_sha256'][str(f.relative_to(ROOT))]=sha(f)
    manifest['source_sha256'][str(Path(__file__).relative_to(ROOT))]=sha(Path(__file__))
    (WORK/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


def execute(case, size, variant, steps, warm=32, dump=False):
    folder=WORK/case/str(size)/variant
    args=[str(folder/'run'),str(steps),str(warm)]
    if dump:args.append('state.bin')
    raw=subprocess.check_output(args,cwd=folder,text=True)
    result=json.loads(next(s for s in raw.splitlines() if s.startswith('{')))
    assert result['steps']==steps and result['warmup_steps']==warm
    return result


def check(case,size,steps,warm):
    states=[]
    for v in ['generated','manual']:
        execute(case,size,v,steps,warm,True)
        path=WORK/case/str(size)/v/'state.bin'
        states.append(np.fromfile(path,dtype=np.float64));path.unlink()
    a,b=states
    assert a.size==b.size==len(CASES[case])*size**3
    error=np.abs(a-b);scaled=error/np.maximum(1.,np.maximum(np.abs(a),np.abs(b)))
    assert np.isfinite(a).all() and np.isfinite(b).all() and scaled.max()<2e-10,(case,size,scaled.max())
    return {'steps':steps,'warmup_steps':warm,'values':a.size,'max_absolute_error':float(error.max()),'max_scaled_error':float(scaled.max())}


def measure(repetitions,target,output):
    manifest=json.loads((WORK/'manifest.json').read_text())
    for name,digest in manifest['source_sha256'].items():
        assert sha(ROOT/name)==digest,('changed source',name)
    for name,entries in manifest['builds'].items():
        for filename,digest in entries.items():assert sha(WORK/name/filename)==digest
    report={'method':'ratio of median kernel times; serial alternating pairs; clock_gettime; no initialization, output, or compilation in timed region',
            'host':{'cpu':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
                    'os':platform.platform(),'cc':subprocess.check_output(['cc','--version'],text=True).splitlines()[0]},
            'manifest':manifest,'repetitions':repetitions,'target_seconds':target,'results':[]}
    for case in manifest['cases']:
        for size in manifest['sizes']:
            short=check(case,size,4,0)
            pilots=[execute(case,size,v,32)['seconds'] for v in ['generated','manual']]
            steps=max(32,4*math.ceil(target/min(pilots)*32/4))
            # Independent full-array comparison also covers the measured trajectory.
            long=check(case,size,steps,32)
            samples={'generated':[],'manual':[]}
            for n in range(repetitions):
                for v in (['generated','manual'] if n%2==0 else ['manual','generated']):
                    samples[v].append(execute(case,size,v,steps)['seconds'])
            med={v:statistics.median(s) for v,s in samples.items()}
            result={'case':case,'grid':[size]*3,'steps':steps,'warmup_steps':32,
                    'samples_seconds':samples,'median_seconds':med,
                    'generated_over_manual':med['generated']/med['manual'],
                    'interquartile_seconds':{v:[float(np.percentile(s,25)),float(np.percentile(s,75))] for v,s in samples.items()},
                    'validation':[short,long]}
            report['results'].append(result)
            output.parent.mkdir(parents=True,exist_ok=True)
            output.write_text(json.dumps(report,indent=2)+'\n')
            print(case,size,'steps',steps,'ratio',round(result['generated_over_manual'],4),'error',long['max_absolute_error'],flush=True)
    report['all_passed']=True
    output.write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--prepare',action='store_true');p.add_argument('--measure',action='store_true')
    p.add_argument('--egison-dir',type=Path,default=ROOT/'.build/egison-abstraction-bench')
    p.add_argument('--cases',nargs='+',choices=CASES,default=list(CASES))
    p.add_argument('--sizes',nargs='+',type=int,default=[32,64])
    p.add_argument('--repetitions',type=int,default=9);p.add_argument('--target-seconds',type=float,default=0.4)
    p.add_argument('--output',type=Path,default=HERE/'results.json')
    a=p.parse_args();WORK.mkdir(parents=True,exist_ok=True)
    if not(a.prepare or a.measure):p.error('select --prepare and/or --measure')
    if a.prepare:prepare(a.cases,a.sizes,a.egison_dir.resolve())
    if a.measure:measure(a.repetitions,a.target_seconds,a.output.resolve())
