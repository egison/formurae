#!/usr/bin/env python3
"""Plot saved solver fields and reductions. Never computes or advances a model."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.colors import Normalize
from matplotlib.patches import Circle
from run import ROOT, SPECS

OPTICS = ['zero','turn22','turn45','turn45-wide']
LABELS = {
'battery_cooling': ['Isotropic / side cooling','Anisotropic / side cooling',
                    'Anisotropic / end cooling','Anisotropic / side + end cooling'],
'composite_ultrasound': ['Healthy / fibers at 0 degrees','Soft inclusion / fibers at 0 degrees',
                         'Healthy / fibers at 45 degrees','Soft inclusion / fibers at 45 degrees'],
'optics_design': ['No rotation','22.5 degree rotation','45 degree rotation','45 degrees / thicker layer'],
}
TITLES = {'battery_cooling':'Cylindrical cell: conduction model and cooling surfaces',
          'composite_ultrasound':'Composite ultrasound: material direction and a soft inclusion',
          'optics_design':'Field rotator: angle and layer thickness'}

def load(directory, step, optics=False):
    result=None
    for path in sorted((directory/'data').glob(f'frame-{step:07d}-rank-*.bin')):
        with path.open('rb') as f:
            header=np.fromfile(f,dtype='=i4',count=3 if optics else 4)
            nx,ny,stamp=header[:3]; nf=2 if optics else header[3]
            if stamp!=step: raise ValueError('stamp mismatch')
            record=np.dtype([('i','=i4'),('j','=i4'),('u','=f8',(nf,))])
            data=np.fromfile(f,dtype=record)
        if result is None: result=np.full((nx,ny,nf),np.nan)
        result[data['i'],data['j'],:]=data['u']
    if result is None or not np.isfinite(result).all(): raise ValueError('incomplete frame '+str(directory))
    return result

def rows(directory):
    with (directory/'stats.csv').open() as f:
        return [{k:float(v) for k,v in r.items()} for r in csv.DictReader(f)]

def render(name, video=True):
    cases = OPTICS if name=='optics_design' else list(SPECS[name]['cases'])
    dirs=[ROOT/'.build/application_demos'/name/c for c in cases]
    metadata=[json.loads((d/'metadata.json').read_text()) for d in dirs]
    tables=[rows(d) for d in dirs]
    stamps=sorted(int(p.name.split('-')[1]) for p in (dirs[0]/'data').glob('frame-*-rank-000.bin'))
    out=ROOT/'examples/application_demos/results'/name; out.mkdir(parents=True,exist_ok=True)
    for case,d in zip(cases,dirs):
        shutil.copyfile(d/'stats.csv',out/(case+'.csv'))
        source_name='transformation_optics' if name=='optics_design' else name
        for ext in ['fme','yaml']:
            shutil.copyfile(d/(source_name+'.'+ext),out/(case+'.'+ext))
    (out/'runs.json').write_text(json.dumps(dict(zip(cases,metadata)),indent=2)+'\n')
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'figure.facecolor':'#fafbfc','savefig.facecolor':'#fafbfc'})
    battery=name=='battery_cooling'; optics=name=='optics_design'
    norm=Normalize(25,25+max(t[-1]['maximum'] for t in tables)) if battery else Normalize(-1,1) if optics else Normalize(0,0.7)
    cmap='inferno' if battery else 'RdBu_r' if optics else 'magma'
    fig,axes=plt.subplots(2,2,figsize=(12,6.5 if battery else 9),layout='constrained')
    heading=fig.suptitle(TITLES[name],fontsize=16,fontweight='bold')
    images=[]
    for ax,case,d,meta,label in zip(axes.flat,cases,dirs,metadata,LABELS[name]):
        u=load(d,stamps[0],optics)[:,:,0]
        if battery:
            image=ax.imshow(25+u,origin='lower',extent=(0,65,2,9),aspect='auto',cmap=cmap,norm=norm)
            ax.set(xlabel='Axial position z (mm)',ylabel='Radius r (mm)')
            if float(meta['parameters']['side']): ax.plot([0,65],[9,9],c='#32c7f2',lw=4)
            if float(meta['parameters']['ends']):
                for z in [0,65]: ax.plot([z,z],[2,9],c='#32c7f2',lw=4)
        else:
            image=ax.imshow(u.T,origin='lower',extent=(0,16,0,12),cmap=cmap,norm=norm,interpolation='bilinear')
            if optics:
                for r in ['R1','R2']:
                    ax.add_patch(Circle((8+4/meta['grid'][0],6+3/meta['grid'][1]),float(meta['parameters'][r]),fill=False,color='#262626',lw=.9,ls='--'))
            else:
                ax.plot([4],[6],'+',c='white',ms=8,label='source')
                ax.plot([9],[6],'v',c='#30d9ed',ms=6,label='receiver')
                if float(meta['parameters']['damage']): ax.add_patch(Circle((7,6),.4,fill=False,color='white',lw=.9,ls='--'))
                a=float(meta['parameters']['angle'])
                ax.plot([1,1+1.2*np.cos(a)],[1,1+1.2*np.sin(a)],c='#30d9ed',lw=2)
            ax.set(xlabel='x',ylabel='y')
        ax.set_title(label,fontsize=11)
        images.append(image)
    fig.colorbar(images[0],ax=axes,orientation='horizontal',fraction=.035,pad=.015,
                 label='Temperature (degrees C); cyan marks cooling surfaces' if battery else 'Electric field Ez' if optics else 'Speed; + source, triangle receiver, dashed circle soft region')
    time_by_stamp={int(row['step']):row.get('time',row['step']*16/metadata[0]['grid'][0]*.1) for row in tables[0]}
    def draw(stamp):
        heading.set_text(TITLES[name]+'\n'+f"t = {time_by_stamp[stamp]:.2f}"+(' s' if battery else ' (dimensionless)'))
        for image,d in zip(images,dirs):
            u=load(d,stamp,optics)[:,:,0]
            image.set_data(25+u if battery else u.T)
    desired=400 if battery else 8 if optics else 1.8
    selected=min(stamps,key=lambda s:abs(time_by_stamp[s]-desired))
    draw(selected); fig.savefig(out/'comparison.png',dpi=130)
    if video:
        matplotlib.rcParams['animation.ffmpeg_path']=shutil.which('ffmpeg') or 'ffmpeg'
        writer=FFMpegWriter(fps=15,codec='libx264',extra_args=['-crf','23','-pix_fmt','yuv420p','-movflags','+faststart'])
        with writer.saving(fig,out/'comparison.mp4',dpi=100):
            for i,stamp in enumerate(stamps):
                draw(stamp); writer.grab_frame()
                if i%25==0: print(name,'frame',i+1,'/',len(stamps),flush=True)
    plt.close(fig)
    fig,axes=plt.subplots(1,2,figsize=(12,4),layout='constrained')
    for i,(case,table,label) in enumerate(zip(cases,tables,LABELS[name])):
        times=[r.get('time',r['step']*16/metadata[i]['grid'][0]*.1) for r in table]
        if battery:
            axes[0].plot(times,[25+r['maximum'] for r in table],label=label)
            axes[1].plot(times,[r['maximum']-r['minimum'] for r in table],label=label)
        elif optics:
            axes[0].plot(times,[r['scatter']/max(r['incident'],1e-300) for r in table],label=label)
            axes[1].plot(times[1:],[r['energy']/table[1]['energy'] for r in table[1:]],label=label)
        else:
            ax=axes[i//2]; ax.plot(times,[r['signal'] for r in table],label='Healthy' if i%2==0 else 'Soft inclusion')
    if battery:
        axes[0].set(ylabel='Maximum temperature (degrees C)',xlabel='Time (s)')
        axes[1].set(ylabel='Maximum - minimum temperature (K)',xlabel='Time (s)')
    elif optics:
        axes[0].set(ylabel='Scattered / incident field energy',xlabel='Time',yscale='log',ylim=(1e-8,1))
        axes[1].set(ylabel='Electromagnetic energy / first recorded energy',xlabel='Time')
    else:
        for ax,angle in zip(axes,[0,45]): ax.set(title=f'Fibers at {angle} degrees',xlabel='Time (dimensionless)',ylabel='Receiver signal (velocity x)')
    for ax in axes: ax.legend(fontsize=8,frameon=False); ax.grid(alpha=.2)
    fig.savefig(out/'measurements.png',dpi=140); plt.close(fig)
    print(out,flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--only',choices=list(LABELS)); p.add_argument('--no-video',action='store_true')
    a=p.parse_args()
    for name in [a.only] if a.only else LABELS: render(name,not a.no_video)
