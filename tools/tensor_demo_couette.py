"""Two-dimensional incompressible Oldroyd-B flow between rotating cylinders.

Formurae generates momentum, curl of momentum, and conformation-tensor RHSs.
The driver solves a scalar Poisson equation to reconstruct the nonaxisymmetric
velocity. Its azimuthal mean is evolved separately: fixing both streamfunction
wall values for that mean would incorrectly remove the annular circulation.
"""
import argparse
import time

import numpy as np
from scipy.linalg.lapack import zgttrf,zgttrs

from tensor_demo_common import Kernel,WORK,derivative,write_report


class Couette:
    def __init__(self,radial=48,angular=128):
        self.nr,self.nt=radial+1,angular
        self.dr,self.dtheta=1/radial,2*np.pi/angular
        self.r=1+np.arange(self.nr)*self.dr
        self.R,self.T=np.meshgrid(self.r,np.arange(angular)*self.dtheta,indexing='ij')
        self.kernel=Kernel('oldroyd_couette',[self.nr+6,self.nt],[self.dr,self.dtheta],[False,True])
        self.vi=self.kernel.indices('v_');self.ci=self.kernel.indices('C_')
        self.ai=self.kernel.indices('acceleration_');self.bi=self.kernel.indices('rate_')
        self.wi=self.kernel.fields.index('rotationRate')
        self.ti=self.kernel.indices('transport_')
        self.gi=self.kernel.indices('velocityGradient_')
        self.oi=self.kernel.fields.index('omega')
        self.ui=self.kernel.indices('transportSpeed_')
        self.scale=np.array([np.ones_like(self.R),self.R])
        self.cs=np.array([np.ones_like(self.R),self.R,self.R**2])
        self.factors=[]
        interior=self.r[1:-1]
        for k in range(self.nt//2+1):
            a=-1/self.dr**2+1/(2*self.dr*interior)
            c=-1/self.dr**2-1/(2*self.dr*interior)
            d=2/self.dr**2+4*np.sin(np.pi*k/self.nt)**2/(self.dtheta**2*interior**2)
            factors=zgttrf(a[1:].astype(complex),d.astype(complex),c[:-1].astype(complex))
            assert factors[-1]==0
            self.factors.append(factors[:-1])

    def poisson(self,omega):
        transformed=np.fft.rfft(omega[1:-1],axis=1)
        solution=np.zeros((self.nr,self.nt//2+1),complex)
        for k in range(1,self.nt//2+1):
            out,info=zgttrs(*self.factors[k],transformed[:,k,None])
            assert info==0
            solution[1:-1,k]=out[:,0]
        return np.fft.irfft(solution,n=self.nt,axis=1)

    @staticmethod
    def wall_speed(t):
        # Smooth deceleration exposes stress memory after the drive stops.
        if t<=12:return 1.
        if t>=14:return 0.
        return .5*(1+np.cos(np.pi*(t-12)/2))

    def velocity(self,state,t):
        omega,mean,C=state
        psi=self.poisson(omega)
        mean=mean.copy();mean[0]=self.wall_speed(t);mean[-1]=0
        vr=derivative(psi,1,self.dtheta)/self.R
        vt=-derivative(psi,0,self.dr,True)+mean[:,None]
        vr[[0,-1]]=0;vt[0]=self.wall_speed(t);vt[-1]=0
        return np.array([vr,vt]),psi

    def initial(self,perturb=True):
        mean=(4/self.r-self.r)/3
        gamma=-8/(3*self.R**2)
        relaxation=1.5
        C=np.array([np.ones_like(self.R),relaxation*gamma,1+2*(relaxation*gamma)**2])
        if perturb:
            # A smooth initial orientation perturbation preserves positive
            # definiteness exactly and then evolves without prescribed motion.
            angle=.08*np.sin(np.pi*(self.R-1))**2*(np.cos(3*self.T)+.4*np.sin(5*self.T))
            co,si=np.cos(angle),np.sin(angle)
            xx,xy,yy=C.copy()
            C=np.array([co*co*xx-2*co*si*xy+si*si*yy,
                        co*si*(xx-yy)+(co*co-si*si)*xy,
                        si*si*xx+2*co*si*xy+co*co*yy])
        psi=.004*(self.R-1)**2*(2-self.R)**2*(np.cos(3*self.T)+.5*np.sin(5*self.T)) if perturb else np.zeros_like(self.R)
        omega=-(self.d2(psi,0,self.dr)+derivative(psi,0,self.dr,True)/self.R
                +self.d2(psi,1,self.dtheta)/self.R**2)
        omega[[0,-1]]=0
        return omega,mean,C

    @staticmethod
    def d2(a,axis,h):
        return (np.roll(a,-1,axis)+np.roll(a,1,axis)-2*a)/h**2

    def evaluate(self,v,C,split=False,omega=None):
        # Three ghost rings supply nested tensor derivatives. Velocity is
        # reflected about each no-slip wall; conformation is extended in the
        # physical orthonormal frame before converting coordinate components.
        vp=np.pad(v,((0,0),(3,3),(0,0)),mode='edge')
        for j in range(1,4):
            vp[:,3-j]=2*v[:,0]-v[:,j]
            vp[:,-4+j]=2*v[:,-1]-v[:,-1-j]
        cp=np.pad(C,((0,0),(3,3),(0,0)),mode='edge')
        radius=(1+np.arange(-3,self.nr+3)*self.dr)[:,None]
        data=self.kernel.empty();data[self.vi]=vp/np.array([np.ones_like(radius),radius])
        data[self.ci]=cp/np.array([np.ones_like(radius),radius,radius**2])
        data[self.ui]=abs(data[self.vi])
        if omega is None:
            omega=(derivative(self.R*v[1],0,self.dr,True)-derivative(v[0],1,self.dtheta))/self.R
        data[self.oi]=np.pad(omega,((3,3),(0,0)),mode='edge')
        got=self.kernel.apply(data)[:,3:-3]
        if split:
            G=got[self.gi].reshape(2,2,self.nr,self.nt)*self.scale[:,None]/self.scale[None,:]
            return got[self.ai]*self.scale,got[self.ti]*self.cs,got[self.wi],G
        return got[self.ai]*self.scale,got[self.bi]*self.cs,got[self.wi]

    def step(self,state,t,dt):
        # A first-order split step: upwind transport is a convex combination
        # of positive tensors; stretching is a congruence F C F^T; relaxation
        # is a convex combination with identity. No eigenvalues are clipped.
        def forward(s,time):
            v,psi=self.velocity(s,time)
            assert dt*np.max(abs(v[0])/self.dr+abs(v[1])/(self.R*self.dtheta))<1
            rotation=s[0].copy()
            rotation[0]=-2*psi[1]/self.dr**2
            rotation[-1]=-2*psi[-2]/self.dr**2
            force,transport,omega,G=self.evaluate(v,s[2],True,rotation)
            c=s[2]+dt*transport
            a,b=1+dt*G[0,0],dt*G[0,1]
            d,e=dt*G[1,0],1+dt*G[1,1]
            xx,xy,yy=c
            c=np.array([a*a*xx+2*a*b*xy+b*b*yy,
                        a*d*xx+(a*e+b*d)*xy+b*e*yy,
                        d*d*xx+2*d*e*xy+e*e*yy])
            decay=np.exp(-dt/1.5);c*=decay;c[[0,2]]+=1-decay
            omega-=omega.mean(axis=1)[:,None];omega[[0,-1]]=0
            mean=force[1].mean(axis=1);mean[[0,-1]]=0
            return s[0]+dt*omega,s[1]+dt*mean,c
        predicted=forward(state,t)
        second=forward(predicted,t+dt)
        updated=tuple(.5*(s+p) for s,p in zip(state,second))
        updated[1][0]=self.wall_speed(t+dt);updated[1][-1]=0
        return updated

    def stats(self,state,t):
        v,psi=self.velocity(state,t)
        C=state[2]
        eigmin=.5*(C[0]+C[2]-np.sqrt((C[0]-C[2])**2+4*C[1]**2))
        assert eigmin.min()>0,dict(time=t,min_conformation_eigenvalue=float(eigmin.min()))
        divergence=(derivative(self.R*v[0],0,self.dr,True)+derivative(v[1],1,self.dtheta))/self.R
        kinetic=.5*np.sum(v*v,axis=0)
        polymer=.16/(2*1.5)*(C[0]+C[2]-np.log(C[0]*C[2]-C[1]**2)-2)
        weight=self.R*self.dr*self.dtheta;weight=weight.copy();weight[[0,-1]]*=.5
        perturb=v-v.mean(axis=2)[:,:,None]
        return dict(time=t,min_conformation_eigenvalue=float(eigmin.min()),
                    divergence_max=float(abs(divergence[1:-1]).max()),
                    perturbation_rms=float(np.sqrt(np.mean(perturb**2))),
                    max_speed=float(np.sqrt(np.sum(v*v,axis=0)).max()),
                    energy=float(np.sum((kinetic+polymer)*weight)),wall_speed=self.wall_speed(t))


def validate():
    rows=[]
    for n in [16,32,64]:
        model=Couette(n,4*n)
        state=model.initial(False)
        v,_=model.velocity(state,0)
        force,rate,omega=model.evaluate(v,state[2])
        perturbed=model.initial()
        pv,_=model.velocity(perturbed,0)
        _,transport,_,gradient=model.evaluate(pv,perturbed[2],True)
        V=pv/model.scale;C=perturbed[2]/model.cs
        expected=(-V[0]*derivative(C,1,model.dr,True)-V[1]*derivative(C,2,model.dtheta)
                  +abs(V[0])*model.dr*.5*model.d2(C,1,model.dr)
                  +abs(V[1])*model.dtheta*.5*model.d2(C,2,model.dtheta))*model.cs
        transport_error=float(abs((expected-transport)[:,3:-3]).max())
        assert transport_error<1e-9,transport_error
        matrix=np.array([[C[0],C[1]],[C[1],C[2]]])
        G=np.array([[derivative(V[i],j,[model.dr,model.dtheta][j],j==0)
                     for j in range(2)] for i in range(2)])
        expected_rate=np.einsum('ik...,kj...->ij...',G,matrix)+np.einsum('ik...,jk...->ij...',matrix,G)
        expected_rate-=V[0]*derivative(matrix,2,model.dr,True)+V[1]*derivative(matrix,3,model.dtheta)
        packed=np.array([expected_rate[0,0],expected_rate[0,1],expected_rate[1,1]])*model.cs
        packed-=(perturbed[2]-np.array([1,0,1])[:,None,None])/1.5
        actual_rate=model.evaluate(pv,perturbed[2])[1]
        tensor_error=float(abs((packed-actual_rate)[:,3:-3]).max())
        assert tensor_error<1e-9,tensor_error
        # Exact steady circular Couette solution of the full coupled model.
        # Its radial momentum residual is balanced by pressure; curl and
        # azimuthal acceleration vanish, as does the upper-convected RHS.
        region=(model.R>=1.25-1e-12)&(model.R<=1.75+1e-12)
        error=max(float(abs(force[1][region]).max()),float(abs(rate[:,region]).max()),
                  float(abs(omega[region]).max()))
        stats=model.stats(model.initial(),0)
        assert stats['divergence_max']<1e-11,stats
        assert stats['min_conformation_eigenvalue']>0,stats
        rows.append(dict(radial=n,steady_error=error,divergence=stats['divergence_max'],
                         transport_reference_error=transport_error,tensor_reference_error=tensor_error))
        print('couette validation',rows[-1],flush=True)
    orders=[float(np.log2(rows[i]['steady_error']/rows[i+1]['steady_error'])) for i in range(2)]
    assert min(orders)>1.7,orders
    model=Couette(24,64)
    solutions=[]
    for dt in [.001,.0005,.00025]:
        s=model.initial()
        for k in range(round(.2/dt)):s=model.step(s,k*dt,dt)
        solutions.append(s)
        assert model.stats(s,.2)['min_conformation_eigenvalue']>0
    errors=[max(float(abs(a-b).max()) for a,b in zip(solutions[k],solutions[k+1])) for k in range(2)]
    time_order=float(np.log2(errors[0]/errors[1]))
    assert .7<time_order<1.4,time_order
    print('couette time convergence',errors,time_order,flush=True)
    return dict(runs=rows,orders=orders,time_difference_errors=errors,time_order=time_order)


def simulate(radial=48,angular=128,end=24.,frames=121):
    model=Couette(radial,angular)
    state=model.initial()
    steps_per_frame=max(1,round(end/(frames-1)/min(.0015,.12*model.dr**2/.2)))
    dt=end/((frames-1)*steps_per_frame)
    output=WORK/'couette';output.mkdir(parents=True,exist_ok=True)
    records=[];start=time.monotonic()
    for frame in range(frames):
        if frame:
            for j in range(steps_per_frame):
                t=((frame-1)*steps_per_frame+j)*dt
                state=model.step(state,t,dt)
        t=frame*steps_per_frame*dt
        assert all(np.isfinite(s).all() for s in state)
        record=model.stats(state,t)
        assert record['min_conformation_eigenvalue']>0,record
        assert record['divergence_max']<1e-9,record
        records.append(record)
        v,psi=model.velocity(state,t)
        np.savez_compressed(output/f'frame-{frame:04d}.npz',v=v.astype(np.float32),
                            conformation=state[2].astype(np.float32),psi=psi.astype(np.float32),time=t)
        if frame%10==0:print('couette',frame,record,'elapsed',round(time.monotonic()-start,1),flush=True)
    report=dict(model='Incompressible Oldroyd-B rotating annulus',radial=radial,angular=angular,
                dt=dt,steps=(frames-1)*steps_per_frame,kernel=model.kernel.record,frames=records)
    write_report('couette',report)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--validate',action='store_true')
    p.add_argument('--radial',type=int,default=48);p.add_argument('--angular',type=int,default=128)
    p.add_argument('--end',type=float,default=24)
    a=p.parse_args()
    if a.validate:write_report('couette-validation',validate())
    else:simulate(a.radial,a.angular,a.end)
