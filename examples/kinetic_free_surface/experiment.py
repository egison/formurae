#!/usr/bin/env python3
"""Configure the generated model, collect its diagnostics, and draw saved fields."""
import argparse
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import subprocess
import shlex
import time
import numpy as np
import run


def execute(args):
    if args.height_method>=2 and args.surface_position!=1:
        raise ValueError('height-method 2–5 reconstructs the surface height; use height-method 1 with surface-position 0 for the face-centred pressure control')
    directory=run.directory_for(*args.grid,args.mpi)
    build=json.loads((directory/'build.json').read_text())
    assert build['grid']==args.grid and build['length']==args.length and build['mpi']==args.mpi
    assert build['source_sha256']==run.sha(run.HERE/f'{run.NAME}.fme')
    assert build['driver_sha256']==run.sha(run.HERE/'driver.c')
    assert build['config_sha256']==run.sha(run.HERE/'config.h')
    assert build['build_script_sha256']==run.sha(run.HERE/'run.py')
    assert build['toolchain']==run.helpers.toolchain()
    assert build['binaries']['record']==run.sha(directory/'record')
    assert build['recorder_sha256']==run.sha(run.ROOT/'gallery/tools/field_frames.h')
    assert build['frameFields']==5
    output=directory/args.label
    output.mkdir(exist_ok=True)
    for name in ['result.json','frames.npz','snapshots.png']:
        (output/name).unlink(missing_ok=True)
    values=dict(lengthX=args.length[0],lengthY=args.length[1],warpX=args.warp[0],warpY=args.warp[1],scenario=args.scenario,gravity=args.gravity,level=args.level,amplitude=args.amplitude,waveCenter=args.center,waveWidth=args.width,bedStart=args.bed_start,bedSlope=args.bed_slope,speed=args.speed,tau=args.tau,timeScale=args.time_scale,periodic=int(args.periodic),method=args.method,surfacePosition=args.surface_position,fittedBed=args.fitted_bed,wetFraction=args.wet_fraction,heightMethod=args.height_method,wallSlip=args.wall_slip,boundarySlope=args.boundary_slope,collisionImplicit=args.collision_implicit,compression=args.compression,launch=args.launch,alignmentFloor=args.alignment_floor,verticalStart=args.vertical_start)
    # Step count is run configuration, not a model update.
    hx,hy=[l/n for l,n in zip(args.length,args.grid)]
    dt=args.time_scale*.1*hx*hy/(hx+hy)
    steps=round(args.duration/dt)
    interval=max(1,steps//args.reports)
    arguments=[steps,interval,*[values[k] for k in run.PARAMETERS]]
    environment=dict(os.environ)
    raw=output/'raw'
    raw.mkdir(exist_ok=True)
    for p in raw.glob('*.bin'): p.unlink()
    environment['FORMURAE_FRAME_DIR']=str(raw)
    command=[str(directory/'record'),*map(str,arguments)]
    if args.mpi!=[1,1]:
        command=[os.environ.get('MPIRUN','mpirun'),*shlex.split(os.environ.get('MPIRUN_ARGS','')),'-np',str(args.mpi[0]*args.mpi[1]),*command]
    launch_environment={key:environment[key] for key in ['MPIRUN','MPIRUN_ARGS','HWLOC_SYNTHETIC'] if key in environment}
    (output/'configuration.json').write_text(json.dumps(dict(parameters=values,grid=args.grid,length=args.length,mpi=args.mpi,arguments=arguments,command=command,launch_environment=launch_environment,source_sha256=run.sha(run.HERE/f'{run.NAME}.fme')),indent=2)+'\n')
    started=time.monotonic()
    with (output/'diagnostics.csv').open('w') as stream:
        subprocess.run(command,env=environment,stdout=stream,check=True,cwd=directory)
    execution_seconds=time.monotonic()-started
    with (output/'diagnostics.csv').open() as stream:
        rows=[{k:float(v) for k,v in row.items()} for row in csv.DictReader(stream)]
    finite=all(math.isfinite(v) for row in rows for v in row.values())
    result=dict(parameters=values,grid=args.grid,length=args.length,mpi=args.mpi,arguments=arguments,history=rows,finite=finite,source_sha256=build['source_sha256'],build=build,orchestration_sha256=run.sha(Path(__file__)),mass_drift=max(abs(r['waterMass']-rows[0]['waterMass']) for r in rows),final=rows[-1],execution_seconds=execution_seconds)
    print(json.dumps(dict(finite=finite,mass_drift=result['mass_drift'],final=rows[-1],execution_seconds=execution_seconds)),flush=True)
    files=sorted(raw.glob('*.bin'))
    updates=np.array([int(p.stem) for p in files])
    fields=np.stack([np.fromfile(p,dtype=np.float64).reshape(5,args.grid[1],args.grid[0]) for p in files])
    by_update={int(row['update']):row for row in rows}
    np.testing.assert_array_equal(updates,np.array(list(by_update)))
    times=np.array([by_update[int(update)]['elapsed'] for update in updates])
    np.savez_compressed(output/'frames.npz',fields=fields,time=times,updates=updates)
    for p in files:p.unlink()
    raw.rmdir()
    result['files']={name:run.sha(output/name) for name in ['configuration.json','diagnostics.csv','frames.npz']}
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    draw(output)
    return result


def draw(output):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.colors import LinearSegmentedColormap
    config=json.loads((output/'configuration.json').read_text())
    nx,ny=config['grid']; lx,ly=config['length']; pars=config['parameters']
    with np.load(output/'frames.npz') as data:
        fields=data['fields']; times=data['time']
    xx,yy=np.meshgrid(np.linspace(0,lx,nx+1),np.linspace(0,ly,ny+1))
    ox,oy=(1-pars['periodic'])*lx/nx,(1-pars['periodic'])*ly/ny
    phase=np.sin(2*np.pi*(xx-ox)/(lx-2*ox))*np.sin(2*np.pi*(yy-oy)/(ly-2*oy))
    X,Y=(xx-ox)*lx/(lx-2*ox)+pars['warpX']*phase,(yy-oy)*ly/(ly-2*oy)+pars['warpY']*phase
    if pars['fittedBed']>.5:
        bed=pars['bedSlope']*np.maximum(X-pars['bedStart'],0)
        Y=bed+(ly-bed)*(yy-oy)/(ly-2*oy)+pars['warpY']*phase
    xc=(X[:-1,:-1]+X[:-1,1:]+X[1:,:-1]+X[1:,1:])/4
    yc=(Y[:-1,:-1]+Y[:-1,1:]+Y[1:,:-1]+Y[1:,1:])/4
    ground=LinearSegmentedColormap.from_list('ground',['#c2ae88','#c2ae88'])
    cmap=LinearSegmentedColormap.from_list('water',['#f5fafc','#75bfd2','#006e99'])
    fig,axes=plt.subplots(2,3,figsize=(13,7),layout='constrained')
    for ax,frame in zip(axes.flat,np.linspace(0,len(times)-1,6,dtype=int)):
        f=fields[frame]
        ax.pcolormesh(X,Y,f[0],shading='flat',vmin=0,vmax=1,cmap=cmap)
        if np.isfinite(f).all():
            ax.contour(xc,yc,f[0],levels=[.5],colors='#06344a',linewidths=1)
            stride=max(1,nx//15)
            sample=(slice(None,None,stride),slice(None,None,stride))
            ax.quiver(xc[sample],yc[sample],np.ma.masked_where(f[0][sample]<pars['wetFraction'],f[2][sample]),np.ma.masked_where(f[0][sample]<pars['wetFraction'],f[3][sample]),angles='xy',scale_units='xy',scale=.5)
        if pars['fittedBed']>.5 and not pars['periodic']:
            ax.fill_between(X[1,1:-1],Y[1,1:-1],0,color='#c2ae88',zorder=4)
        ax.pcolormesh(X,Y,np.ma.masked_where(f[4]<.5,f[4]),shading='flat',vmin=0,vmax=1,cmap=ground)
        ax.set(xlim=(0,lx),ylim=(0,ly),aspect='equal',title=f't = {times[frame]:.3f}',xlabel='X',ylabel='Y')
    fig.suptitle(output.name)
    fig.savefig(output/'snapshots.png',dpi=120);plt.close(fig)
    print(output/'snapshots.png',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('label')
    p.add_argument('--grid',type=int,nargs=2,default=[32,32])
    p.add_argument('--length',type=float,nargs=2,default=[1,1])
    p.add_argument('--warp',type=float,nargs=2,default=[0,0])
    p.add_argument('--mpi',type=int,nargs=2,default=[1,1])
    p.add_argument('--reports',type=int,default=100)
    p.add_argument('--duration',type=float,default=2)
    p.add_argument('--scenario',type=int,choices=range(8),default=0)
    p.add_argument('--gravity',type=float,default=.02)
    p.add_argument('--level',type=float,default=.5)
    p.add_argument('--amplitude',type=float,default=.03)
    p.add_argument('--center',type=float,default=.3)
    p.add_argument('--width',type=float,default=.12)
    p.add_argument('--bed-start',type=float,default=.6)
    p.add_argument('--bed-slope',type=float,default=0)
    p.add_argument('--speed',type=float,default=.1)
    p.add_argument('--tau',type=float,default=.02)
    p.add_argument('--time-scale',type=float,default=1)
    p.add_argument('--periodic',action='store_true')
    p.add_argument('--surface-position',type=int,choices=[0,1],default=1)
    p.add_argument('--method',type=int,choices=[0,1,2,3,4],default=1)
    p.add_argument('--compression',type=float,default=5)
    p.add_argument('--launch',type=float,default=1)
    p.add_argument('--alignment-floor',type=float,default=1e-12)
    p.add_argument('--vertical-start',type=int,choices=[0,1],default=1)
    p.add_argument('--fitted-bed',type=int,choices=[0,1],default=1)
    p.add_argument('--wet-fraction',type=float,default=.01)
    p.add_argument('--height-method',type=int,choices=[0,1,2,3,4,5],default=1)
    p.add_argument('--wall-slip',type=int,choices=[0,1],default=1)
    p.add_argument('--boundary-slope',type=int,choices=[0,1],default=1)
    p.add_argument('--collision-implicit',type=int,choices=[0,1],default=1)
    args=p.parse_args();execute(args)
