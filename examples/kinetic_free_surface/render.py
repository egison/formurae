#!/usr/bin/env python3
"""Render saved fields and Formurae diagnostics without updating the model."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.patches import Rectangle
import numpy as np

import run


def render(directory, destination, title, kind):
    result=json.loads((directory/'result.json').read_text())
    assert result['source_sha256']==run.sha(run.HERE/f'{run.NAME}.fme')
    for name,expected in result['files'].items():
        assert run.sha(directory/name)==expected, ('changed output',name)
    with np.load(directory/'frames.npz') as saved:
        fields=saved['fields']; times=saved['time']
    rows=result['history']; pars=result['parameters']
    np.testing.assert_array_equal(times,[r['elapsed'] for r in rows])
    nx,ny=result['grid']; lx,ly=result['length']
    ox,oy=(1-pars['periodic'])*lx/nx,(1-pars['periodic'])*ly/ny

    def coordinates(xx,yy):
        phase=np.sin(2*np.pi*(xx-ox)/(lx-2*ox))*np.sin(2*np.pi*(yy-oy)/(ly-2*oy))
        X=(xx-ox)*lx/(lx-2*ox)+pars['warpX']*phase
        bed=pars['bedSlope']*np.maximum(X-pars['bedStart'],0) if pars['fittedBed']>.5 else 0
        Y=bed+(ly-bed)*(yy-oy)/(ly-2*oy)+pars['warpY']*phase
        return X,Y

    X,Y=coordinates(*np.meshgrid(np.linspace(0,lx,nx+1),np.linspace(0,ly,ny+1)))
    xc,yc=coordinates(*np.meshgrid((np.arange(nx)+.5)*lx/nx,(np.arange(ny)+.5)*ly/ny))
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10})
    fig=plt.figure(figsize=(12,8 if kind=='beach' else 7),dpi=100,facecolor='#f5f8fa')
    fig.text(.065,.95,title,fontsize=19,weight='bold',color='#143a50')
    fig.text(.065,.91,'Computed water fraction and velocity / Continuous D2Q9 transport',color='#536d7a')
    timestamp=fig.text(.945,.91,'',ha='right',family='monospace')
    if kind=='beach':
        gs=fig.add_gridspec(3,3,left=.075,right=.955,top=.825,bottom=.13,
                          width_ratios=[1,1,1.25],height_ratios=[1.2,1.5,1.5],
                          hspace=.8,wspace=.65)
        ax=fig.add_subplot(gs[0,:])
        zoom=fig.add_subplot(gs[1:,:2])
        left=fig.add_subplot(gs[1,2]); right=fig.add_subplot(gs[2,2])
    else:
        gs=fig.add_gridspec(2,2,left=.105,right=.955,top=.835,bottom=.13,
                          height_ratios=[3.2,1],hspace=.55,wspace=.34)
        ax=fig.add_subplot(gs[0,:])
        zoom=None
        left=fig.add_subplot(gs[1,0]); right=fig.add_subplot(gs[1,1])
    ax.set(xlim=(0,lx),ylim=(0,ly),aspect='equal',xlabel='Physical X',ylabel='Physical Y')
    water=LinearSegmentedColormap.from_list('water',['#f8fcfe','#87cadc','#09759c'])
    ground=LinearSegmentedColormap.from_list('bed',['#c9b595','#c9b595'])
    mesh=ax.pcolormesh(X,Y,fields[0,0],shading='flat',vmin=0,vmax=1,cmap=water)
    solid=ax.pcolormesh(X,Y,np.ma.masked_where(fields[0,4]<.5,fields[0,4]),
                       shading='flat',vmin=0,vmax=1,cmap=ground,zorder=4)
    if pars['fittedBed']>.5 and not pars['periodic']:
        ax.fill_between(X[1,1:-1],Y[1,1:-1],0,color='#c9b595',zorder=4)
    stride=max(1,nx//28); sampling=(slice(None,None,stride),slice(None,None,stride))
    arrows=ax.quiver(xc[sampling],yc[sampling],np.zeros_like(xc[sampling]),
                     np.zeros_like(yc[sampling]),angles='xy',scale_units='xy',
                     scale=.8,color='#144357',width=.0022,zorder=5)
    ax.quiverkey(arrows,.86,.864,.1,'Speed 0.1',labelpos='E',coordinates='figure')
    fig.text(.075,.86,'Solid: fraction 0.5     Dashed: fraction 0.01',
            fontsize=9,color='#536d7a')
    views=[dict(ax=ax,mesh=mesh,arrows=arrows,contour=None)]
    camera=None
    if zoom is not None:
        zoom.set(aspect='equal',xlabel='Physical X',ylabel='Physical Y',
                 title='Water surface — close-up')
        zoom_mesh=zoom.pcolormesh(X,Y,fields[0,0],shading='flat',vmin=0,vmax=1,cmap=water)
        zoom.pcolormesh(X,Y,np.ma.masked_where(fields[0,4]<.5,fields[0,4]),
                       shading='flat',vmin=0,vmax=1,cmap=ground,zorder=4)
        if pars['fittedBed']>.5 and not pars['periodic']:
            zoom.fill_between(X[1,1:-1],Y[1,1:-1],0,color='#c9b595',zorder=4)
        zoom_arrows=zoom.quiver(xc[sampling],yc[sampling],np.zeros_like(xc[sampling]),
                     np.zeros_like(yc[sampling]),angles='xy',scale_units='xy',
                     scale=.8,color='#144357',width=.0022,zorder=5)
        views.append(dict(ax=zoom,mesh=zoom_mesh,arrows=zoom_arrows,contour=None))
        zoom_width=min(lx,max(6*pars['level'],8*lx/nx))
        zoom_height=min(ly,max(2.2*pars['level'],8*ly/ny))
        frame=Rectangle((0,0),zoom_width,zoom_height,fill=False,
                        edgecolor='#a14c36',linewidth=1,zorder=6)
        ax.add_patch(frame)
    if kind=='beach':
        for key,label,color,style in [('wetFront','Waterline (0.5)','#09759c','-'),
                                     ('thinFront','Thin layer (0.01)','#a47b3e','--'),
                                     ('bulkFront','Two wet cells','#4e536a',':')]:
            left.plot(times,[r[key] for r in rows],label=label,color=color,ls=style)
        left.set_ylabel('Waterline X')
        right.plot(times,[r['shoreWaterMass'] for r in rows],color='#09759c')
        right.set_ylabel('Water mass beyond\ninitial shore')
    else:
        left.plot(times,[r['waveMoment'] for r in rows],color='#09759c',label='Surface cosine moment')
        left.axhline(0,color='#8295a0',lw=.7)
        left.set_ylabel('Surface cosine moment')
        if kind=='wave':
            # The initial gauge state has not been sampled yet. Subsequent
            # points are the values already evaluated and summed by FME.
            right.plot(times[1:],[r['surfaceGauge'] for r in rows[1:]],color='#09759c')
            right.axhline(0,color='#8295a0',lw=.7)
            right.set_ylabel('Centre height gauges (sum)')
        else:
            right.plot(times,[r['kineticEnergy'] for r in rows],color='#09759c')
            right.set_ylabel('Water kinetic energy')
    left.legend(loc='best',frameon=False,fontsize=8)
    markers=[]
    for panel in [left,right]:
        panel.set(xlim=(0,times[-1]),xlabel='Simulation time')
        panel.spines[['top','right']].set_visible(False)
        panel.grid(alpha=.15)
        markers.append(panel.axvline(0,color='#b85e43',lw=1.2))
    diagnostic=fig.text(.075,.045,'',fontsize=9,family='monospace',color='#536d7a')
    destination.parent.mkdir(parents=True,exist_ok=True)
    writer=FFMpegWriter(fps=20,codec='libx264',extra_args=['-crf','20','-pix_fmt','yuv420p','-movflags','+faststart'])
    with writer.saving(fig,str(destination.with_suffix('.mp4')),dpi=100):
        for index,time in enumerate(times):
            f=fields[index]; row=rows[index]
            mask=f[0][sampling]<pars['wetFraction']
            for view in views:
                view['mesh'].set_array(f[0].ravel())
                if view['contour'] is not None:
                    view['contour'].remove()
                view['contour']=view['ax'].contour(xc,yc,f[0],levels=[.01,.5],
                    colors=['#559fba','#063b54'],linestyles=['--','-'],
                    linewidths=[.7,1.3],zorder=3)
                view['arrows'].set_UVC(np.ma.masked_where(mask,f[2][sampling]),
                                      np.ma.masked_where(mask,f[3][sampling]))
            if zoom is not None:
                # Drawing-only camera placement. No diagnostic or model state
                # is derived from this smoothed view position.
                visible=(f[0]>=.5)&(f[4]<.5)
                if np.any(visible):
                    top=np.max(np.where(visible,yc,-np.inf))
                    near_top=visible&(yc>=top-1e-12)
                    target=np.array([np.mean(xc[near_top]),top])
                    camera=target if camera is None else .8*camera+.2*target
                elif camera is None:
                    camera=np.array([lx/2,pars['level']])
                x0=np.clip(camera[0]-zoom_width/2,0,lx-zoom_width)
                y0=np.clip(camera[1]-.8*zoom_height,0,ly-zoom_height)
                zoom.set(xlim=(x0,x0+zoom_width),ylim=(y0,y0+zoom_height))
                frame.set_xy((x0,y0))
            timestamp.set_text(f't = {time:7.3f}')
            for marker in markers:
                marker.set_xdata([time,time])
            diagnostic.set_text(f'{nx} x {ny} cells  |  mass = {row["waterMass"]:.10f}  |  raw fraction range = [{row["lowest"]:.3g}, {row["highest"]:.12g}]')
            writer.grab_frame()
            if index==len(times)//3:
                fig.savefig(destination.with_suffix('.png'),dpi=100)
    plt.close(fig)
    metadata=dict(result_sha256=run.sha(directory/'result.json'),source_sha256=result['source_sha256'],
                  renderer_sha256=run.sha(Path(__file__)),frames_sha256=result['files']['frames.npz'],
                  grid=result['grid'],parameters=pars,frame_count=len(times),fps=20,
                  kind=kind,title=title,pixels=[1200,800 if kind=='beach' else 700],
                  simulation_time=[float(times[0]),float(times[-1])],
                  media={ext:run.sha(destination.with_suffix('.'+ext)) for ext in ['png','mp4']})
    destination.with_suffix('.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(destination.with_suffix('.mp4'))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    parser.add_argument('destination',type=Path)
    parser.add_argument('--title',default='A wave approaching the beach')
    parser.add_argument('--kind',choices=['wave','dam','beach'],default='beach')
    args=parser.parse_args()
    render(args.directory,args.destination,args.title,args.kind)
