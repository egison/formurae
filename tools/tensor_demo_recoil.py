"""Explain elastic recoil using tracers advected by the saved Couette velocity.

This is a new view of the existing generated-C simulation. Particle motion is
integrated from its saved velocity fields; the path and reversal are not drawn
or prescribed by the renderer. The entire clip runs at half physical speed.
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.collections import LineCollection
from matplotlib.patches import Circle,FancyArrowPatch
import numpy as np

from tensor_demo_common import ROOT,WORK,RESULTS,sha
from tensor_demo_render import encode,ASSETS


class SavedVelocity:
    def __init__(self):
        self.report=json.loads((RESULTS/'couette.json').read_text())
        self.times=np.array([f['time'] for f in self.report['frames']])
        self.values=[]
        for i in range(len(self.times)):
            with np.load(WORK/f'couette/frame-{i:04d}.npz') as f:
                assert abs(float(f['time'])-self.times[i])<1e-10
                self.values.append(f['v'].astype(float))
        self.values=np.array(self.values)
        self.dr=1/self.report['radial'];self.dtheta=2*np.pi/self.report['angular']
        self.drive=np.array([f['wall_speed'] for f in self.report['frames']])

    def sample(self,t,positions):
        r,theta=positions
        assert ((r>1)&(r<2)).all()
        n=int(np.clip(np.searchsorted(self.times,t,side='right')-1,0,len(self.times)-2))
        time_weight=(t-self.times[n])/(self.times[n+1]-self.times[n])
        velocity=(1-time_weight)*self.values[n]+time_weight*self.values[n+1]
        ir=(r-1)/self.dr;it=np.mod(theta,2*np.pi)/self.dtheta
        i,j=np.floor(ir).astype(int),np.floor(it).astype(int)
        a,b=ir-i,it-j;j1=(j+1)%velocity.shape[-1]
        out=((1-a)*(1-b)*velocity[:,i,j]+a*(1-b)*velocity[:,i+1,j]
             +(1-a)*b*velocity[:,i,j1]+a*b*velocity[:,i+1,j1])
        # dr/dt = v_r; dtheta/dt = physical v_theta / r.
        out[1]/=r
        return out

    def advance(self,positions,t,dt):
        k1=self.sample(t,positions)
        k2=self.sample(t+dt/2,positions+dt*k1/2)
        k3=self.sample(t+dt/2,positions+dt*k2/2)
        k4=self.sample(t+dt,positions+dt*k3)
        return positions+dt*(k1+2*k2+2*k3+k4)/6


def cartesian(positions):
    r,theta=positions
    return np.array([r*np.cos(theta),r*np.sin(theta)]).T


def trajectories(field,times,substeps):
    radii,angles=np.meshgrid([1.22,1.50,1.78],np.arange(16)*2*np.pi/16,indexing='ij')
    positions=np.array([radii.ravel(),angles.ravel()])
    states=[positions.copy()]
    for t0,t1 in zip(times,times[1:]):
        dt=(t1-t0)/substeps
        for j in range(substeps):positions=field.advance(positions,t0+j*dt,dt)
        states.append(positions.copy())
    return np.array(states)


TEXT={
 'ja':dict(title='かき混ぜるのをやめると，液体が少し戻る',wall='外側の壁は固定',
           cylinder='回す\n内筒',phases=['1  回す','2  止める','3  まだ進む','4  少し逆回転'],
           explanation=['内筒につられて，\n液体の目印も回ります．','内筒をゆっくり\n停止させます．',
                        '内筒は停止しました．\n液体はまだ同じ向きへ．','内筒は止まったまま．\n液体だけが少し戻ります．'],
           note='液体が蓄えた弾性の力で\n動きが戻る様子です．',tracers='青い点：液体と一緒に動く目印\n橙の点：注目する一つの目印',
           progress='回す → 止める → 液体が戻る',stopped='内筒は停止中',speed='全区間を同じ 1/2 倍速で再生'),
 'en':dict(title='Stop stirring. The liquid briefly turns back.',wall='Fixed outer wall',
           cylinder='Driven\ncylinder',phases=['1  Turn','2  Stop','3  Still forward','4  Turns back'],
           explanation=['The cylinder carries\nthe liquid markers around.','The inner cylinder\nslows to a stop.',
                        'The cylinder has stopped.\nThe liquid still moves forward.','The cylinder stays still.\nThe liquid briefly turns back.'],
           note='Stored elastic stress\npulls the liquid back.',tracers='Blue dots: markers carried by the liquid\nOrange dot: one marker to follow',
           progress='Turn → Stop → Liquid turns back',stopped='Cylinder stopped',speed='Entire clip at the same half-speed')}


def render(lang,field,times,states,drive_angle):
    if lang=='ja':
        candidates=['Hiragino Sans','Noto Sans CJK JP','Noto Sans JP','IPAexGothic']
        available={f.name for f in font_manager.fontManager.ttflist}
        matches=[f for f in candidates if f in available]
        if not matches:
            raise RuntimeError('Japanese rendering needs a Japanese font, e.g. Noto Sans CJK JP.')
        font=matches[0]
    else:font='DejaVu Sans'
    plt.rcParams.update({'font.family':font,'axes.unicode_minus':False})
    L=TEXT[lang];name='couette-recoil-'+lang
    folder=WORK/'render'/name;folder.mkdir(parents=True,exist_ok=True)
    fig=plt.figure(figsize=(11,6.8),dpi=100,facecolor='white')
    ax=fig.add_axes([.03,.075,.60,.79]);ax.set_aspect('equal')
    ax.set(xlim=(-2.3,2.3),ylim=(-2.3,2.3));ax.axis('off')
    ax.add_patch(Circle((0,0),2,facecolor='#e8f4fa',edgecolor='#485971',lw=4))
    ax.add_patch(Circle((0,0),1,facecolor='#d8e0e8',edgecolor='#62738a',lw=2))
    ax.text(0,2.14,L['wall'],ha='center',fontsize=12,color='#485971')
    ax.text(0,0,L['cylinder'],ha='center',va='center',fontsize=16,color='#344760')
    marker,=ax.plot([],[],color='#df7735',lw=9,solid_capstyle='round')
    dots=ax.scatter([],[],s=45,color='#267cb7',zorder=4)
    focus=ax.scatter([],[],s=110,color='#ea762b',edgecolor='white',linewidth=1.2,zorder=6)
    trail=LineCollection([],colors='#75b4d5',linewidths=1.3,alpha=.55,zorder=3);ax.add_collection(trail)
    highlight_trail=LineCollection([],colors='#ea762b',linewidths=3,alpha=.7,zorder=5);ax.add_collection(highlight_trail)
    fig.text(.045,.94,L['title'],fontsize=22,color='#17334f',weight='bold')
    phase=fig.text(.65,.70,'',fontsize=24,weight='bold',color='#17334f')
    detail=fig.text(.65,.58,'',fontsize=15,color='#344760',linespacing=1.7,va='top')
    stopped=fig.text(.65,.76,'',fontsize=12,color='#b35924')
    meaning=fig.text(.65,.40,'',fontsize=14,color='#b35924',linespacing=1.6,va='top')
    fig.text(.65,.20,L['tracers'],fontsize=11,color='#536174',linespacing=1.8)
    fig.text(.045,.028,L['speed'],fontsize=11,color='#536174')
    clock=fig.text(.95,.028,'',ha='right',fontsize=11,color='#536174')
    arrows=[];selected=16+2
    points=np.array([cartesian(s) for s in states])
    for frame,(t,state) in enumerate(zip(times,states)):
        center_speed=field.sample(t,state)[1,16:32].mean()
        drive=np.interp(t,field.times,field.drive)
        stage=0 if t<12 else 1 if drive>1e-9 else 2 if center_speed>=0 else 3
        phase.set_text(L['phases'][stage]);detail.set_text(L['explanation'][stage])
        stopped.set_text(L['stopped'] if drive<=1e-9 else '')
        meaning.set_text(L['note'] if stage==3 else '')
        clock.set_text(f't = {t:.2f}')
        angle=drive_angle[frame]
        marker.set_data(np.array([.70,.93])*np.cos(angle),np.array([.70,.93])*np.sin(angle))
        dots.set_offsets(points[frame]);focus.set_offsets(points[frame,selected:selected+1])
        history=points[max(0,frame-18):frame+1]
        trail.set_segments(np.moveaxis(history,1,0))
        highlight_trail.set_segments([history[:,selected]])
        for arrow in arrows:arrow.remove()
        arrows=[]
        # These small arrows show direction only. Particle displacements are
        # unscaled and use the integrated physical velocities above.
        if abs(center_speed)>.002:
            sign=np.sign(center_speed)
            for theta in [0,np.pi/2,np.pi,3*np.pi/2]:
                theta+=.18
                start=1.50*np.array([np.cos(theta),np.sin(theta)])
                end=1.50*np.array([np.cos(theta+sign*.15),np.sin(theta+sign*.15)])
                arrow=FancyArrowPatch(start,end,arrowstyle='-|>',mutation_scale=16,
                                      color='#527f9a',lw=1.4,zorder=2)
                ax.add_patch(arrow);arrows.append(arrow)
        fig.savefig(folder/f'frame-{frame:04d}.png')
    plt.close(fig)
    result=encode(name,folder,len(times))
    # Poster shows the part the introductory question is about.
    from PIL import Image
    index=int(np.argmin(abs(times-16)))
    Image.open(folder/f'frame-{index:04d}.png').save(ASSETS/f'{name}.png')
    result['png']=sha(ASSETS/f'{name}.png')
    return name,result


def main():
    field=SavedVelocity();times=np.linspace(11,17.4,193)
    assert field.times[0]<=times[0] and field.times[-1]>=times[-1]
    states=trajectories(field,times,4);refined=trajectories(field,times,8)
    error=float(abs(states-refined).max());assert error<1e-6,error
    speeds=np.array([field.sample(t,s)[1,16:32].mean() for t,s in zip(times,states)])
    assert speeds[times<12].min()>0
    assert speeds[(times>=15)&(times<=17)].max()<0
    # Integrate the prescribed wall speed, with the same saved time samples.
    wall=np.interp(times,field.times,field.drive)
    angle=np.concatenate([[0],np.cumsum(.5*(wall[1:]+wall[:-1])*np.diff(times))])
    assert np.ptp(angle[times>=14])<1e-12
    records=json.loads((ASSETS/'render.json').read_text())
    for lang in ['ja','en']:
        name,result=render(lang,field,times,states,angle);records[name]=result
        print('rendered',name,flush=True)
    (ASSETS/'render.json').write_text(json.dumps(records,indent=2)+'\n')
    summary=dict(source_report_sha256=sha(RESULTS/'couette.json'),renderer_sha256=sha(__file__),
                 start=float(times[0]),end=float(times[-1]),frames=len(times),playback_speed=.5,
                 max_trajectory_time_refinement_error=error,
                 angular_velocity_at_t16=float(speeds[np.argmin(abs(times-16))]),
                 stopped_cylinder_angle_variation=float(np.ptp(angle[times>=14])))
    (RESULTS/'couette-recoil.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(summary,flush=True)


if __name__=='__main__':main()
