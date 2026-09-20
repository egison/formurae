#!/usr/bin/env python3
"""Compare detached-layer gravity with references computed by the FME model."""
import json
import subprocess
import sys
from pathlib import Path
import run
import verify


def main():
    directory=run.directory_for(32,32,[1,1])
    # The four candidate cases keep the original 2% acceptance limits.
    # Additional controls isolate pressure, transport and reconstruction;
    # their own failures remain visible and are not called successful tests.
    # label, layer thickness, heightMethod, method, duration, required, extra options
    cases=[('fall-quarter',1/120,5,4,.5,True,[]),
           ('fall-three-quarter',1/40,5,4,.5,True,[]),
           ('fall-resolved',.1,5,4,.5,True,[]),
           ('fall-thick-partial',.32,5,4,.5,True,[]),
           ('fall-thick-compression-8',.32,5,4,.5,False,['--compression','8']),
           ('fall-limited-thick',.32,5,3,.5,False,[]),
           ('fall-incoming-thick',.32,4,4,.5,False,[]),
           ('fall-superbee-quarter',1/120,5,2,.5,False,[]),
           ('fall-first-order-quarter',1/120,5,0,.5,False,[]),
           ('fall-old-boundary',1/120,2,2,.15625,False,[])]
    report=dict(passed=False,source_sha256=run.sha(run.HERE/f'{run.NAME}.fme'),
                suite_sha256=run.sha(Path(__file__)),
                verifier_sha256=run.sha(run.HERE/'verify.py'),cases=[])
    destination=directory/'falling.json'
    for label,thickness,height,method,duration,required,extra in cases:
        command=[sys.executable,str(run.HERE/'experiment.py'),label,'--grid','32','32',
                 '--scenario','7','--gravity','.02','--level',str(31/60),
                 '--amplitude',str(thickness),'--tau','.0025','--method',str(method),
                 '--height-method',str(height),'--duration',str(duration),'--reports','100',*extra]
        print(label,flush=True)
        with (directory/(label+'.log')).open('w') as log:
            subprocess.run(command,cwd=run.ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        output=directory/label
        record=json.loads((output/'result.json').read_text())
        for name,digest in record['files'].items():
            assert run.sha(output/name)==digest
        entry=dict(label=label,command=command,record=record,basic=verify.basic(record),
                   required_candidate=required,expected_failure=height==2)
        try:entry.update(passed=True,measurements=verify.falling(record))
        except AssertionError as error:entry.update(passed=False,failure=str(error))
        report['cases'].append(entry)
        destination.write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({k:entry[k] for k in ['label','passed','expected_failure']},ensure_ascii=False),flush=True)
    corrected=[case for case in report['cases'] if case['required_candidate']]
    control=report['cases'][-1]
    # The retained old-boundary control must reproduce the diagnosed defect;
    # it is not counted as a successful physical calculation.
    assert not control['passed'] and control['record']['history'][1]['waterMomentumY']>0
    report['old_defect_reproduced']=True
    report['passed']=all(case['passed'] for case in corrected)
    destination.write_text(json.dumps(report,indent=2)+'\n')
    print(destination,flush=True)
    if not report['passed']:raise SystemExit(1)


if __name__=='__main__':main()
