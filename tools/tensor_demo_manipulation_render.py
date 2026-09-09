"""Visible grips and material lines for the saved press/release and twist/release runs."""
import argparse
import json

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
import numpy as np
import pyvista as pv

from tensor_demo_common import WORK,RESULTS,sha
from tensor_demo_render import ASSETS,encode,surface_grid


LABELS={
 'ja':{
  'press-ball':dict(title='中空のボールを押して離す',
    phases=['1  片側を押す','2  手を離す','3  反対側へ伝わる'],
    text=['橙色の場所を\nゆっくり内側へ押します．','押す力を取り除くと，\nへこみが戻り始めます．','押した場所から伝わった\n振動で，反対側の表面も\n動きます．'],
    note='表面の線は材料と一緒に動きます．\n一部を切り除き，中空を表示．'),
  'twist-tube':dict(title='管をねじって離す',
    phases=['1  上端をねじる','2  手を離す','3  振動が戻る'],
    text=['下端を固定して，\n上端を回します．\n縦の線がねじれていきます．','ねじれが管を伝わります．\n下端は固定のままです．','下端から戻った振動で，\n上端が逆向きに回ります．'],
    note='橙色の線：回した上端\n灰色の台：固定した下端'),
  'scale':'変形は全区間で {gain} 倍に拡大',
  'computed':'線と表面は計算した変位で動きます'},
 'en':{
  'press-ball':dict(title='Press a hollow ball, then let go',
    phases=['1  Press one side','2  Let go','3  Reaches far side'],
    text=['Push the orange patch\nslowly inward.','Release the grip.\nThe dent begins to recover.','Vibrations travel\nfrom the pressed patch\nand move the far surface.'],
    note='Lines move with the material.\nA cutaway reveals the hollow interior.'),
  'twist-tube':dict(title='Twist a tube, then let go',
    phases=['1  Twist the top','2  Let go','3  Vibration returns'],
    text=['Fix the bottom and\nturn the top.\nThe vertical lines twist.','The twist travels\nalong the tube.\nThe bottom stays fixed.','The vibration returns\nfrom the fixed bottom,\nturning the top back.'],
    note='Orange lines: the turned upper end\nGrey base: the fixed lower end'),
  'scale':'Displacement magnified {gain} times throughout',
  'computed':'Lines and surfaces follow computed displacement'}
}


def geometry(case,report):
    if case=='press-ball':
        surface,ids,sample=surface_grid('sphere',report,azimuth=3*np.pi/2,azimuth_points=81)
        shape=(report['radial']+1,49,81)
    else:
        nr,nt,nz=report['radial']+1,report['angular'],report['angular']//2+1
        R,T,Z=np.meshgrid(np.linspace(1,2,nr),np.linspace(0,2*np.pi,nt+1),
                         np.linspace(0,2*np.pi,nz),indexing='ij')
        grid=pv.StructuredGrid(R*np.cos(T),R*np.sin(T),Z)
        surface=grid.extract_surface(algorithm='dataset_surface');ids=surface['vtkOriginalPointIds']
        shape=R.shape
        def sample(data):
            v=np.concatenate([data[0],data[0,:,:,:1]],axis=2)
            return np.array([np.cos(T)*v[0]-np.sin(T)*v[1],np.sin(T)*v[0]+np.cos(T)*v[1],v[2]])
    index=np.arange(np.prod(shape)).reshape(shape,order='F')
    paths=[]
    if case=='press-ball':
        for j in range(0,81,8):paths.append(index[-1,:,j])
        for i in range(8,49,8):paths.append(index[-1,i,:])
        # Visible boundaries of the open cut, including the inner surface.
        for r in [0,-1]:
            for p in [0,-1]:paths.append(index[r,:,p])
    else:
        for j in range(0,shape[1]-1,max(1,report['angular']//12)):paths.append(index[-1,j,:])
        for k in range(0,shape[2],max(1,(shape[2]-1)//8)):paths.append(index[-1,:,k])
    # The extracted surface contains every material-line point.
    mapping={int(source):i for i,source in enumerate(ids)}
    lines=pv.PolyData(surface.points.copy());lines.verts=np.empty(0,dtype=np.int64)
    lines.lines=np.concatenate([np.r_[len(path),[mapping[int(i)] for i in path]] for path in paths])
    return surface,ids,sample,lines


def render(case,languages=('ja','en')):
    report=json.loads((RESULTS/f'{case}.json').read_text());gain=report['display_magnification']
    mesh,ids,sample,lines=geometry(case,report);base=mesh.points.copy()
    ball=case=='press-ball'
    # Fixed material colours; no stress scale is needed to read the motion.
    colour=np.tile([98,164,207],(mesh.n_points,1)).astype(np.uint8)
    if ball:
        radius=np.linalg.norm(base,axis=1)
        colour[radius<1.1]=[167,204,227]
        colour[(base[:,0]/radius>np.cos(.65))&(radius>1.99)]=[235,139,66]
    else:colour[base[:,2]>2*np.pi-.001]=[235,139,66]
    mesh['material']=colour
    plot=pv.Plotter(off_screen=True,window_size=(700,610),border=False)
    plot.set_background('white')
    plot.add_mesh(mesh,scalars='material',rgb=True,show_scalar_bar=False,ambient=.6,diffuse=.4,specular=0)
    plot.add_mesh(lines,color='#365c77',line_width=1.6,lighting=False)
    if ball:
        plot.camera_position=[(4,-8,2.8),(0,.15,0),(0,0,1)]
        plot.camera.parallel_scale=3.05
    else:
        plot.add_mesh(pv.Cylinder(center=(0,0,-.14),direction=(0,0,1),radius=2.17,height=.24),
                      color='#bdc8d3',ambient=.65)
        plot.camera_position=[(7,-10,7.2),(0,0,3.15),(0,0,1)]
        plot.camera.parallel_scale=4.55
    plot.enable_parallel_projection()
    plot.camera.parallel_scale=3.05 if ball else 4.65
    raw=WORK/'render'/case;raw.mkdir(parents=True,exist_ok=True)
    for frame,row in enumerate(report['frames']):
        with np.load(WORK/case/f'frame-{frame:04d}.npz') as data:
            assert abs(float(data['time'])-row['time'])<1e-10
            displacement=sample(data['u'])
        u=np.array([a.ravel(order='F') for a in displacement]).T[ids]
        mesh.points=base+gain*u;lines.points=mesh.points.copy()
        plot.remove_actor('grip')
        if ball and row['time']<report['release']:
            tip=2+gain*row['pressed_displacement']
            plot.add_mesh(pv.Arrow(start=(tip+.85,0,0),direction=(-1,0,0),scale=.7),
                          color='#df7735',lighting=False,name='grip')
        if not ball and row['time']<report['release']:
            # A visible ring marks the driven grip; its radial stripe follows the solved top angle.
            angle=gain*row['top_twist']
            p=np.array([[1.1*np.cos(angle),1.1*np.sin(angle),2*np.pi+.04],
                        [2.25*np.cos(angle),2.25*np.sin(angle),2*np.pi+.04]])
            plot.add_mesh(pv.lines_from_points(p),color='#df7735',line_width=9,name='grip',lighting=False)
        # Updating mesh points marks VTK data dirty; screenshot alone can reuse
        # the previous render after the grip actor has disappeared.
        plot.render()
        plot.screenshot(str(raw/f'frame-{frame:04d}.png'))
        if frame%40==0:print('surface render',case,frame,flush=True)
    plot.close()
    records={}
    for lang in languages:
        if lang=='ja':
            available={f.name for f in font_manager.fontManager.ttflist}
            font=next((f for f in ['Hiragino Sans','Noto Sans CJK JP','Noto Sans JP','IPAexGothic'] if f in available),None)
            if font is None:raise RuntimeError('Install Noto Sans CJK JP to render Japanese captions.')
        else:font='DejaVu Sans'
        plt.rcParams.update({'font.family':font,'axes.unicode_minus':False})
        L=LABELS[lang];text=L[case];name=case+'-'+lang
        folder=WORK/'render'/name;folder.mkdir(parents=True,exist_ok=True)
        fig=plt.figure(figsize=(11,7.2),dpi=100,facecolor='white')
        ax=fig.add_axes([0,.065,.65,.83]);ax.axis('off')
        im=ax.imshow(plt.imread(raw/'frame-0000.png'))
        fig.text(.04,.94,text['title'],fontsize=23,color='#17334f',weight='bold')
        phase=fig.text(.65,.72,'',fontsize=23,color='#17334f',weight='bold')
        body=fig.text(.65,.59,'',fontsize=15,color='#344760',linespacing=1.8,va='top')
        fig.text(.65,.23,text['note'],fontsize=11,color='#536174',linespacing=1.7)
        fig.text(.04,.045,L['scale'].format(gain=gain),fontsize=11,color='#536174')
        fig.text(.04,.017,L['computed'],fontsize=10,color='#536174')
        clock=fig.text(.95,.025,'',fontsize=11,ha='right',color='#536174')
        for frame,row in enumerate(report['frames']):
            stage=0 if row['time']<report['release'] else 1 if row['time']<(4 if ball else 12) else 2
            im.set_data(plt.imread(raw/f'frame-{frame:04d}.png'))
            phase.set_text(text['phases'][stage]);body.set_text(text['text'][stage])
            clock.set_text(f"t = {row['time']:.2f}")
            fig.savefig(folder/f'frame-{frame:04d}.png')
        plt.close(fig)
        records[name]=encode(name,folder,len(report['frames']))
        from PIL import Image
        poster=min(range(len(report['frames'])),key=lambda i:abs(report['frames'][i]['time']-.8*report['release']))
        Image.open(folder/f'frame-{poster:04d}.png').save(ASSETS/f'{name}.png')
        records[name]['png']=sha(ASSETS/f'{name}.png')
        records[name]['simulation_report_sha256']=sha(RESULTS/f'{case}.json')
        records[name]['renderer_sha256']=sha(__file__)
        records[name]['frames']=len(report['frames'])
        print('encoded',name,flush=True)
    return records


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('case',choices=['press-ball','twist-tube'])
    a=p.parse_args()
    records=json.loads((ASSETS/'render.json').read_text()) if (ASSETS/'render.json').exists() else {}
    records.update(render(a.case))
    (ASSETS/'render.json').write_text(json.dumps(records,indent=2)+'\n')
