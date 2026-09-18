#!/usr/bin/env python3
"""Render saved volume fractions; no physical time evolution is implemented here."""
import argparse
import hashlib
import json
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.colors import LinearSegmentedColormap
import numpy as np

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BUILD=ROOT/".build/surface-transport"


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def draw(report_path,output):
    report=json.loads(report_path.read_text())
    assert report['source_sha256']==sha(HERE/'surface_transport.fme')
    output.mkdir(parents=True,exist_ok=True)
    metadata=dict(source_sha256=report['source_sha256'],verification_sha256=sha(report_path),renderer_sha256=sha(Path(__file__)),movies={})
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
    cmap=LinearSegmentedColormap.from_list('water_fraction',['#eff6fa','#90cada','#08739a'])
    for case in ['wave','vortex']:
        candidates=[r for r in report['runs'] if r['case']==case and r['time_scale']==(r['grid']/128 if r['grid']>=256 else 1)]
        control_grids=[r['grid'] for r in candidates if r['method']==0]
        n=max(control_grids) if case=='vortex' and control_grids else max(r['grid'] for r in candidates)
        chosen=[next(r for r in candidates if r['grid']==n and r['chart']==chart and r['method']==1) for chart in ['cartesian','mapped']]
        controls=[r for r in candidates if r['grid']==n and r['chart']=='mapped' and r['method']==0]
        chosen+=controls
        data=[]
        for record in chosen:
            path=(BUILD/record['csv']).with_name('frames.npz')
            assert sha(path)==record['frames_sha256']
            with np.load(path) as saved:
                data.append({k:saved[k] for k in saved.files})
        for saved in data[1:]:
            np.testing.assert_array_equal(saved['time'],data[0]['time'])
        times=data[0]['time']
        fig=plt.figure(figsize=(12,7.2),dpi=100,facecolor='#f6f9fb')
        title='A wave-shaped interface carried by a uniform flow' if case=='wave' else 'A water region stretched by a reversing vortex'
        fig.text(.065,.951,title,size=18,weight='bold',color='#1e4257')
        fig.text(.065,.902,'Prescribed flow / Interface transport only / No gravity or pressure feedback',size=11,color='#526f7f')
        clock=fig.text(.94,.853,'',ha='right',family='monospace',size=12)
        gs=fig.add_gridspec(2,len(chosen),height_ratios=[3.3,1],left=.09,right=.955,top=.80,bottom=.105,hspace=.48,wspace=.24)
        artists=[]
        for i,(record,saved) in enumerate(zip(chosen,data)):
            q=saved['fraction']
            warp_x,warp_y=record['arguments'][2:4]
            xx,yy=np.meshgrid(np.linspace(0,1,n+1),np.linspace(0,1,n+1))
            deformation=np.sin(2*np.pi*xx)*np.sin(2*np.pi*yy)
            X,Y=xx+warp_x*deformation,yy+warp_y*deformation
            xc=(X[:-1,:-1]+X[:-1,1:]+X[1:,:-1]+X[1:,1:])/4
            yc=(Y[:-1,:-1]+Y[:-1,1:]+Y[1:,:-1]+Y[1:,1:])/4
            ax=fig.add_subplot(gs[0,i])
            ax.set(xlim=(0,1),ylim=(0,1),aspect='equal',xlabel='Physical X',ylabel='Physical Y' if i==0 else '')
            label=('Cartesian' if record['chart']=='cartesian' else 'Curved')+(' / MUSCL' if record['method']==1 else ' / first-order upwind')
            ax.set_title(label,fontsize=11,pad=9)
            mesh=ax.pcolormesh(X,Y,q[0],cmap=cmap,vmin=0,vmax=1,shading='flat',rasterized=True)
            ax.contour(xc,yc,q[0],levels=[.5],colors=['#8595a2'],linestyles='--',linewidths=1)
            contour=ax.contour(xc,yc,q[0],levels=[.5],colors=['#0a486e'],linewidths=1.2)
            artists.append([mesh,contour,ax,xc,yc])
        ax=fig.add_subplot(gs[1,:])
        colors=['#08739a','#d3872f','#798995']
        for record,color in zip(chosen,colors):
            label=('Cartesian' if record['chart']=='cartesian' else 'Curved')+(' / MUSCL' if record['method']==1 else ' / upwind')
            ax.plot([row['elapsed'] for row in record['history']],[row['mixing'] for row in record['history']],label=label,color=color,lw=1.8,ls='--' if record['chart']=='mapped' and record['method']==1 else '-')
        ax.set(xlim=(0,times[-1]),xlabel='Simulation time',ylabel='Intermediate fractions')
        ax.legend(frameon=False,fontsize=9,ncol=len(chosen),loc='lower left',bbox_to_anchor=(0,1.03),borderaxespad=0)
        cursor=ax.axvline(0,color='#596f7e',lw=1)
        fig.text(.065,.03,f'FORMURAE / {n} × {n} cells / Blue: fraction 0 to 1; solid line: 0.5; dashed line: initial interface',size=10,color='#617888')
        fps=15 if case=='wave' else 30
        movie=output/f'{case}.mp4'
        writer=FFMpegWriter(fps=fps,codec='libx264',extra_args=['-crf','20','-pix_fmt','yuv420p','-movflags','+faststart'])
        with writer.saving(fig,str(movie),dpi=100):
            for frame,time in enumerate(times):
                clock.set_text(f't = {time:6.3f}')
                for saved,artist in zip(data,artists):
                    mesh,contour,axes,xc,yc=artist
                    q=saved['fraction'][frame]
                    mesh.set_array(q)
                    contour.remove()
                    artist[1]=axes.contour(xc,yc,q,levels=[.5],colors=['#0a486e'],linewidths=1.2)
                cursor.set_xdata([time,time])
                if frame==len(times)//2:
                    fig.savefig(output/f'{case}.png',dpi=100)
                writer.grab_frame(facecolor=fig.get_facecolor())
        plt.close(fig)
        metadata['movies'][case]=dict(grid=n,frames=len(times),fps=fps,duration=float(times[-1]),media={s:sha(output/f'{case}.{s}') for s in ['mp4','png']})
        print(movie,flush=True)
    (output/'rendering.json').write_text(json.dumps(metadata,indent=2)+'\n')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe',action='store_true')
    args=p.parse_args()
    draw(BUILD/'probe.json' if args.probe else HERE/'results/verification.json',BUILD/'preview' if args.probe else HERE/'results')
