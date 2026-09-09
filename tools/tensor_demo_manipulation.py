"""Moving grips, then release, for generated three-dimensional tensor elasticity.

The C kernel computes strain, constitutive response and stress divergence.
The driver imposes velocity on a grip and zero traction on a free face.
Stress constraints are orthogonal in the elastic compliance inner product;
this preserves the homogeneous semidiscrete energy identity at release.
"""
import argparse
import time

import numpy as np

from tensor_demo_common import WORK, write_report
from tensor_demo_elastic import Elastic


def ramp(t, duration):
    """Unit displacement and its first two derivatives; smooth at both ends."""
    x=np.clip(t/duration,0,1)
    return (10*x**3-15*x**4+6*x**5,
            30*x*x*(1-x)**2/duration,
            60*x*(1-x)*(1-2*x)/duration**2)


class Manipulation(Elastic):
    def __init__(self,case,radial=16,angular=48):
        self.case=case
        super().__init__('sphere' if case=='press-ball' else 'cylinder',radial,angular,0.,
                         kernel_name=case.replace('-','_'),bounded_axial=case=='twist-tube')
        self.release=1.5 if self.sphere else 4.
        self.amplitude=.035 if self.sphere else .065
        self.radial_face=np.zeros((len(self.basis),*self.shape),dtype=bool)
        self.radial_face[:,[0,-1]]=True
        self.upper_face=np.zeros_like(self.radial_face)
        self.grip=np.zeros_like(self.radial_face)
        if self.sphere:
            # Local pressure from a small rounded grip centred on the +x side.
            c=self.basis[:,0,0]
            self.profile=np.maximum(0,(c-np.cos(.65))/(1-np.cos(.65)))**2
            self.grip[:,-1]=c[:,-1]>np.cos(.65)
        else:
            self.upper_face[...,-1]=True
            self.grip=self.upper_face.copy()

    def initial(self):
        v=np.zeros((len(self.basis),3,*self.shape))
        return v,np.zeros((len(v),6,*self.shape)),v.copy()

    def project_stress(self,s,t):
        s=s.copy()
        r=self.radial_face.copy()
        if self.sphere and t<self.release:r&=~self.grip
        z=self.upper_face if not self.sphere and t>=self.release else np.zeros_like(r)
        # Remove C[:,I] inv(C[I,I]) sigma[I] for the constrained normal stresses.
        # Solve both constraints together at edges where two free faces meet.
        normals=s[:,[0,3,5]].copy()
        for mask,indices in [(r&~z,[0]),(z&~r,[2]),(r&z,[0,2])]:
            if not mask.any():continue
            values=np.moveaxis(normals,1,0)[:,mask]
            correction=self.stiffness[:,indices]@np.linalg.solve(
                self.stiffness[np.ix_(indices,indices)],values[indices])
            normal_first=np.moveaxis(normals,1,0)
            normal_first[:,mask]=values-correction
        s[:,[0,3,5]]=normals
        # Tangential surface traction also vanishes on the pressed cap.
        s[:,1][self.radial_face]=0
        s[:,2][self.radial_face|z]=0
        s[:,4][z]=0
        return s

    def project_velocity(self,v,t,derivative=False):
        v=v.copy()
        if not self.sphere:v[...,0]=0
        if t<self.release:
            value=ramp(t,self.release)[2 if derivative else 1]*self.amplitude
            if self.sphere:v[:,0][self.grip]=-value*self.profile[self.grip]
            else:
                v[...,-1]=0
                v[:,1,...,-1]=value*self.R[...,-1]
        return v

    def constrain(self,v,s,u,t):
        if self.sphere:
            v=self.sphere.exchange(v)
            s=self.sphere.exchange(s,tensor=True)
            u=self.sphere.exchange(u)
        # Reapply the prescribed displacement after Cartesian panel exchange,
        # just as for velocity: interpolation must not move a boundary grip.
        u=u.copy()
        if not self.sphere:u[...,0]=0
        if t<=self.release:
            value=ramp(t,self.release)[0]*self.amplitude
            if self.sphere:u[:,0][self.grip]=-value*self.profile[self.grip]
            else:
                u[...,-1]=0
                u[:,1,...,-1]=value*self.R[...,-1]
        return self.project_velocity(v,t),self.project_stress(s,t),u

    def derivative(self,state,t):
        v,s,u=self.constrain(*state,t)
        av,bs=super().rhs(v,s,exchange=False)
        return self.project_velocity(av,t,True),self.project_stress(bs,t),v

    def advance(self,state,t,dt):
        if abs(t-self.release)<1e-10:t=self.release
        finish=t+dt
        if abs(finish-self.release)<1e-10:finish=self.release
        # Integrate the loading interval using its left limit, then release
        # once. Sampling the free branch in k4 would mix two boundary problems.
        stage_end=np.nextafter(finish,-np.inf) if t<self.release and finish==self.release else finish
        state=self.constrain(*state,t)
        k1=self.derivative(state,t)
        k2=self.derivative(tuple(s+dt*k/2 for s,k in zip(state,k1)),t+dt/2)
        k3=self.derivative(tuple(s+dt*k/2 for s,k in zip(state,k2)),t+dt/2)
        k4=self.derivative(tuple(s+dt*k for s,k in zip(state,k3)),stage_end)
        new=tuple(s+dt*(a+2*b+2*c+d)/6 for s,a,b,c,d in zip(state,k1,k2,k3,k4))
        return self.constrain(*new,finish)


def validate():
    rows=[]
    # Exact torsional standing wave of a fixed/free hollow tube: omega = k sqrt(mu/rho).
    for n in [4,8,16]:
        m=Manipulation('twist-tube',n,6*n);m.release=-1
        k=.25;a=.02;phase=.7
        v,s,u=m.initial()
        u[:,1]=a*m.R*np.sin(k*m.P)*np.cos(phase)
        v[:,1]=-a*k*m.R*np.sin(k*m.P)*np.sin(phase)
        s[:,4]=a*k*m.R*np.cos(k*m.P)*np.cos(phase)
        av,bs,_=m.derivative((v,s,u),0)
        ae=np.zeros_like(v);ae[:,1]=-k*k*u[:,1]
        be=np.zeros_like(s);be[:,4]=-a*k*k*m.R*np.cos(k*m.P)*np.sin(phase)
        # Include the free top; exclude the fixed bottom acceleration.
        error=max(float(abs((av-ae)[...,1:]).max()),float(abs(bs-be).max()))
        rows.append(dict(radial=n,angular=6*n,error=error,kernel=m.kernel.record))
        print('torsion exact-mode check',n,error,flush=True)
    orders=[float(np.log2(rows[i]['error']/rows[i+1]['error'])) for i in range(2)]
    assert min(orders)>1.7,orders
    # Releasing a grip removes boundary constraints orthogonally, without adding energy.
    rng=np.random.default_rng(721)
    for case in ['press-ball','twist-tube']:
        m=Manipulation(case,4,24)
        v,s,u=m.initial();s=rng.normal(size=s.shape)
        free=m.project_stress(s,m.release)
        assert m.energy(v,free)<=m.energy(v,s)*(1+1e-12)
        assert abs(m.project_stress(free,m.release)-free).max()<1e-12
    return dict(torsion_exact_mode=rows,orders=orders,release_projection='energy non-increasing and idempotent')


def simulate(case,radial=16,angular=48,end=None,frames=None):
    m=Manipulation(case,radial,angular)
    end=end or (9. if m.sphere else 22.)
    frames=frames or (181 if m.sphere else 221)
    steps_per_frame=int(np.ceil(end/(frames-1)/(.06/radial)))
    dt=end/((frames-1)*steps_per_frame)
    # All output times and the release are exact multiples of dt.
    assert abs(m.release/dt-round(m.release/dt))<1e-8
    folder=WORK/case;folder.mkdir(parents=True,exist_ok=True)
    state=m.initial();records=[];start=time.monotonic();release_energy=None
    for frame in range(frames):
        if frame:
            for j in range(steps_per_frame):
                t=((frame-1)*steps_per_frame+j)*dt
                # Avoid selecting the loading branch from a roundoff error at release.
                if abs(t-m.release)<1e-10:t=m.release
                state=m.advance(state,t,dt)
        t=frame*steps_per_frame*dt
        if abs(t-m.release)<1e-10:t=m.release
        v,s,u=state
        assert all(np.isfinite(a).all() for a in state)
        energy=m.energy(v,s)
        if t>=m.release and release_energy is None:release_energy=energy
        drift=energy/release_energy-1 if release_energy else None
        constraint=float(abs(m.project_stress(s,t)-s).max())
        if drift is not None:assert abs(drift)<.06,(case,t,drift)
        assert constraint<1e-9
        if m.sphere:
            probes=m.sphere.interpolate_global(u[:,:,-1],np.array([[1.,-1.],[0.,0.],[0.,0.]]))
            observation=dict(pressed_displacement=float(probes[0,0]),opposite_displacement=float(-probes[0,1]))
        else:
            observation=dict(top_twist=float(np.mean(u[:,1,...,-1]/m.R[...,-1])),
                             bottom_displacement=float(abs(u[...,0]).max()))
        row=dict(time=t,energy=energy,relative_free_energy=drift,constraint_error=constraint,
                 max_displacement=float(np.linalg.norm(u,axis=1).max()),**observation)
        records.append(row)
        np.savez_compressed(folder/f'frame-{frame:04d}.npz',u=u.astype(np.float32),v=v.astype(np.float32),time=t)
        if frame%20==0:print(case,frame,row,'elapsed',round(time.monotonic()-start,1),flush=True)
    report=dict(case=case,radial=radial,angular=angular,dt=dt,release=m.release,
                imposed_displacement=m.amplitude,display_magnification=8 if m.sphere else 6,
                kernel=m.kernel.record,frames=records)
    write_report(case,report)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('case',choices=['press-ball','twist-tube','validate'])
    p.add_argument('--radial',type=int,default=16);p.add_argument('--angular',type=int,default=48)
    a=p.parse_args()
    if a.case=='validate':write_report('manipulation-validation',validate())
    else:simulate(a.case,a.radial,a.angular)
