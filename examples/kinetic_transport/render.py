#!/usr/bin/env python3
"""Draw saved fraction, density and velocity fields; no simulation updates."""
import argparse
import hashlib
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.colors import LinearSegmentedColormap
import numpy as np

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BUILD=ROOT/'.build/kinetic-transport'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def draw(report_path,output):
    report=json.loads(report_path.read_text())
    assert report['source_sha256']==sha(HERE/'kinetic_transport.fme')
    candidates=[r for r in report['runs'] if r['case']=='coupled' and r['method']==1 and r['time_scale']==1]
    n=max(r['grid'] for r in candidates)
    records=[next(r for r in candidates if r['grid']==n and r['chart']==c) for c in ['cartesian','mapped']]
    data=[]
    for record in records:
        path=(BUILD/record['csv']).with_name('frames.npz')
        assert sha(path)==record['frames_sha256']
        with np.load(path) as saved:
            data.append({k:saved[k] for k in saved.files})
    np.testing.assert_array_equal(data[0]['time'],data[1]['time'])
    times=data[0]['time']
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
    fig=plt.figure(figsize=(12,7.6),dpi=100,facecolor='#f6f9fb')
    fig.text(.065,.949,'Transport driven by the D2Q9 fluid',size=20,weight='bold',color='#1e4257')
    fig.text(.065,.9,'A material label in a fully filled fluid / No free-surface pressure boundary yet',size=11,color='#526f7f')
    clock=fig.text(.95,.852,'',ha='right',family='monospace',size=12)
    gs=fig.add_gridspec(2,3,height_ratios=[3.6,1],left=.09,right=.95,top=.8,bottom=.12,hspace=.8,wspace=.25)
    cmap=LinearSegmentedColormap.from_list('labelled_water',['#eff6fa','#90cada','#08739a'])
    artists=[]
    stride=max(1,n//10)
    sampling=(slice(stride//2,None,stride),slice(stride//2,None,stride))
    for i in range(3):
        record,saved=(records[i],data[i]) if i<2 else (records[1],data[1])
        warp_x,warp_y=record['arguments'][2:4]
        xx,yy=np.meshgrid(np.linspace(0,1,n+1),np.linspace(0,1,n+1))
        deformation=np.sin(2*np.pi*xx)*np.sin(2*np.pi*yy)
        X,Y=xx+warp_x*deformation,yy+warp_y*deformation
        xc=(X[:-1,:-1]+X[:-1,1:]+X[1:,:-1]+X[1:,1:])/4
        yc=(Y[:-1,:-1]+Y[:-1,1:]+Y[1:,:-1]+Y[1:,1:])/4
        ax=fig.add_subplot(gs[0,i])
        ax.set(xlim=(0,1),ylim=(0,1),aspect='equal',xlabel='Physical X',ylabel='Physical Y' if i==0 else '')
        ax.set_title(['Label / Cartesian','Label / curved grid','Density / curved grid'][i],fontsize=11,pad=10)
        fields=saved['fields'][0]
        mesh=ax.pcolormesh(X,Y,fields[0 if i<2 else 1],cmap=cmap if i<2 else 'RdBu_r',vmin=0 if i<2 else .85,vmax=1 if i<2 else 1.15,shading='flat')
        ax.contour(xc,yc,fields[0],levels=[.5],colors=['#788c9c'],linestyles='--',linewidths=1)
        contour=ax.contour(xc,yc,fields[0],levels=[.5],colors=['#0a486e'],linewidths=1.4)
        arrows=None
        if i<2:
            arrows=ax.quiver(xc[sampling],yc[sampling],fields[2][sampling],fields[3][sampling],color='#183f54',angles='xy',scale_units='xy',scale=1.3,width=.0035,alpha=.72)
            if i==0:
                ax.quiverkey(arrows,.22,-.27,.1,'Speed 0.1',labelpos='E',coordinates='axes',fontproperties={'size':9})
        else:
            cax=ax.inset_axes([.05,-.27,.9,.04])
            fig.colorbar(mesh,cax=cax,orientation='horizontal',ticks=[.85,1,1.15])
        artists.append([mesh,contour,arrows,ax,xc,yc])
    ax=fig.add_subplot(gs[1,:])
    for record,color in zip(records,['#08739a','#d3872f']):
        ax.plot([r['elapsed'] for r in record['history']],[r['mixing'] for r in record['history']],label='Cartesian' if record['chart']=='cartesian' else 'Curved grid',color=color,lw=1.8,ls='-' if record['chart']=='cartesian' else '--')
    ax.set(xlim=(0,times[-1]),xlabel='Simulation time',ylabel='Intermediate fractions')
    ax.legend(frameon=False,ncol=2,fontsize=9,loc='lower left',bbox_to_anchor=(0,1.01),borderaxespad=0)
    cursor=ax.axvline(0,color='#596f7e',lw=1)
    fig.text(.065,.035,f'FORMURAE / {n} × {n} cells / Blue: labelled fraction; solid: 0.5; dashed: initial boundary',size=10,color='#617888')
    output.mkdir(parents=True,exist_ok=True)
    movie=output/'coupled.mp4'
    writer=FFMpegWriter(fps=15,codec='libx264',extra_args=['-crf','20','-pix_fmt','yuv420p','-movflags','+faststart'])
    with writer.saving(fig,str(movie),dpi=100):
        for frame,time in enumerate(times):
            clock.set_text(f't = {time:6.3f}')
            for i,artist in enumerate(artists):
                fields=data[min(i,1)]['fields'][frame]
                mesh,contour,arrows,axes,xc,yc=artist
                mesh.set_array(fields[0 if i<2 else 1])
                contour.remove()
                artist[1]=axes.contour(xc,yc,fields[0],levels=[.5],colors=['#0a486e'],linewidths=1.4)
                if arrows is not None:
                    arrows.set_UVC(fields[2][sampling],fields[3][sampling])
            cursor.set_xdata([time,time])
            if frame==len(times)//2:
                fig.savefig(output/'coupled.png',dpi=100)
            writer.grab_frame(facecolor=fig.get_facecolor())
    plt.close(fig)
    metadata=dict(source_sha256=report['source_sha256'],verification_sha256=sha(report_path),renderer_sha256=sha(Path(__file__)),grid=n,
        frames=len(times),fps=15,duration=float(times[-1]),media={ext:sha(output/f'coupled.{ext}') for ext in ['mp4','png']})
    (output/'rendering.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(movie,flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe',action='store_true')
    args=parser.parse_args()
    draw(BUILD/'probe.json' if args.probe else HERE/'results/verification.json',BUILD/'preview' if args.probe else HERE/'results')
