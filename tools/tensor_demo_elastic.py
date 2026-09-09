"""Traction-free, radially reinforced 3-D cylinders and complete hollow spheres."""
import argparse
import time

import numpy as np

from tensor_demo_common import Kernel, WORK, derivative, write_report
from tensor_demo_sphere import YinYang, basis, pack, unpack

PAIRS=[(i,j) for i in range(3) for j in range(i,3)]


class Elastic:
    def __init__(self, geometry='sphere', radial=16, angular=48, alpha=6.,
                 kernel_name=None, bounded_axial=False):
        self.geometry,self.alpha=geometry,alpha
        self.dr=1/radial
        r=1+np.arange(radial+1)*self.dr
        self.sphere=YinYang(angular) if geometry=='sphere' else None
        if self.sphere:
            s=self.sphere
            self.shape=(radial+1,*s.shape)
            self.spacing=[self.dr,s.h,s.h]
            periodic=[False,False,False]
            self.basis=np.broadcast_to(s.basis[:,:,:,None],(2,3,3,*self.shape))
            self.xyz=r[None,None,:,None,None]*np.broadcast_to(s.xyz[:,:,None],(2,3,*self.shape))
            R,T,P=np.broadcast_arrays(r[:,None,None],s.theta[None],s.phi[None])
            self.scale=np.array([np.ones_like(R),R,R*np.sin(T)])
            self.weight=r[None,:,None,None]**2*s.area_weights[:,None]*self.dr
        else:
            self.shape=(radial+1,angular,angular//2+int(bounded_axial))
            self.spacing=[self.dr,2*np.pi/angular,2*np.pi/(angular//2)]
            periodic=[False,True,not bounded_axial]
            R,T,P=np.meshgrid(r,np.arange(angular)*self.spacing[1],
                             np.arange(self.shape[2])*self.spacing[2],indexing='ij')
            z=np.zeros_like(R);o=np.ones_like(R)
            self.basis=np.array([[[np.cos(T),np.sin(T),z],[-np.sin(T),np.cos(T),z],[z,z,o]]])
            self.xyz=np.array([[R*np.cos(T),R*np.sin(T),P]])
            self.scale=np.array([o,R,o])
            self.weight=(R*np.prod(self.spacing))[None]
        self.R,self.T,self.P=R,T,P
        self.weight=self.weight.copy();self.weight[:,[0,-1]]*=.5
        if bounded_axial:self.weight[...,[0,-1]]*=.5
        self.sigma_scale=np.array([self.scale[i]*self.scale[j] for i,j in PAIRS])
        self.kernel=Kernel(kernel_name or 'anisotropic_'+geometry,self.shape,self.spacing,periodic,
                           {'double :: alpha = 6.0':f'double :: alpha = {alpha}'})
        self.vi=self.kernel.indices('v_');self.si=self.kernel.indices('sigma_')
        self.ai=self.kernel.indices('acceleration_');self.bi=self.kernel.indices('rate_')
        self.stiffness=2*np.ones((3,3))+2*np.eye(3)+np.diag([alpha,0,0])
        self.compliance=np.linalg.inv(self.stiffness)

    def initial(self):
        radial_profile=np.exp(-((self.R-1.5)/.28)**2)
        if self.sphere:
            n=self.basis[:,0]
            H=np.array([[1.,.15,.1],[.15,-1.,.2],[.1,.2,0.]])
            hn=np.einsum('ij,pj...->pi...',H,n)
            f=np.einsum('pi...,pi...->p...',n,hn)
            tangent=hn-f[:,None]*n
            twist=np.cross(n,hn,axisa=1,axisb=1,axisc=1)
            cart=.04*radial_profile[None,None]*(f[:,None]*n+.5*tangent+.3*twist)
            v=np.einsum('pij...,pj...->pi...',self.basis,cart)
        else:
            v=.04*radial_profile[None,None]*np.array([[np.cos(2*self.T)*np.cos(self.P),
                 .4*np.sin(2*self.T)*np.cos(self.P),.3*np.cos(self.T)*np.sin(self.P)]])
        return v,np.zeros((len(v),6,*self.shape)),np.zeros_like(v)

    def exchange(self,v,s,u=None):
        if self.sphere:
            v=self.sphere.exchange(v)
            s=self.sphere.exchange(s,tensor=True)
            # Interpolating Cartesian stress between neighbouring normals
            # perturbs traction. Reapply the same compliance-orthogonal
            # constraint on the two physical surfaces after panel exchange.
            radial=s[:,0,[0,-1]].copy()
            s[:,3,[0,-1]]-=2/(4+self.alpha)*radial
            s[:,5,[0,-1]]-=2/(4+self.alpha)*radial
            s[:,0,[0,-1]]=0;s[:,1,[0,-1]]=0;s[:,2,[0,-1]]=0
            if u is not None:
                u=self.sphere.exchange(u)
        return v,s,u

    def rhs(self,v,s,exchange=True):
        if exchange:
            v,s,_=self.exchange(v,s)
        av=np.empty_like(v);bs=np.empty_like(s)
        for p in range(len(v)):
            state=self.kernel.empty()
            state[self.vi]=v[p]/self.scale
            state[self.si]=s[p]/self.sigma_scale
            out=self.kernel.apply(state)
            av[p]=out[self.ai]*self.scale
            bs[p]=out[self.bi]*self.sigma_scale
        return av,bs

    def energy(self,v,s):
        normal=s[:,[0,3,5]]
        density=.5*np.sum(v*v,axis=1)+.5*np.einsum('pi...,ij,pj...->p...',normal,self.compliance,normal)
        density+=.5*np.sum(s[:,[1,2,4]]**2,axis=1)
        return float(np.sum(density*self.weight))

    def reference(self,v,s):
        scale=self.scale;g=scale**2;J=np.prod(scale,axis=0)
        dg=np.zeros((3,3,*self.shape))
        dg[0,1]=2*self.R
        if self.sphere:
            dg[0,2]=2*self.R*np.sin(self.T)**2
            dg[1,2]=2*self.R**2*np.sin(self.T)*np.cos(self.T)
        d=lambda a,j: derivative(a,j,self.spacing[j],j==0)
        acceleration=[];rate=[]
        for vp,sp in zip(v,s):
            V=vp/scale;S=unpack(sp/self.sigma_scale,3)
            e=np.zeros_like(S)
            for i in range(3):
                for j in range(3):
                    e[i,j]=.5*(g[i]*d(V[i],j)+g[j]*d(V[j],i))
                    if i==j:
                        e[i,j]+=.5*sum(dg[k,i]*V[k] for k in range(3))
                    e[i,j]/=scale[i]*scale[j]
            e[0,0,[0,-1]]=-2/(4+self.alpha)*(e[1,1,[0,-1]]+e[2,2,[0,-1]])
            e[0,1,[0,-1]]=e[1,0,[0,-1]]=0
            e[0,2,[0,-1]]=e[2,0,[0,-1]]=0
            stress=2*e
            tr=np.einsum('ii...->...',e)
            for i in range(3):stress[i,i]+=2*tr
            stress[0,0]+=self.alpha*e[0,0]
            f=np.empty_like(V)
            for i in range(3):
                f[i]=sum(d(J*g[i]*S[i,j],j) for j in range(3))/(J*g[i])
                f[i]-=sum(dg[i,j]*S[j,j] for j in range(3))/(2*g[i])
            acceleration.append(f*scale);rate.append(pack(stress))
        return np.array(acceleration),np.array(rate)

    def step(self,v,s,u,dt):
        v,s,u=self.exchange(v,s,u)
        a1,b1=self.rhs(v,s,False)
        a2,b2=self.rhs(v+.5*dt*a1,s+.5*dt*b1)
        a3,b3=self.rhs(v+.5*dt*a2,s+.5*dt*b2)
        a4,b4=self.rhs(v+dt*a3,s+dt*b3)
        un=u+dt*v+(dt*dt/6)*(a1+a2+a3)
        vn=v+dt/6*(a1+2*a2+2*a3+a4)
        sn=s+dt/6*(b1+2*b2+2*b3+b4)
        return self.exchange(vn,sn,un)


def validate():
    report=[]
    for geom in ['cylinder','sphere']:
        rows=[]
        for n in [8,16,32]:
            m=Elastic(geom,n,3*n if geom=='sphere' else 4*n)
            A=np.array([[.2,.3,-.1],[-.2,.1,.2],[.1,-.2,-.3]])
            S=np.array([[.2,.1,-.05],[.1,-.1,.04],[-.05,.04,.3]])
            cart=np.einsum('ij,pj...->pi...',A,m.xyz)
            v=np.einsum('pij...,pj...->pi...',m.basis,cart)
            stress=np.einsum('pki...,ij,plj...->pkl...',m.basis,S,m.basis)
            s=np.array([pack(p) for p in stress])
            actual=m.rhs(v,s,False);ref=m.reference(v,s)
            region=(m.R>=1.25-1e-12)&(m.R<=1.75+1e-12)
            if m.sphere:
                region&=(m.T>=np.pi/3-1e-12)&(m.T<=2*np.pi/3+1e-12)&(abs(m.P)<=np.pi/2+1e-12)
            else:
                # An affine Cartesian field is not periodic in z. Its local
                # consistency test excludes the axial wrap, in physical units.
                region&=(m.P>=np.pi/2-1e-12)&(m.P<=3*np.pi/2+1e-12)
            reference_error=max(float(np.max(abs((a-b)[...,region]))) for a,b in zip(actual,ref))
            assert reference_error<1e-10,reference_error
            E=(A+A.T)/2
            strain=np.einsum('pki...,ij,plj...->pkl...',m.basis,E,m.basis)
            exact=2*strain
            for i in range(3):exact[:,i,i]+=2*np.trace(E)
            exact[:,0,0]+=m.alpha*strain[:,0,0]
            exact=np.array([pack(p) for p in exact])
            error=max(float(np.max(abs(actual[0][...,region]))),
                      float(np.max(abs((actual[1]-exact)[...,region]))))
            rows.append(dict(radial_intervals=n,reference_error=reference_error,affine_error=error))
            print('elastic validation',geom,rows[-1],flush=True)
        orders=[float(np.log2(rows[i]['affine_error']/rows[i+1]['affine_error'])) for i in range(2)]
        assert min(orders)>1.65,orders
        report.append(dict(geometry=geom,runs=rows,orders=orders))
    return {'models':report}


def simulate(geometry='sphere',radial=16,angular=48,end=5.,frames=101):
    models=[Elastic(geometry,radial,angular,alpha) for alpha in [0.,6.]]
    states=[m.initial() for m in models]
    e0=[m.energy(v,s) for m,(v,s,u) in zip(models,states)]
    frame_steps=max(1,round(end/(frames-1)/(.08/radial)))
    dt=end/((frames-1)*frame_steps)
    output=WORK/f'elastic-{geometry}';output.mkdir(parents=True,exist_ok=True)
    records=[];start=time.monotonic()
    for frame in range(frames):
        if frame:
            for _ in range(frame_steps):
                states=[m.step(*state,dt) for m,state in zip(models,states)]
        entries=[]
        for m,(v,s,u),initial_energy in zip(models,states,e0):
            assert all(np.isfinite(a).all() for a in [v,s,u])
            traction=float(np.max(abs(s[:,[0,1,2]][:,:,[0,-1]])))
            drift=m.energy(v,s)/initial_energy-1
            assert traction<1e-9,traction
            assert abs(drift)<(.005 if geometry=='sphere' else .00001),drift
            entries.append(dict(alpha=m.alpha,relative_energy=drift,traction_error=traction))
        records.append(dict(time=frame*frame_steps*dt,models=entries))
        np.savez_compressed(output/f'frame-{frame:04d}.npz',
                            u=np.array([s[2] for s in states],dtype=np.float32),
                            v=np.array([s[0] for s in states],dtype=np.float32),time=records[-1]['time'])
        if frame%10==0:
            print('elastic',geometry,frame,'energy',[round(e['relative_energy'],6) for e in entries],
                  'elapsed',round(time.monotonic()-start,1),flush=True)
    report=dict(geometry=geometry,radial=radial,angular=angular,dt=dt,
                steps=(frames-1)*frame_steps,kernels=[m.kernel.record for m in models],frames=records)
    write_report('elastic-'+geometry,report)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--validate',action='store_true')
    p.add_argument('--geometry',choices=['cylinder','sphere'],default='sphere')
    p.add_argument('--radial',type=int,default=16);p.add_argument('--angular',type=int,default=48)
    p.add_argument('--end',type=float,default=5)
    a=p.parse_args()
    if a.validate:write_report('elastic-validation',validate())
    else:simulate(a.geometry,a.radial,a.angular,a.end)
