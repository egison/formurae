"""Serial build/check/simulate/render entry point for the tensor PDE gallery."""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def invoke(script,*args):
    subprocess.run([sys.executable,str(ROOT/'tools'/script),*args],cwd=ROOT,check=True)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('stage',choices=['checks','simulate','render','all'],default='all',nargs='?')
    a=p.parse_args()
    if a.stage in ['checks','all']:
        invoke('tensor_demo_sphere.py')
        for model in ['elastic','nematic','couette']:
            invoke(f'tensor_demo_{model}.py','--validate')
        invoke('tensor_demo_manipulation.py','validate')
        invoke('tensor_demo_manipulation_checks.py')
    if a.stage in ['simulate','all']:
        for geometry in ['cylinder','sphere']:
            invoke('tensor_demo_elastic.py','--geometry',geometry)
        invoke('tensor_demo_nematic.py')
        invoke('tensor_demo_couette.py')
        for case in ['press-ball','twist-tube']:
            invoke('tensor_demo_manipulation.py',case)
    if a.stage in ['render','all']:
        invoke('tensor_demo_render.py')
        invoke('tensor_demo_recoil.py')
        for case in ['press-ball','twist-tube']:
            invoke('tensor_demo_manipulation_render.py',case)
        invoke('tensor_demo_animation_checks.py')
        invoke('tensor_demo_gallery.py')

if __name__=='__main__':main()
