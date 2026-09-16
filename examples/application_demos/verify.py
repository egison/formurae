#!/usr/bin/env python3
"""Compare generated outputs. Analytical errors and physical sums are FME fields."""
import csv
import json
from pathlib import Path
import shutil
import struct
from run import ROOT, SPECS, build, run

OUT=ROOT/'.build/application_demos/verification'
RESULT=ROOT/'examples/application_demos/results'

def table(directory):
    with (directory/'stats.csv').open() as f: return [{k:float(v) for k,v in r.items()} for r in csv.DictReader(f)]

def fields(directory, step):
    data={}
    for path in (directory/'data').glob(f'frame-{step:07d}-rank-*.bin'):
        raw=path.read_bytes(); nx,ny,stamp,nf=struct.unpack_from('=4i',raw)
        assert stamp==step
        for record in struct.iter_unpack('=ii'+'d'*nf,raw[16:]):
            key=record[:2]; assert key not in data; data[key]=record[2:]
    assert len(data)==nx*ny
    return data

def agree(left,right):
    assert left.keys()==right.keys()
    error=max(abs(x-y) for k in left for x,y in zip(left[k],right[k]))
    assert error<1e-11,error
    return error

def main():
    report={}
    for name,spec in SPECS.items():
        cases={}
        for case in spec['cases']:
            d=ROOT/'.build/application_demos'/name/case; rows=table(d)
            if name=='battery_cooling':
                error=max(abs(r['balance'])/max(r['supplied'],1) for r in rows)
                assert error<1e-9,(case,error)
                assert all(r['minimum']>-1e-10 and r['maximum']<120 for r in rows)
                cases[case]={'maximum_temperature_C':25+rows[-1]['maximum'],
                             'temperature_range_K':rows[-1]['maximum']-rows[-1]['minimum'],
                             'relative_heat_balance_error':error}
            else:
                energies=[r['modified'] for r in rows[1:]]
                error=max(abs(e-energies[0])/energies[0] for e in energies)
                assert error<1e-10,(case,error)
                cases[case]={'relative_modified_energy_drift':error,
                             'receiver_peak':max(abs(r['signal']) for r in rows)}
        report[name]={'comparisons':cases}
    # Insulated cell with uniform heating: T = T0 + Q t / capacity, at all nodes.
    d=build('battery_cooling',OUT/'uniform',{'side':'0','ends':'0','hotspot':'0','initial':'2'},[17,33])
    rows=run(d,1000,100,dump=False)
    assert rows[-1]['error']<1e-10,rows[-1]
    report['battery_cooling']['uniform_heating_max_error_K']=rows[-1]['error']
    # Refine space/time together for the case with cooling on both surfaces.
    d=build('battery_cooling',OUT/'battery-fine',{'ends':'50','dt':'0.0025'},[65,193])
    rows=run(d,160000,160000,dump=False)
    coarse=report['battery_cooling']['comparisons']['both-anisotropic']['maximum_temperature_C']
    difference=abs((25+rows[-1]['maximum'])-coarse)
    assert difference<.15,difference
    report['battery_cooling']['fine_grid_maximum_temperature_C']=25+rows[-1]['maximum']
    report['battery_cooling']['refinement_difference_K']=difference
    # Exact longitudinal plane wave along the reinforcement direction.
    errors=[]
    for n in [64,128]:
        dt=.01*64/n
        d=build('composite_ultrasound',OUT/f'mode-{n}',{'mode':'1','dt':str(dt)},[n,n//2])
        rows=run(d,round(.8/dt),round(.8/dt),dump=False)
        errors.append(rows[-1]['error'])
    assert errors[1]<errors[0]/3,errors
    report['composite_ultrasound']['plane_wave_max_errors']=errors
    # Parallel/blocking equivalence on modest grids; includes every dumped state component.
    for name in SPECS:
        grid=[32,48] if name=='battery_cooling' else [64,48]
        changes={'ends':'50'} if name=='battery_cooling' else {'damage':'0.7','angle':'0.7853981633974483'}
        plain=build(name,OUT/(name+'-plain'),changes,grid)
        run(plain,40,40); reference=fields(plain,40)
        blocked=build(name,OUT/(name+'-blocked'),changes,grid,blocking=2)
        run(blocked,40,40)
        report[name]['blocking_max_error']=agree(reference,fields(blocked,40))
        if shutil.which('mpicc') and shutil.which('mpirun'):
            for mpi in [(2,1),(1,2)]:
                parallel=build(name,OUT/(name+f'-mpi-{mpi[0]}-{mpi[1]}'),changes,grid,mpi=mpi,blocking=2)
                run(parallel,40,40)
                report[name][f'mpi_{mpi[0]}_{mpi[1]}_max_error']=agree(reference,fields(parallel,40))
        else: report[name]['mpi']='not tested: MPI tools unavailable'
    report['optics_design']=verify_optics()
    RESULT.mkdir(parents=True,exist_ok=True)
    (RESULT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

def verify_optics():
    # Same existing solver with different maps. Sums below were computed in FME.
    optical={}
    for case in ['zero','turn22','turn45','turn45-wide']:
        rows=table(ROOT/'.build/application_demos/optics_design'/case)
        energies=[r['energy'] for r in rows[1:]]
        drift=max(abs(e-energies[0])/energies[0] for e in energies)
        ratio=rows[-1]['scatter']/rows[-1]['incident']
        assert drift<.05,(case,drift)
        optical[case]={'scattering_ratio':ratio,'relative_energy_drift':drift}
    assert optical['zero']['scattering_ratio']<1e-24,optical
    report={'comparisons':optical}
    import importlib.util
    module_spec=importlib.util.spec_from_file_location('optics_run',ROOT/'examples/transformation_optics/run.py')
    optics=importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(optics)
    changes={'R1':'0.5','R1s':'0.4'}
    coarse=optics.build(OUT/'optics-coarse','rotator',(120,90),blocking=0,overrides=changes)
    optics.run(coarse,750,750,dump=False)
    last=table(coarse)[-1]; ratio=last['scatter']/last['incident']
    assert optical['turn45-wide']['scattering_ratio']<ratio,(optical,ratio)
    report['coarse_grid_scattering_ratio']=ratio
    def electric(directory):
        result={}
        for path in (directory/'data').glob('frame-0000040-rank-*.bin'):
            raw=path.read_bytes(); nx,ny,stamp=struct.unpack_from('=iii',raw)
            assert stamp==40
            for i,j,e,ev in struct.iter_unpack('=iidd',raw[12:]):
                assert (i,j) not in result; result[i,j]=(e,ev)
        assert len(result)==nx*ny
        return result
    plain=optics.build(OUT/'optics-plain','rotator',(80,60),blocking=0,layers=8,overrides=changes)
    optics.run(plain,40,40); reference=electric(plain)
    blocked=optics.build(OUT/'optics-blocked','rotator',(80,60),blocking=2,layers=8,overrides=changes)
    optics.run(blocked,40,40)
    report['blocking_electric_max_error']=agree(reference,electric(blocked))
    if shutil.which('mpicc') and shutil.which('mpirun'):
        for mpi in [(2,1),(1,2)]:
            parallel=optics.build(OUT/f'optics-mpi-{mpi[0]}-{mpi[1]}','rotator',(80,60),mpi=mpi,blocking=2,layers=8,overrides=changes)
            optics.run(parallel,40,40,mpi=mpi)
            report[f'mpi_{mpi[0]}_{mpi[1]}_electric_max_error']=agree(reference,electric(parallel))
    return report

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--optics-only',action='store_true')
    args=p.parse_args()
    if args.optics_only:
        report=json.loads((RESULT/'verification.json').read_text())
        report['optics_design']=verify_optics()
        (RESULT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report['optics_design'],indent=2))
    else:
        main()
