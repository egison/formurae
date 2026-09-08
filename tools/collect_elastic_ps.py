#!/usr/bin/env python3
"""Generate and validate common P/S diagnostics; record 3-D pulse propagation.

Requires NumPy, the pinned Egison setup, Cabal, bin/formura, and cc.
All compiler and simulation invocations are sequential.
"""
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import subprocess
import sys

import numpy as np

ROOT=Path(__file__).resolve().parents[1]
EX=ROOT/'examples/elastic_curvilinear'
WORK=ROOT/'.build/elastic-ps'
OUT=EX/'results/ps-propagation'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args,cwd,stdout,stderr=None):
    with stdout.open('w') as out:
        if stderr:
            with stderr.open('w') as err:
                subprocess.run(args,cwd=cwd,stdout=out,stderr=err,check=True)
        else:
            subprocess.run(args,cwd=cwd,stdout=out,stderr=subprocess.STDOUT,check=True)


def grid_info(coordinate,n=48,angular=128):
    spherical=coordinate=='spherical'
    dims=[n+1,n+1,angular] if spherical else [n+1,angular,n+1]
    spacing=[1/n,(math.pi-2)/n,2*math.pi/angular] if spherical else [1/n,2*math.pi/angular,1/n]
    q=np.indices(dims);r=1+q[0]*spacing[0];t=q[1]*spacing[1]+int(spherical)
    u=q[2]*spacing[2]
    if spherical:
        basis=np.array([[np.sin(t)*np.cos(u),np.sin(t)*np.sin(u),np.cos(t)],
                        [np.cos(t)*np.cos(u),np.cos(t)*np.sin(u),-np.sin(t)],
                        [-np.sin(u),np.cos(u),np.zeros_like(r)]])
        xyz=r*basis[0]
        scale=np.array([np.ones_like(r),r,r*np.sin(t)])
    else:
        z=np.zeros_like(r);o=np.ones_like(r)
        basis=np.array([[np.cos(t),np.sin(t),z],[-np.sin(t),np.cos(t),z],[z,z,o]])
        xyz=np.array([r*np.cos(t),r*np.sin(t),u])
        scale=np.array([o,r,o])
    return dims,spacing,xyz,basis,scale


def build(fmr,coordinate,work,header,n=48,angular=128):
    work.mkdir(parents=True,exist_ok=True);name=fmr.stem
    shutil.copy2(fmr,work/fmr.name)
    spherical=coordinate=='spherical'
    dims=[n+1,n+1,angular] if spherical else [n+1,angular,n+1]
    lengths=[(n+1)/n,(math.pi-2)*(n+1)/n,2*math.pi] if spherical else [(n+1)/n,2*math.pi,(n+1)/n]
    boundary='[fixed 0.0, fixed 0.0, periodic]' if spherical else '[fixed 0.0, periodic, fixed 0.0]'
    (work/f'{name}.yaml').write_text(f'length_per_node: {lengths}\ngrid_per_node: {dims}\nmpi_shape: [1,1,1]\nboundary: {boundary}\n')
    (work/'driver.c').write_text(f'#define SPHERICAL {int(spherical)}\n#include "{name}.h"\n#include "{header}"\n')
    run([str(ROOT/'bin/formura'),fmr.name],work,work/'formura.log')
    run(['cc','-O2','-std=c11','-I.',f'-I{ROOT}/mpistub','driver.c',f'{name}.c','-lm','-o','check'],work,work/'cc.log')
    return work/'check'


def derivative(a,axis,h,bounded):
    result=(np.roll(a,-1,axis=axis)-np.roll(a,1,axis=axis))/(2*h)
    if bounded:
        lo=[slice(None)]*3;hi=lo.copy();lo[axis]=0;hi[axis]=1
        result[tuple(lo)]=(a[tuple(hi)]-a[tuple(lo)])/h
        lo[axis]=-1;hi[axis]=-2
        result[tuple(lo)]=(a[tuple(lo)]-a[tuple(hi)])/h
    return result


def reference(velocity,spacing,scale,coordinate):
    volume=np.prod(scale,axis=0);covariant=scale**2*velocity
    def d(a,j):
        return derivative(a,j,spacing[j],j==0 or j==(1 if coordinate=='spherical' else 2))
    div=sum(d(volume*velocity[j],j) for j in range(3))/volume
    curl=np.array([d(covariant[2],1)-d(covariant[1],2),
                   d(covariant[0],2)-d(covariant[2],0),
                   d(covariant[1],0)-d(covariant[0],1)])/volume
    return np.concatenate([div[None],curl])


def evaluate(exe,velocity_file,dims,target):
    run([str(exe),str(velocity_file),str(target)],exe.parent,exe.parent/'check.log')
    result=np.fromfile(target,dtype=np.float64).reshape((4,*dims))
    assert np.isfinite(result).all()
    return result


def analytic_checks(coordinate,fmr):
    results=[]
    matrices={'general':np.array([[.2,.3,-.4],[-.1,.5,.2],[.3,-.2,-.1]]),
              'irrotational':np.diag([.2,.5,-.1]),
              'solenoidal':np.array([[0,-.4,-.2],[.4,0,-.3],[.2,.3,0]])}
    for n in [16,32,64]:
        work=WORK/coordinate/f'analytic-{n}'
        exe=build(fmr,coordinate,work,EX/'diagnostics_check.h',n,n)
        dims,spacing,xyz,basis,scale=grid_info(coordinate,n,n)
        interior=[slice(None)]*3
        interior[0]=slice(2,-2);interior[1 if coordinate=='spherical' else 2]=slice(2,-2)
        for name,A in matrices.items():
            cart=np.einsum('ij,j...->i...',A,xyz)
            velocity=np.einsum('ij...,j...->i...',basis,cart)/scale
            velocity.tofile(work/'input.bin')
            got=evaluate(exe,work/'input.bin',dims,work/'output.bin')
            ref=reference(velocity,spacing,scale,coordinate)
            err=np.max(np.abs(got-ref));assert err<5e-11,(coordinate,n,name,err)
            curl_cart=np.einsum('ij...,i...->j...',basis,scale*got[1:])
            exact_curl=np.array([A[2,1]-A[1,2],A[0,2]-A[2,0],A[1,0]-A[0,1]])
            diverr=float(np.max(np.abs(got[0][tuple(interior)]-np.trace(A))))
            curlerr=float(np.max(np.abs((curl_cart-exact_curl[:,None,None,None])[(slice(None),*interior)])))
            results.append({'coordinate':coordinate,'n':n,'case':name,'reference_error':float(err),
                            'div_error':diverr,'curl_error':curlerr,'max_error':max(diverr,curlerr)})
        print(coordinate,'analytic',n,'passed',flush=True)
    orders={}
    for name in matrices:
        errors=[r['max_error'] for r in results if r['case']==name]
        orders[name]=[math.log(errors[i]/errors[i+1],2) for i in range(2)]
        assert min(orders[name])>1.7,(coordinate,name,orders[name])
    return {'runs':results,'orders':orders}


def main():
    assert sys.byteorder=='little' and np.dtype('float64').itemsize==8
    WORK.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True)
    egison=subprocess.check_output([str(ROOT/'tools/prepare_elastic_validation.sh')],text=True).strip()
    report={'description':'Full 3-D pulse; common generated metric divergence and curl; independent and analytic checks.',
            'platform':platform.platform(),'numpy':np.__version__,'binary_byte_order':sys.byteorder,
            'egison_revision':(Path(egison)/'.formurae-revision').read_text().strip(),
            'compiler':subprocess.check_output(['cc','--version'],text=True).splitlines()[0],
            'source_sha256':{},'build_sha256':{},'results':[]}
    functions=[[line for line in (EX/f'diagnostics_{c}.fme').read_text().splitlines() if line.startswith('def ')] for c in ['cylindrical','spherical']]
    assert len(functions[0])==2 and functions[0]==functions[1]
    elastic=[[line for line in (ROOT/f'examples/elastic_{c}/elastic_{c}.fme').read_text().splitlines() if line.startswith('def ')] for c in ['cylindrical','spherical']]
    assert len(elastic[0])==3 and elastic[0]==elastic[1]
    for coordinate in ['cylindrical','spherical']:
        name='diagnostics_'+coordinate;source=EX/f'{name}.fme'
        # The complete new operator path is generated, without compiler edits.
        run(['cabal','run','-v0','formurae-pre','--',str(source)],ROOT,WORK/f'{name}.egi',WORK/f'{name}-pre.log')
        run([str(ROOT/'tools/run_formurae_normalization.sh'),egison,str(WORK/f'{name}.egi')],ROOT,WORK/f'{name}.feir',WORK/f'{name}-egison.log')
        run(['cabal','run','-v0','formurae-post','--',str(WORK/f'{name}.feir')],ROOT,EX/f'{name}.fmr',WORK/f'{name}-post.log')
        fmr=EX/f'{name}.fmr'
        analytic=analytic_checks(coordinate,fmr)
        diag=build(fmr,coordinate,WORK/coordinate/'diagnostics',EX/'diagnostics_check.h')
        wave=build(ROOT/f'examples/elastic_{coordinate}/elastic_{coordinate}.fmr',coordinate,
                   WORK/coordinate/'wave',EX/'propagation_ps_check.h')
        frames=WORK/coordinate/'frames';frames.mkdir(exist_ok=True)
        run([str(wave),str(frames)],wave.parent,wave.parent/'run.log')
        wave_records=[json.loads(line) for line in (wave.parent/'run.log').read_text().splitlines() if line.startswith('{')]
        assert len(wave_records)==1 and wave_records[0]['ok']
        result=wave_records[0];result['analytic']=analytic;result['frames']=[]
        dims,spacing,xyz,basis,scale=grid_info(coordinate)
        dest=OUT/coordinate;dest.mkdir(exist_ok=True)
        for step in range(0,577,24):
            velocity_file=frames/f'velocity-{step:04d}.bin'
            velocity=np.fromfile(velocity_file,dtype=np.float64).reshape((3,*dims))
            got=evaluate(diag,velocity_file,dims,frames/f'diagnostics-{step:04d}.bin')
            ref=reference(velocity,spacing,scale,coordinate)
            error=float(np.max(np.abs(got-ref)));assert error<5e-11,(coordinate,step,error)
            curl_norm=np.sqrt(np.sum((got[1:]*scale)**2,axis=0))
            # All frames remain available for the movie, with no time interpolation.
            np.savez_compressed(frames/f'ps-{step:04d}.npz',div=got[0],curl=curl_norm)
            if step in [96,192,384]:
                shutil.copy2(frames/f'ps-{step:04d}.npz',dest/f'ps-{step:04d}.npz')
            result['frames'].append({'step':step,'time':step*result['dt'],'reference_error':error,
                'div_peak':float(np.max(np.abs(got[0]))),'curl_peak':float(np.max(curl_norm)),
                'velocity_sha256':sha(velocity_file),'diagnostics_sha256':sha(frames/f'diagnostics-{step:04d}.bin'),
                'plot_data_sha256':sha(frames/f'ps-{step:04d}.npz')})
        result['data_sha256']={str(p.relative_to(OUT)):sha(p) for p in sorted(dest.glob('*.npz'))}
        report['results'].append(result)
        print(coordinate,'25 full-volume diagnostics passed',flush=True)
        (OUT/'records.json').write_text(json.dumps(report,indent=2)+'\n')
    sources=[Path(__file__),EX/'propagation_ps_check.h',EX/'diagnostics_check.h',EX/'elastic_check.h']
    sources+=list((ROOT/'src').rglob('*.hs'))+list((ROOT/'lib').glob('*.egi'))
    for coordinate in ['cylindrical','spherical']:
        sources += [EX/f'diagnostics_{coordinate}.{s}' for s in ['fme','fmr']]
        sources += [ROOT/f'examples/elastic_{coordinate}/elastic_{coordinate}.{s}' for s in ['fme','fmr']]
    report['source_sha256']={str(p.relative_to(ROOT)):sha(p) for p in sources}
    report['build_sha256']={str(p.relative_to(ROOT)):sha(p) for p in sorted(WORK.rglob('*')) if p.is_file() and (p.suffix in ['.c','.h','.yaml','.egi','.feir'] or p.name=='check')}
    report['all_passed']=True
    (OUT/'records.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    main()
