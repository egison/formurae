"""Check that rendered surfaces keep moving after release, and videos are complete."""
import json

import imageio_ffmpeg
from PIL import Image

from tensor_demo_common import WORK,RESULTS,sha,write_report
from tensor_demo_render import ASSETS


def main():
    records=json.loads((ASSETS/'render.json').read_text());motion=[];movies=[]
    for case in ['press-ball','twist-tube']:
        report=json.loads((RESULTS/f'{case}.json').read_text())
        hashes=[sha(WORK/'render'/case/f'frame-{i:04d}.png') for i,row in enumerate(report['frames'])
                if row['time']>=report['release']]
        distinct=len(set(hashes))
        # These raw surface frames have no changing clock or captions: a frozen
        # VTK scene cannot pass merely because overlay text keeps changing.
        assert distinct>.95*len(hashes),(case,distinct,len(hashes))
        motion.append(dict(case=case,frames_after_release=len(hashes),distinct_surface_frames=distinct))
    for case,count in [('press-ball',181),('twist-tube',221),('couette-recoil',193)]:
        for lang in ['ja','en']:
            name=case+'-'+lang;record=records[name]
            for ext in ['png','gif','mp4']:
                assert sha(ASSETS/f'{name}.{ext}')==record[ext],(name,ext)
            with Image.open(ASSETS/f'{name}.gif') as gif:assert gif.n_frames==count,(name,gif.n_frames)
            frames,duration=imageio_ffmpeg.count_frames_and_secs(str(ASSETS/f'{name}.mp4'))
            assert frames==count,(name,frames,count)
            if case!='couette-recoil':
                assert record['simulation_report_sha256']==sha(RESULTS/f'{case}.json')
                assert record['renderer_sha256']==sha(__file__.replace('animation_checks','manipulation_render'))
            movies.append(dict(name=name,frames=frames,duration=duration,mp4_sha256=record['mp4']))
    write_report('animation-validation',dict(surface_motion=motion,movies=movies))
    print('Animation verification:',motion,flush=True)
    print('All six introductory MP4/GIF files have the expected frame counts and hashes.',flush=True)


if __name__=='__main__':main()
