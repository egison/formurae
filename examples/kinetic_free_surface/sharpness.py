#!/usr/bin/env python3
"""Compare the saved FME return error after one periodic water-label circuit."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
import run,verify


def main(args):
    directory=run.directory_for(64,64,args.mpi)
    cases=[]
    for method in [1,2]:
        label=f'translation-return-method-{method}'
        command=[sys.executable,str(run.HERE/'experiment.py'),label,
                 '--grid','64','64','--mpi',*map(str,args.mpi),
                 '--scenario','1','--periodic','--gravity','0',
                 '--speed','.2','--duration','5','--reports','100',
                 '--height-method','2','--method',str(method)]
        subprocess.run(command,cwd=run.ROOT,check=True)
        record=json.loads((directory/label/'result.json').read_text())
        for name,digest in record['files'].items():
            assert run.sha(directory/label/name)==digest
        cases.append(dict(command=command,record=record,checks=verify.translation_return(record)))
    error=[case['checks']['returned_fraction_error'] for case in cases]
    assert error[0]>0
    report=dict(source_sha256=run.sha(run.HERE/f'{run.NAME}.fme'),
                suite_sha256=run.sha(Path(__file__)),verifier_sha256=run.sha(run.HERE/'verify.py'),
                cases=cases,superbee_to_mc_error_ratio=error[1]/error[0],passed=error[1]<error[0])
    (directory/'sharpness.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['passed'], ('fraction transport did not improve',error)
    print('Superbee/MC return-error ratio:',report['superbee_to_mc_error_ratio'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mpi',type=int,nargs=2,default=[2,2])
    main(parser.parse_args())
