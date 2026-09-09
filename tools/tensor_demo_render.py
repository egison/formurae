"""Render actual simulation snapshots; fixed cameras and fixed colour scales."""
import argparse
import json
from pathlib import Path
import subprocess

import imageio_ffmpeg
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image
import pyvista as pv

from tensor_demo_common import ROOT,WORK,RESULTS,sha
from tensor_demo_sphere import YinYang

ASSETS=ROOT/'gallery/tensor'


def encode(name,folder,count):
    ASSETS.mkdir(parents=True,exist_ok=True)
    movie=ASSETS/f'{name}.mp4'
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(),'-y','-loglevel','error',
                    '-framerate','15','-i',str(folder/'frame-%04d.png'),
                    '-frames:v',str(count),'-c:v','libx264','-crf','20','-preset','medium',
                    '-pix_fmt','yuv420p','-movflags','+faststart',str(movie)],check=True)
    # One shared palette for the entire GIF. No frame-wise colour normalization.
    thumbs=[]
    for i in np.linspace(0,count-1,min(24,count)).astype(int):
        im=Image.open(folder/f'frame-{i:04d}.png').convert('RGB')
        im.thumbnail((250,155));thumbs.append(im)
    atlas=Image.new('RGB',(250*6,155*((len(thumbs)+5)//6)),'white')
    for k,im in enumerate(thumbs):atlas.paste(im,(250*(k%6),155*(k//6)))
    palette=atlas.quantize(colors=256,method=Image.Quantize.MEDIANCUT)
    frames=[Image.open(folder/f'frame-{i:04d}.png').convert('RGB').quantize(
        palette=palette,dither=Image.Dither.NONE) for i in range(count)]
    frames[0].save(ASSETS/f'{name}.gif',save_all=True,append_images=frames[1:],
                   duration=70,loop=0,optimize=False,disposal=1)
    poster=round(.65*(count-1)) if name=='couette' else count//3
    Image.open(folder/f'frame-{poster:04d}.png').save(ASSETS/f'{name}.png')
    return {ext:sha(ASSETS/f'{name}.{ext}') for ext in ['mp4','gif','png']}


def surface_grid(geometry,report,azimuth=np.pi,azimuth_points=49):
    nr=report['radial']+1
    rr=np.linspace(1,2,nr)
    if geometry=='sphere':
        t=np.linspace(1e-6,np.pi-1e-6,49)
        p=np.linspace(0,azimuth,azimuth_points)
        R,T,P=np.meshgrid(rr,t,p,indexing='ij')
        xyz=np.array([R*np.sin(T)*np.cos(P),R*np.sin(T)*np.sin(P),R*np.cos(T)])
        points=xyz[:,0].reshape(3,-1)
        yy=YinYang(report['angular'])
        def sample(data):
            out=np.empty_like(xyz)
            for r in range(nr):
                out[:,r]=yy.interpolate_global(data[:,:,r],points).reshape(3,len(t),len(p))
            return out
    else:
        angular=report['angular'];nz=angular//2
        R,T,Z=np.meshgrid(rr,np.linspace(0,np.pi,angular//2+1),
                         np.linspace(0,2*np.pi,nz+1),indexing='ij')
        xyz=np.array([R*np.cos(T),R*np.sin(T),Z])
        def sample(data):
            physical=data[0,:,:,:angular//2+1]
            physical=np.concatenate([physical,physical[...,:1]],axis=-1)
            a,b,c=physical
            return np.array([np.cos(T)*a-np.sin(T)*b,np.sin(T)*a+np.cos(T)*b,c])
    grid=pv.StructuredGrid(*xyz)
    surface=grid.extract_surface(algorithm='dataset_surface')
    ids=surface['vtkOriginalPointIds']
    return surface,ids,sample


def render_elastic(geometry):
    name='elastic-'+geometry
    report=json.loads((RESULTS/f'{name}.json').read_text())
    count=len(report['frames']);source=WORK/name
    folder=WORK/'render'/name;folder.mkdir(parents=True,exist_ok=True)
    surface,ids,sample=surface_grid(geometry,report)
    meshes=[surface.copy(),surface.copy()]
    base=surface.points.copy()
    plot=pv.Plotter(off_screen=True,shape=(1,2),window_size=(1100,640),border=False)
    plot.set_background('white')
    for k,title in enumerate(['Isotropic material','Radially reinforced material']):
        plot.subplot(0,k)
        mesh=meshes[k];mesh['speed']=np.zeros(mesh.n_points)
        plot.add_mesh(mesh,scalars='speed',cmap='viridis',clim=(0,.06),lighting=True,ambient=.65,diffuse=.35,specular=0,
                      scalar_bar_args=dict(title=' '*(k+1),vertical=False,width=.65,height=.07,
                                           position_x=.17,position_y=.018,title_font_size=1,label_font_size=9))
        plot.add_text(title,position='upper_left',font_size=12,color='#172c44')
        z0=np.pi if geometry=='cylinder' else 0
        plot.camera_position=[(4,-7,4+z0),(0,.25,z0),(0,0,1)]
        plot.enable_parallel_projection()
        plot.camera.parallel_scale=4.9 if geometry=='cylinder' else 3.1
        plot.camera.SetWindowCenter(0,-.13)
        plot.add_text('Colour: speed; displacement x8',position=(15,72),font_size=8,color='#536174')
    for frame,record in enumerate(report['frames']):
        data=np.load(source/f'frame-{frame:04d}.npz')
        assert abs(float(data['time'])-record['time'])<1e-10
        for k in range(2):
            displacement=sample(data['u'][k]);velocity=sample(data['v'][k])
            u=np.array([a.ravel(order='F') for a in displacement]).T[ids]
            speed=np.linalg.norm(velocity,axis=0).ravel(order='F')[ids]
            meshes[k].points=base+8*u
            meshes[k]['speed']=speed
            plot.subplot(0,k)
            plot.add_text(f"t = {record['time']:.2f}",position=(15,98),font_size=10,color='#172c44',name='clock')
        plot.screenshot(str(folder/f'frame-{frame:04d}.png'))
        if frame%20==0:print('render',name,frame,flush=True)
    plot.close()
    return encode(name,folder,count)


def fibonacci_points(n):
    z=1-2*(np.arange(n)+.5)/n
    p=np.arange(n)*np.pi*(3-np.sqrt(5))
    return np.array([np.sqrt(1-z*z)*np.cos(p),np.sqrt(1-z*z)*np.sin(p),z])


def tangent_tensor(yy,q,points):
    tensor=yy.interpolate_global(q,points,tensor=True,tangent=True)
    projector=np.eye(3)[:,:,None]-np.einsum('ic,jc->ijc',points,points)
    tensor=np.einsum('ikc,klc,ljc->ijc',projector,tensor,projector)
    tensor-=.5*projector*np.einsum('iic->c',tensor)
    return np.moveaxis(tensor,-1,0)


def render_nematic():
    report=json.loads((RESULTS/'nematic.json').read_text())
    yy=YinYang(report['resolution'])
    count=len(report['frames']);source=WORK/'nematic'
    folder=WORK/'render/nematic';folder.mkdir(parents=True,exist_ok=True)
    sphere=pv.Sphere(radius=1,theta_resolution=96,phi_resolution=64)
    points=sphere.points.T.copy();points/=np.linalg.norm(points,axis=0)
    glyph_points=fibonacci_points(550)
    meshes=[sphere.copy(),sphere.copy()]
    plot=pv.Plotter(off_screen=True,shape=(1,2),window_size=(1100,640),border=False)
    for k in range(2):
        plot.subplot(0,k);plot.set_background('white')
        meshes[k]['order']=np.zeros(sphere.n_points)
        plot.add_mesh(meshes[k],scalars='order',cmap='magma',clim=(0,1),lighting=False,
                      scalar_bar_args=dict(title=' '*(k+1),vertical=False,width=.65,height=.07,
                                           position_x=.17,position_y=.018,title_font_size=1,label_font_size=9))
        plot.add_text('Liquid crystal: '+('front' if k==0 else 'back'),
                      position='upper_left',font_size=12,color='#172c44')
        camera=np.array([3.,-5.,2.])*(1 if k==0 else -1)
        plot.camera_position=[camera,(0,0,0),(0,0,1)]
        plot.enable_parallel_projection();plot.camera.parallel_scale=1.7
        plot.camera.SetWindowCenter(0,-.13)
        plot.add_text('Colour: alignment; lines: orientation; cyan: defects',position=(15,72),font_size=8,color='#536174')
    for frame,record in enumerate(report['frames']):
        data=np.load(source/f'frame-{frame:04d}.npz');q=data['q']
        tensor=tangent_tensor(yy,q,points)
        order=np.sqrt(2*np.sum(tensor*tensor,axis=(1,2)))
        glyphs=tangent_tensor(yy,q,glyph_points)
        eigen,directions=np.linalg.eigh(glyphs)
        director=directions[:,:,-1]
        centers=glyph_points.T*1.012
        amplitude=np.sqrt(np.maximum(0,2*eigen[:,-1]))
        half=.033*np.minimum(amplitude,1)[:,None]*director
        endpoints=np.stack([centers-half,centers+half],axis=1).reshape(-1,3)
        lines=pv.PolyData(endpoints)
        lines.verts=np.empty(0,dtype=np.int64)
        lines.lines=np.array([[2,2*i,2*i+1] for i in range(len(centers))]).ravel()
        defects=np.array([d['position'] for d in record['defects']])*1.024
        for k in range(2):
            plot.subplot(0,k);meshes[k]['order']=order
            plot.add_mesh(lines,color='#213447',line_width=1.3,name='orientation',lighting=False)
            if len(defects):
                plot.add_mesh(pv.PolyData(defects),color='#00c8dd',point_size=13,
                              render_points_as_spheres=True,name='defects',lighting=False)
            plot.add_text(f"t = {record['time']:.1f}   |   {len(defects)} defects",
                          position=(15,98),font_size=10,color='#172c44',name='clock')
        plot.screenshot(str(folder/f'frame-{frame:04d}.png'))
        if frame%20==0:print('render nematic',frame,flush=True)
    plot.close()
    return encode('nematic',folder,count)


def render_couette():
    report=json.loads((RESULTS/'couette.json').read_text())
    count=len(report['frames']);source=WORK/'couette'
    folder=WORK/'render/couette';folder.mkdir(parents=True,exist_ok=True)
    nr,nt=report['radial']+1,report['angular']
    R,T=np.meshgrid(np.linspace(1,2,nr),np.linspace(0,2*np.pi,nt+1),indexing='ij')
    X,Y=R*np.cos(T),R*np.sin(T)
    times=np.array([f['time'] for f in report['frames']])
    energies=np.array([f['energy'] for f in report['frames']])
    fig=plt.figure(figsize=(11,6.4),dpi=100,facecolor='white')
    grid=fig.add_gridspec(2,2,width_ratios=[1.2,1],left=.045,right=.96,bottom=.12,top=.88,wspace=.2,hspace=.55)
    ax=fig.add_subplot(grid[:,0]);flow=fig.add_subplot(grid[0,1]);trace=fig.add_subplot(grid[1,1])
    for frame,record in enumerate(report['frames']):
        data=np.load(source/f'frame-{frame:04d}.npz');C=data['conformation'];v=data['v']
        stress=(.16/1.5)*np.sqrt((C[0]-1)**2+2*C[1]**2+(C[2]-1)**2)
        stress=np.concatenate([stress,stress[:,:1]],axis=1)
        ax.clear()
        mesh=ax.pcolormesh(X,Y,stress,shading='gouraud',cmap='viridis',vmin=0,vmax=4)
        ax.add_patch(plt.Circle((0,0),1,color='#dce3ea'));ax.add_patch(plt.Circle((0,0),2,fill=False,color='#536174',lw=.8))
        ax.text(0,.08,'Rotating\ninner cylinder',ha='center',va='center',fontsize=11,color='#172c44')
        ax.text(0,-.40,f"speed = {record['wall_speed']:.2f}",ha='center',fontsize=10,color='#536174')
        theta=T[:,:-1];r=R[:,:-1]
        vx=v[0]*np.cos(theta)-v[1]*np.sin(theta)
        vy=v[0]*np.sin(theta)+v[1]*np.cos(theta)
        sl=(slice(3,-3,6),slice(None,None,8))
        ax.quiver((r*np.cos(theta))[sl],(r*np.sin(theta))[sl],vx[sl],vy[sl],
                  color='white',scale=9,width=.004,headwidth=3)
        ax.set_aspect('equal');ax.set_xlim(-2.15,2.15);ax.set_ylim(-2.15,2.15);ax.axis('off')
        ax.set_title('Polymer stress and fluid velocity',fontsize=13,pad=12)
        if frame==0:
            cb=fig.colorbar(mesh,ax=ax,orientation='horizontal',fraction=.045,pad=.025)
            cb.set_label('Polymer stress magnitude (fixed scale)',fontsize=10)
        flow.clear();flow.plot(np.linspace(1,2,nr),v[1].mean(axis=1),color='#176fa7',lw=2)
        flow.set(xlim=(1,2),ylim=(-.15,1.1),xlabel='Radius',ylabel='Mean azimuthal velocity')
        flow.grid(alpha=.2);flow.set_title('Velocity profile',fontsize=12)
        trace.clear();trace.plot(times[:frame+1],energies[:frame+1],color='#bf5b25',lw=2)
        trace.axvspan(12,14,color='#dce3ea',alpha=.65)
        trace.set(xlim=(0,times[-1]),ylim=(0,energies.max()*1.08),xlabel='Time',ylabel='Kinetic + polymer energy')
        trace.grid(alpha=.2);trace.set_title('Drive slows at t = 12; stops at t = 14',fontsize=11)
        fig.suptitle(f"Viscoelastic Taylor-Couette flow     t = {record['time']:.2f}",
                     fontsize=17,x=.045,ha='left',color='#172c44')
        fig.savefig(folder/f'frame-{frame:04d}.png')
        if frame%20==0:print('render couette',frame,flush=True)
    plt.close(fig)
    return encode('couette',folder,count)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('model',choices=['all','elastic-cylinder','elastic-sphere','nematic','couette'],nargs='?',default='all')
    args=parser.parse_args()
    records=json.loads((ASSETS/'render.json').read_text()) if (ASSETS/'render.json').exists() else {}
    for name,fn in [('elastic-cylinder',lambda:render_elastic('cylinder')),
                    ('elastic-sphere',lambda:render_elastic('sphere')),
                    ('nematic',render_nematic),('couette',render_couette)]:
        if args.model in ['all',name]:records[name]=fn()
    (ASSETS/'render.json').write_text(json.dumps(records,indent=2)+'\n')


if __name__=='__main__':main()
