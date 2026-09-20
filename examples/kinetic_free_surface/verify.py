#!/usr/bin/env python3
"""Check diagnostics emitted by Formurae; do not reconstruct model quantities."""
import argparse
import json
import math
from pathlib import Path
import run


def basic(record):
    assert record['source_sha256']==run.sha(run.HERE/f'{run.NAME}.fme'), 'stale model source'
    for key,name in [('driver_sha256','driver.c'),('config_sha256','config.h'),('build_script_sha256','run.py')]:
        assert record['build'][key]==run.sha(run.HERE/name), ('stale build',name)
    # The recorded launcher hash identifies the version that ran the case.
    # Validate its actual physical arguments; later CLI validation or drawing
    # changes do not invalidate an unchanged generated solver and saved data.
    assert record['arguments'][2:]==[record['parameters'][name] for name in run.PARAMETERS], 'physical argument mismatch'
    assert record['grid']==record['build']['grid'] and record['length']==record['build']['length']
    assert record['mpi']==record['build']['mpi']
    if record['parameters']['heightMethod']>=2:
        assert record['parameters']['surfacePosition']==1

    rows=record['history']
    assert record['finite'] and rows
    assert all(math.isfinite(v) for row in rows for v in row.values())
    f=rows[-1]
    relative=record['mass_drift']/rows[0]['waterMass']
    assert relative<5e-10, ('water mass drift',relative)
    assert f['lowest']>=-2e-10 and f['highest']<=1+2e-10, ('fraction bounds',f['lowest'],f['highest'])
    assert f['densityLowest']>.5 and f['densityHighest']<1.5
    assert f['populationLowest']>0
    assert f['peakSpeed']<.3
    assert f['minimumArea']>0
    assert f['fractionCourant']<1
    if record['parameters']['method']>=4:
        # Sufficient explicit positivity bound of the compressive face values.
        assert f['fractionCourant']*record['parameters']['compression']<1, ('compressive positivity bound',f['fractionCourant'],record['parameters']['compression'])
    assert f['pressureResidual']<5e-11, ('atmospheric stress',f['pressureResidual'])
    if record['parameters']['heightMethod']>=5:
        assert f['surfaceMassResidual']<5e-12, ('surface mass flux',f['surfaceMassResidual'])
    assert f['collisionResidual']<5e-12
    assert f['stateConsistencyError']<5e-12
    assert f['wallMassResidual']<5e-12, ('wall mass flux',f['wallMassResidual'])
    if record['parameters']['wallSlip']>.5:
        assert f['wallSlipResidual']<5e-12, ('wall shear flux',f['wallSlipResidual'])
    return dict(relative_water_mass_drift=relative,raw_fraction_range=[f['lowest'],f['highest']],minimum_population_over_weight=f['populationLowest'],maximum_speed=f['peakSpeed'],pressure_stress_residual=f['pressureResidual'])


def rest(record):
    checks=basic(record)
    assert record['final']['restingError']<1e-10
    assert max(r['movedAmount'] for r in record['history'])<1e-10
    return checks


def bed_rest(record):
    checks=basic(record)
    p=record['parameters']; f=record['final']
    assert p['scenario']==4 and p['amplitude']==0 and p['periodic']==0
    assert p['gravity']>0 and p['bedSlope']>0
    assert f['peakSpeed']<.001, ('static slope speed',f['peakSpeed'])
    checks.update(maximum_stationary_speed=f['peakSpeed'],
                  maximum_fraction_change_integral=max(r['movedAmount'] for r in record['history']))
    return checks


def translation(record):
    checks=basic(record)
    f,rows=record['final'],record['history']
    assert record['parameters']['periodic']==1 and record['parameters']['gravity']==0
    assert abs(f['densityHighest']-1)<1e-10 and abs(f['densityLowest']-1)<1e-10
    assert max(r['movedAmount'] for r in rows)>.05
    mass=rows[0]['waterMass'];speed=record['parameters']['speed']
    assert max(abs(r['waterMomentumX']-mass*speed) for r in rows)<1e-10
    assert max(abs(r['waterMomentumY']) for r in rows)<1e-10
    return checks


def translation_return(record):
    checks=translation(record)
    p=record['parameters']; f=record['final']
    assert abs(p['speed']*f['elapsed']-record['length'][0])<1e-9
    # For one complete periodic translation, the initial field is the exact
    # returning profile. FME already computes this area-weighted difference.
    checks.update(returned_fraction_error=f['movedAmount'])
    return checks


def falling(record):
    checks=basic(record)
    p=record['parameters']; rows=record['history']; f=rows[-1]
    assert p['scenario']==7 and p['gravity']>0 and p['periodic']==0
    assert p['bedSlope']==0 and p['warpX']==0 and p['warpY']==0
    assert p['level']>p['amplitude']/2 and p['level']+p['amplitude']/2<record['length'][1]
    moving=[r for r in rows if r['elapsed']>0]
    assert moving and all(r['expectedFallingMomentum']<0 for r in moving)
    errors=[abs(r['waterMomentumY']/r['expectedFallingMomentum']-1) for r in moving]
    assert moving[0]['waterMomentumY']<0, ('upward initial acceleration',moving[0]['waterMomentumY'])
    assert max(errors)<.02, ('free-fall momentum error',max(errors))
    expected_drop=rows[0]['expectedFallingCentroid']-f['expectedFallingCentroid']
    assert expected_drop>0
    # A layer containing a full cell has its water position inside each
    # interface cell inferred from the fuller neighbour (resolvedCentroidY);
    # the plain cell-centre moment of an exactly transported layer with
    # partially filled end cells differs from the analytic moment. A layer
    # thinner than one cell has no inferable sub-cell position, so its plain
    # moment is compared. Both moments are recorded for every case.
    resolved=rows[0]['highest']>=.999
    measure='resolvedCentroidY' if resolved else 'waterCentroidY'
    drops={key:rows[0][key]-f[key] for key in ['waterCentroidY','resolvedCentroidY']}
    centroid_error=abs(drops[measure]/expected_drop-1)
    assert centroid_error<.02, ('free-fall centroid displacement error',centroid_error,measure)
    checks.update(maximum_relative_momentum_error=max(errors),
                  relative_centroid_displacement_error=centroid_error,
                  centroid_measure=measure,
                  plain_centroid_error=abs(drops['waterCentroidY']/expected_drop-1),
                  resolved_centroid_error=abs(drops['resolvedCentroidY']/expected_drop-1),
                  measured_final_momentum=f['waterMomentumY'],
                  reference_final_momentum=f['expectedFallingMomentum'])
    return checks


def backwash_measurements(record):
    """Compare recorded Formurae diagnostics; do not reconstruct water state."""
    rows=record['history']
    hx=record['length'][0]/(record['grid'][0]-2)
    front=[r['wetFront'] for r in rows]
    bulk=[r['bulkFront'] for r in rows]
    thin=[r['thinFront'] for r in rows]
    shore=[r['shoreWaterMass'] for r in rows]
    crest=max(front); crest_index=front.index(crest)
    bulk_peak=max(bulk); bulk_index=bulk.index(bulk_peak)
    thin_peak=max(thin); thin_index=thin.index(thin_peak)
    shore_peak=max(shore); shore_index=shore.index(shore_peak)
    measurements=dict(initial_shoreline=front[0],maximum_shoreline=crest,
        final_shoreline=front[-1],runup=crest-front[0],
        shoreline_retreat=crest-min(front[crest_index:]),
        bulk_retreat=bulk_peak-min(bulk[bulk_index:]),
        minimum_backwash_flux=min(r['shoreFlux'] for r in rows[crest_index:]),
        maximum_overhang_cells=max(r['overhangCells'] for r in rows),
        maximum_thin_front=thin_peak,final_thin_front=thin[-1],
        thin_front_retreat=thin_peak-min(thin[thin_index:]),
        initial_mass_above_shore=shore[0],maximum_mass_above_shore=shore_peak,
        final_mass_above_shore=shore[-1],
        returned_shore_mass=shore_peak-min(shore[shore_index:]),
        cell_width=hx)
    checks=dict(runup=measurements['runup']>=3*hx,
        shoreline_retreat=measurements['shoreline_retreat']>=3*hx,
        bulk_retreat=measurements['bulk_retreat']>=2*hx,
        offshore_flow=measurements['minimum_backwash_flux']<0,
        overturning_candidate=measurements['maximum_overhang_cells']>0,
        thin_layer_retreat=measurements['thin_front_retreat']>=3*hx,
        water_arrived_above_shore=shore_peak>shore[0]+1e-5,
        water_returned_from_shore=measurements['returned_shore_mass']>.1*(shore_peak-shore[0]),
        waterline_avoids_far_wall=crest<record['length'][0]-3*hx,
        thin_layer_avoids_far_wall=thin_peak<record['length'][0]-3*hx)
    return dict(measurements=measurements,criteria=checks)


def backwash(record):
    checks=basic(record)
    p=record['parameters']
    assert p['scenario']==4 and p['periodic']==0 and p['bedSlope']>0
    result=backwash_measurements(record)
    failed=[name for name,passed in result['criteria'].items() if not passed]
    assert not failed, ('backwash criteria',failed)
    checks.update(result['measurements'])
    return checks


def wave(record):
    checks=basic(record)
    rows=record['history']; f=record['final']
    assert record['parameters']['scenario']==2
    assert min(r['waveMoment'] for r in rows)<0, 'no crest/trough reversal'
    assert f['wavePeriod']>0, 'two gauge crossings not measured'
    error=abs(f['wavePeriod']/f['expectedPeriod']-1)
    assert error<.05, ('gravity-wave period error',error)
    checks.update(measured_period=f['wavePeriod'],reference_period=f['expectedPeriod'],relative_period_error=error)
    return checks


def relaxation(record):
    checks=basic(record)
    p=record['parameters']; f=record['final']
    assert p['scenario']==6 and p['gravity']==0 and p['periodic']==1
    assert abs(f['densityHighest']-1)<1e-10 and abs(f['densityLowest']-1)<1e-10
    assert f['peakSpeed']<1e-10
    hx,hy=[l/n for l,n in zip(record['length'],record['grid'])]
    ratio=p['timeScale']*.1*hx*hy/(hx+hy)/p['tau']
    peak=max(r['relaxationError'] for r in record['history'])
    assert ratio<=.1, 'this accuracy check resolves the relaxation time'
    assert peak/(p['amplitude']/9)<.002, ('relaxation accuracy',peak)
    checks.update(timestep_over_relaxation_time=ratio,maximum_stress_error=peak,
                  final_stress_error=f['relaxationError'])
    return checks


def stiff(record):
    checks=basic(record)
    p=record['parameters']; f=record['final']
    assert p['scenario']==6 and p['gravity']==0 and p['periodic']==1
    assert p['collisionImplicit']==1
    hx,hy=[l/n for l,n in zip(record['length'],record['grid'])]
    ratio=p['timeScale']*.1*hx*hy/(hx+hy)/p['tau']
    assert ratio>2
    assert f['elapsed']>20*p['tau']
    assert f['relaxationError']<1e-10
    assert f['peakSpeed']<1e-10
    assert abs(f['densityHighest']-1)<1e-10 and abs(f['densityLowest']-1)<1e-10
    checks.update(timestep_over_relaxation_time=ratio,final_stress_error=f['relaxationError'],
                  maximum_transient_stress_error=max(r['relaxationError'] for r in record['history']),
                  early_transient_accuracy_required=False)
    return checks


def shear(record):
    checks=basic(record)
    p=record['parameters']; f=record['final']
    assert p['scenario']==5 and p['gravity']==0 and p['periodic']==1
    assert f['shearExpected']>0
    error=abs(f['shearProjection']/f['shearExpected']-1)
    assert error<.05, ('shear amplitude error',error)
    assert f['shearError']/p['speed']<.05
    # A small amplitude error can hide a large error in weak viscous decay.
    # Compare the loss itself with the independent continuum reference.
    expected_loss=record['history'][0]['shearExpected']-f['shearExpected']
    measured_loss=record['history'][0]['shearProjection']-f['shearProjection']
    assert expected_loss>1e-8*p['speed']
    decay_error=abs(measured_loss/expected_loss-1)
    assert decay_error<.05, ('shear decay error',decay_error)
    checks.update(measured_amplitude=f['shearProjection'],reference_amplitude=f['shearExpected'],
                  relative_amplitude_error=error,relative_decay_error=decay_error,
                  maximum_velocity_error=f['shearError'])
    return checks


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('result',type=Path)
    parser.add_argument('--case',choices=['basic','rest','bed-rest','translation','translation-return','wave','backwash','relaxation','stiff','shear','falling'],default='basic')
    args=parser.parse_args()
    record=json.loads(args.result.read_text())
    for name,expected in record['files'].items():
        assert run.sha(args.result.parent/name)==expected, ('changed output',name)
    print(json.dumps(globals()[args.case.replace('-', '_')](record),indent=2))
