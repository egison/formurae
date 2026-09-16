#!/usr/bin/env python3
"""Build/run application comparisons, using only the usual Formurae pipeline.

Python selects parameters, invokes existing tools, and records their outputs.
Every initial state, boundary flux, update and physical diagnostic is in FME.
All compilation and simulation processes are run sequentially.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SPECS = {
    'battery_cooling': {
        'axes': ['r', 'z'], 'grid': [33, 97], 'length': [0.007, 0.065], 'bounded': True,
        'steps': 40000, 'every': 500,
        'fields': ['T'],
        'reductions': ['time = max clock', 'maximum = max T', 'minimum = min T',
                       'heat = sum heat', 'supplied = sum supplied', 'removed = sum removed',
                       'balance = sum balance', 'error = absmax uniformError'],
        'cases': {'side-isotropic': {'axial': '0.5'}, 'side-anisotropic': {},
                  'ends-anisotropic': {'side': '0.0', 'ends': '50.0'},
                  'both-anisotropic': {'ends': '50.0'}},
    },
    'composite_ultrasound': {
        'axes': ['x', 'y'], 'grid': [256, 192], 'length': [16.0, 12.0], 'bounded': False,
        'steps': 960, 'every': 12,
        'fields': ['speed', 'v_up1', 'v_up2', 'E_down1_down1', 'E_down1_down2', 'E_down2_down2'],
        'reductions': ['time = max clock', 'maximum = max speed', 'energy = sum energy',
                       'modified = sum modified', 'signal = sum signal', 'error = absmax modeError'],
        'cases': {'healthy-0': {}, 'soft-0': {'damage': '0.7'},
                  'healthy-45': {'angle': '0.7853981633974483'},
                  'soft-45': {'damage': '0.7', 'angle': '0.7853981633974483'}},
    },
}

def call(command, directory, label, cwd=None, output=None, env=None):
    print(directory.name, label, flush=True)
    with (directory / (label + '.log')).open('w') as log:
        if output:
            with Path(output).open('w') as stream:
                result = subprocess.run(list(map(str, command)), cwd=cwd or ROOT, env=env,
                                        stdout=stream, stderr=log)
        else:
            result = subprocess.run(list(map(str, command)), cwd=cwd or ROOT, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((directory / (label + '.log')).read_text()[-6000:])
        raise subprocess.CalledProcessError(result.returncode, command)

def driver(name, spec):
    fields = ', '.join('formura_data.' + f + '[i][j]' for f in spec['fields'])
    reductions = [r.split(' = ')[0] for r in spec['reductions']]
    formats = ','.join(['%d'] + ['%.17g'] * len(reductions))
    values = ', '.join(['n.time_step'] + ['n.reduce_' + r for r in reductions])
    code = r'''/* I/O only: no initializers, updates or physical diagnostics here. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "NAME.h"
static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  snprintf(path, sizeof path, "%s/frame-%07d-rank-%03d.bin", directory, n.time_step, n.my_rank);
  FILE *f = fopen(path, "wb"); if (!f) { perror(path); exit(2); }
  int32_t header[] = {n.total_grid_x, n.total_grid_y, n.time_step, NFIELDS};
  if (fwrite(header, sizeof header, 1, f) != 1) exit(2);
  for (int i=n.lower_x; i<n.upper_x; ++i) for (int j=n.lower_y; j<n.upper_y; ++j) {
    int32_t index[] = {((i+n.offset_x)%n.total_grid_x+n.total_grid_x)%n.total_grid_x,
                       ((j+n.offset_y)%n.total_grid_y+n.total_grid_y)%n.total_grid_y};
    double values[] = {FIELDS};
    if (fwrite(index, sizeof index, 1, f)!=1 || fwrite(values, sizeof values, 1, f)!=1) exit(2);
  }
  if (fclose(f)) exit(2);
}
int main(int argc, char **argv) {
  int steps=argc>1?atoi(argv[1]):100, every=argc>2?atoi(argv[2]):steps;
  const char *directory=argc>3?argv[3]:NULL;
  if (steps<1 || every<1 || steps%every) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  if (n.my_rank==0) puts("step,REDUCTIONS");
  for (int target=0; target<=steps; target+=every) {
    while(n.time_step<target) Formura_Forward(&n);
    if(n.time_step!=target || !isfinite(n.reduce_maximum)) return 1;
    if(n.my_rank==0) printf("FORMATS\n", VALUES);
    if(directory) dump(n,directory);
  }
  Formura_Finalize(); return 0;
}
'''.replace('NAME', name).replace('NFIELDS', str(len(spec['fields']))).replace('FIELDS', fields).replace('REDUCTIONS', ','.join(reductions)).replace('FORMATS', formats).replace('VALUES', values)
    for old, new in zip(['x', 'y'], spec['axes']):
        for member in ('total_grid_', 'offset_', 'lower_', 'upper_'):
            code = code.replace(member + old, member + new)
    return code

def build(name, directory, changes=None, grid=None, mpi=(1, 1), blocking=0, fresh=False):
    spec = SPECS[name]
    directory = Path(directory).resolve(); directory.mkdir(parents=True, exist_ok=True)
    grid = grid or spec['grid']
    source = (ROOT / 'examples' / name / (name + '.fme')).read_text()
    for key, value in (changes or {}).items():
        source, count = re.subn(r'^param ' + re.escape(key) + r' = .*$',
                               lambda m: 'param ' + key + ' = ' + str(value), source, flags=re.M)
        if count != 1: raise ValueError(key)
    (directory / (name + '.fme')).write_text(source)
    shape = [n // p for n, p in zip(grid, mpi)]
    if any(n % p for n, p in zip(grid, mpi)): raise ValueError('grid / mpi mismatch')
    spacing = [L / (n - 1 if spec['bounded'] else n) for L, n in zip(spec['length'], grid)]
    cfg = ['length_per_node: ' + json.dumps([h*n for h, n in zip(spacing, shape)]),
           'grid_per_node: ' + json.dumps(shape), 'mpi_shape: ' + json.dumps(list(mpi)),
           'boundary: [' + ', '.join(['fixed 0.0' if spec['bounded'] else 'periodic']*2) + ']']
    if blocking:
        # Full padded extent is a valid block for these small verification grids.
        sleeve = 2 if spec['bounded'] else 3
        cfg += ['grid_per_block: ' + json.dumps([n + 2*sleeve*blocking for n in shape]),
                'temporal_blocking_interval: ' + str(blocking)]
    cfg += ['reduces: [' + ', '.join(spec['reductions']) + ']']
    (directory / (name + '.yaml')).write_text('\n'.join(cfg) + '\n')
    egison = Path(os.environ.get('EGISON_DIR', ROOT.parent / 'egison')).resolve()
    # Include tool/source revisions in the cache key. Parameters remain symbolic.
    canonical = re.sub(r'^(param \S+ = ).*$', r'\1@', source, flags=re.M)
    tool_hash = hashlib.sha256()
    for path in sorted((ROOT/'src').rglob('*.hs')):
        tool_hash.update(path.read_bytes())
    revision = subprocess.check_output(['git','-C',str(egison),'rev-parse','HEAD'], text=True).strip()
    key = hashlib.sha256((canonical + revision + tool_hash.hexdigest()).encode()).hexdigest()[:20]
    cache = ROOT / '.build' / 'application_demos' / 'normalized' / name / key
    cache.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, EGISON_HEAP_LIMIT='4G')
    if fresh or not (cache / (name + '.fmr')).exists():
        model = cache / (name + '.fme'); model.write_text(source)
        call(['cabal','run','-v0','formurae-pre','--',model], cache,'pre', output=cache/(name+'.egi'),env=env)
        call([ROOT/'tools/run_formurae_normalization.sh',egison,cache/(name+'.egi')],cache,'egison',output=cache/(name+'.feir'),env=env)
        call(['cabal','run','-v0','formurae-post','--',cache/(name+'.feir')],cache,'post',output=cache/(name+'.fmr.tmp'),env=env)
        (cache/(name+'.fmr.tmp')).replace(cache/(name+'.fmr'))
    program = (cache/(name+'.fmr')).read_text()
    original = dict(re.findall(r'^param (\S+) = (.*)$', (cache/(name+'.fme')).read_text(), re.M))
    params = dict(re.findall(r'^param (\S+) = (.*)$', source, re.M))
    generated = [k for k in re.findall(r'^double :: (\S+) =', program, re.M) if not k.startswith('sbp')]
    if len(params) != len(generated): raise ValueError('parameter correspondence')
    for translated, (surface, value) in zip(generated, params.items()):
        if value != original[surface]:
            program, count = re.subn(r'^double :: '+re.escape(translated)+r' = .*$', lambda m:'double :: '+translated+' = '+value, program, flags=re.M)
            if count != 1: raise ValueError(translated)
    (directory/(name+'.fmr')).write_text(program)
    call([os.environ.get('FORMURA',str(ROOT/'bin/formura')),name+'.fmr'],directory,'formura',cwd=directory)
    (directory/'driver.c').write_text(driver(name,spec))
    parallel = tuple(mpi)!=(1,1)
    cc = os.environ.get('MPICC','mpicc') if parallel else os.environ.get('CC','cc')
    flags = [] if parallel else ['-I'+str(ROOT/'mpistub')]
    call([cc,'-O2','-std=c11',*flags,'driver.c',name+'.c','-lm','-o','check'],directory,'cc',cwd=directory)
    metadata = {'name':name,'parameters':params,'grid':grid,'spacing':spacing,'mpi':list(mpi),'blocking':blocking,
                'fields':spec['fields'],'source_sha256':hashlib.sha256(source.encode()).hexdigest(),
                'egison_revision':revision,'normalized':str(cache.relative_to(ROOT))}
    (directory/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    return directory

def run(directory, steps, every, dump=True):
    directory = Path(directory).resolve()
    meta = json.loads((directory/'metadata.json').read_text())
    data = directory/'data'; data.mkdir(exist_ok=True)
    for path in data.glob('frame-*.bin'): path.unlink()
    command = [directory/'check',steps,every]
    if dump: command.append(data)
    if meta['mpi'] != [1,1]:
        import shlex
        command = [os.environ.get('MPIRUN','mpirun'),*shlex.split(os.environ.get('MPIRUN_ARGS','')), '-np',meta['mpi'][0]*meta['mpi'][1],*command]
    call(command,directory,'run',output=directory/'stats.csv')
    meta.update(steps=steps,every=every)
    (directory/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
    with (directory/'stats.csv').open() as f: rows=list(csv.DictReader(f))
    print(rows[-1],flush=True)
    return [{k:float(v) for k,v in row.items()} for row in rows]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name',choices=list(SPECS)+['optics_design'])
    parser.add_argument('--case',default='all'); parser.add_argument('--grid',type=int,nargs=2)
    parser.add_argument('--steps',type=int); parser.add_argument('--every',type=int)
    parser.add_argument('--param',action='append',default=[]); parser.add_argument('--fresh',action='store_true')
    args=parser.parse_args()
    if args.name=='optics_design':
        sys.path.insert(0,str(ROOT/'examples/transformation_optics'))
        import run as optics
        cases={'zero':{'twist':'0.0'},'turn22':{'twist':'0.39269908169872414'},
               'turn45':{'twist':'0.7853981633974483'},'turn45-wide':{'twist':'0.7853981633974483','R1':'0.5','R1s':'0.4'}}
        if args.case != 'all': cases = {args.case: cases[args.case]}
        for case,params in cases.items():
            params = params | dict(x.split('=',1) for x in args.param)
            d=optics.build(ROOT/'.build/application_demos/optics_design'/case,'rotator',grid=tuple(args.grid or [240,180]),blocking=0,overrides=params)
            optics.run(d,args.steps or 1500,args.every or 25)
        return
    spec=SPECS[args.name]
    cases=spec['cases'] if args.case=='all' else {args.case:spec['cases'].get(args.case,{})}
    for case,params in cases.items():
        params=params|dict(x.split('=',1) for x in args.param)
        d=build(args.name,ROOT/'.build/application_demos'/args.name/case,params,args.grid,fresh=args.fresh)
        run(d,args.steps or spec['steps'],args.every or spec['every'])

if __name__=='__main__': main()
