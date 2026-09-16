#!/usr/bin/env python3
"""Check diagnostics computed in Formurae and run small reference cases."""
import argparse
import csv
import json
import math
from pathlib import Path
from run import ROOT, build, run


def check(directory, *, require_overhang=False, still=False, planar=False):
    directory = Path(directory)
    with (directory/'stats.csv').open() as f:
        rows=[{k:float(v) for k,v in row.items()} for row in csv.DictReader(f)]
    meta=json.loads((directory/'metadata.json').read_text())
    assert rows and rows[-1]['step']==meta['steps'], 'incomplete run'
    assert all(math.isfinite(v) for row in rows for v in row.values()), 'nonfinite diagnostic'
    initial=rows[0]['water']
    assert initial>0, 'empty initial water'
    drift=max(abs(row['water']-initial)/initial for row in rows)
    maximum=lambda key:max(row[key] for row in rows)
    assert drift<1e-9, f'mass drift {drift}'
    assert maximum('bank')<1e-6, 'unredistributed mass'
    assert maximum('bad')==0, 'out-of-bounds state'
    if require_overhang:
        assert maximum('overhang')>=3, 'no resolved overhang'
        assert maximum('span_velocity')>1e-5, 'no spanwise motion'
        assert maximum('span_difference')>.01, 'no spanwise surface variation'
    if still:
        assert maximum('speed')<.001, 'still water developed a large velocity'
        assert maximum('overhang')==0, 'still water developed an overhang'
    if planar:
        assert maximum('span_velocity')<1e-12, 'planar flow lost spanwise symmetry'
        assert maximum('span_difference')<1e-12, 'planar surface lost spanwise symmetry'
    result={'directory':str(directory.resolve().relative_to(ROOT)), 'grid':meta['grid'],
            'steps':meta['steps'], 'relative_mass_drift':drift,
            'max_unredistributed_mass_per_cell':maximum('bank'),
            'max_speed':maximum('speed'), 'max_overhang_cells':maximum('overhang'),
            'max_spanwise_velocity':maximum('span_velocity'),
            'max_spanwise_fraction_difference':maximum('span_difference')}
    print(json.dumps(result,indent=2),flush=True)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',nargs='?',type=Path,default=ROOT/'.build/breaking_wave3d/demo')
    p.add_argument('--reference-cases',action='store_true')
    p.add_argument('--require-overhang',action='store_true')
    a=p.parse_args()
    results=[check(a.directory,require_overhang=a.require_overhang)]
    if a.reference_cases:
        for name, parameters, steps in [
            ('still',{'depth':20,'amplitude':0,'beachSlope':0,'ripple':0,'bend':0},400),
            ('planar',{'depth':20,'amplitude':8,'center':24,'width':10,
                       'beachStart':55,'ripple':0,'bend':0},200)]:
            directory=ROOT/'.build/breaking_wave3d'/name
            build(directory,(80,56,12),parameters)
            run(directory,steps,20)
            results.append(check(directory,still=name=='still',planar=True))
    (a.directory/'verification.json').write_text(json.dumps(results,indent=2)+'\n')


if __name__=='__main__': main()
