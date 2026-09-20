#!/usr/bin/env python3
"""Normal compiler pipeline and execution; model calculations are in .fme."""
import argparse, csv, hashlib, importlib.util, io, json, os, re, shutil, subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
NAME="kinetic_free_surface"
BASE=ROOT/".build/kinetic-free-surface"
spec=importlib.util.spec_from_file_location("helpers",HERE.parent/"kinetic_coordinates/run.py")
helpers=importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
PARAMETERS=['lengthX', 'lengthY', 'warpX', 'warpY', 'scenario', 'gravity', 'level', 'amplitude', 'waveCenter', 'waveWidth', 'bedStart', 'bedSlope', 'speed', 'tau', 'timeScale', 'periodic', 'method', 'surfacePosition', 'fittedBed', 'wetFraction', 'heightMethod', 'wallSlip', 'boundarySlope', 'collisionImplicit', 'compression', 'launch', 'alignmentFloor', 'verticalStart']
REDUCTIONS='elapsed = max elapsed, waterMass = sum waterMass, waterVolume = sum waterVolume, lowest = min lowest, highest = max highest, densityLowest = min densityLowest, densityHighest = max densityHighest, populationLowest = min populationLowest, peakSpeed = max peakSpeed, restingError = max restingError, wetting = sum wetting, drying = sum drying, movedAmount = sum movedAmount, waterMomentumX = sum waterMomentumX, waterMomentumY = sum waterMomentumY, kineticEnergy = sum kineticEnergy, surfaceHeight = max surfaceHeight, wetFront = max wetFront, shoreFlux = sum shoreFlux, minimumArea = min minimumArea, overhangCells = sum overhangCells, bulkFront = max bulkFront, fractionCourant = max fractionCourant, pressureResidual = max pressureResidual, waveMoment = sum waveMoment, gravityEnergy = sum gravityEnergy, waterCentroidX = sum waterCentroidX, waterCentroidY = sum waterCentroidY, collisionResidual = max collisionResidual, stateConsistencyError = max stateConsistencyError, thinFront = max thinFront, shoreWaterMass = sum shoreWaterMass, thinWaterMass = sum thinWaterMass, surfaceGauge = sum surfaceGauge, firstCrossing = max firstCrossing, wavePeriod = max wavePeriod, expectedPeriod = max expectedPeriod, heightReconstructions = sum heightReconstructions, surfaceReconstructions = sum surfaceReconstructions, gaugeSamples = sum waveGaugeCell, wallMassResidual = max wallMassResidual, wallSlipResidual = max wallSlipResidual, relaxationError = max relaxationError, shearError = max shearError, shearProjection = sum shearProjection, shearExpected = max shearExpected, expectedFallingMomentum = sum expectedFallingMomentum, expectedFallingCentroid = sum expectedFallingCentroid, surfaceMassResidual = max surfaceMassResidual, resolvedCentroidY = sum resolvedCentroidY'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def normalize():
    BASE.mkdir(parents=True,exist_ok=True)
    identity=dict(source=sha(HERE/f"{NAME}.fme"),toolchain=helpers.toolchain())
    shutil.copyfile(HERE/f"{NAME}.fme",BASE/f"{NAME}.fme")
    os.environ.setdefault("EGISON_HEAP_LIMIT","5G")
    helpers.call(["cabal","run","-v0","formurae-pre","--",HERE/f"{NAME}.fme"],BASE,"pre",BASE/f"{NAME}.egi")
    helpers.call([ROOT/"tools/run_formurae_normalization.sh",ROOT.parent/"egison",BASE/f"{NAME}.egi"],BASE,"egison",BASE/f"{NAME}.feir")
    helpers.call(["cabal","run","-v0","formurae-post","--",BASE/f"{NAME}.feir"],BASE,"post",BASE/f"{NAME}.fmr")
    assert identity==dict(source=sha(HERE/f"{NAME}.fme"),toolchain=helpers.toolchain())
    (BASE/"normalization.json").write_text(json.dumps(identity))
def directory_for(nx,ny,mpi=(1,1)):
    suffix='' if tuple(mpi)==(1,1) else f'-mpi-{mpi[0]}-{mpi[1]}'
    return BASE/f'grid-{nx}-{ny}{suffix}'

def compile_flags(directory,mpi):
    parallel=tuple(mpi)!=(1,1)
    compiler=os.environ.get('MPICC','mpicc') if parallel else os.environ.get('CC','cc')
    include=[] if parallel else ['-I'+str(ROOT/'mpistub')]
    return [compiler,'-O2','-std=c11',*include,'-I'+str(directory),'-include',HERE/'config.h']

def build(nx,ny,lx,ly,mpi=(1,1)):
    assert len(mpi)==2 and all(p>0 for p in mpi)
    assert nx%mpi[0]==0 and ny%mpi[1]==0
    directory=directory_for(nx,ny,mpi)
    directory.mkdir(parents=True,exist_ok=True)
    marker=json.loads((BASE/'normalization.json').read_text())
    assert marker==dict(source=sha(HERE/f'{NAME}.fme'),toolchain=helpers.toolchain())
    source=(BASE/f'{NAME}.fmr').read_text()
    for k,name in enumerate(PARAMETERS):
        source,count=re.subn(r'^double :: '+name+r' = .*$',f'double :: {name} = surfaceConfig({k})',source,flags=re.M)
        assert count==1,name
    (directory/f'{NAME}.fmr').write_text(source)
    (directory/f'{NAME}.yaml').write_text(
        f'length_per_node: [{lx/mpi[0]}, {ly/mpi[1]}]\n'
        f'grid_per_node: [{nx//mpi[0]}, {ny//mpi[1]}]\n'
        f'mpi_shape: {list(mpi)}\nboundary: [periodic, periodic]\nreduces: [{REDUCTIONS}]\n')
    helpers.call([ROOT/'bin/formura',f'{NAME}.fmr'],directory,'formura',cwd=directory)
    cc=compile_flags(directory,mpi)
    helpers.call([*cc,'-c',directory/f'{NAME}.c','-o',directory/'solver.o'],directory,'cc-solver')
    helpers.call([*cc,HERE/'driver.c',directory/'solver.o','-lm','-o',directory/'run'],directory,'cc-driver')
    link_recording(directory,nx,ny,lx,ly,marker,mpi)

def link_recording(directory,nx,ny,lx,ly,marker,mpi=(1,1)):
    cc=compile_flags(directory,mpi)
    defines=[f'-DHDR="{NAME}.h"','-DDIM=2','-DFRAME_FIELDS=5','-DFRAME_EVERY=surfaceFrameInterval','-DF1=formura_data.fraction[i][j]','-DF2=formura_data.density[i][j]','-DF3=formura_data.velocityX[i][j]','-DF4=formura_data.velocityY[i][j]','-DF5=formura_data.solid[i][j]']
    if tuple(mpi)!=(1,1):defines.append('-DFRAME_MPI')
    helpers.call([*cc,*defines,'-include',ROOT/'gallery/tools/field_frames.h','-c',HERE/'driver.c','-o',directory/'record.o'],directory,'cc-record')
    helpers.call([cc[0],directory/'record.o',directory/'solver.o','-lm','-o',directory/'record'],directory,'cc-link')
    metadata=dict(source_sha256=marker['source'],toolchain=marker['toolchain'],grid=[nx,ny],length=[lx,ly],mpi=list(mpi),frameFields=5,driver_sha256=sha(HERE/'driver.c'),config_sha256=sha(HERE/'config.h'),build_script_sha256=sha(Path(__file__)),recorder_sha256=sha(ROOT/'gallery/tools/field_frames.h'),generated={ext:sha(BASE/f'{NAME}.{ext}') for ext in ['egi','feir','fmr']},generated_files={ext:sha(directory/f'{NAME}.{ext}') for ext in ['fmr','yaml','c','h']},compiler_flags=list(map(str,cc)),binaries={name:sha(directory/name) for name in ['run','record']})
    (directory/'build.json').write_text(json.dumps(metadata,indent=2)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--normalize',action='store_true')
    parser.add_argument('--grid',type=int,nargs=2,default=[32,32])
    parser.add_argument('--length',type=float,nargs=2,default=[1,1])
    parser.add_argument('--mpi',type=int,nargs=2,default=[1,1])
    args=parser.parse_args()
    if args.normalize:normalize()
    build(*args.grid,*args.length,args.mpi)
