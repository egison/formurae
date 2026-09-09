"""Nonlinear tangent Q-tensor relaxation on the complete sphere."""
import argparse
import time

import numpy as np

from tensor_demo_common import Kernel, WORK, derivative, write_report
from tensor_demo_sphere import YinYang, pack, unpack


class Nematic:
    def __init__(self, resolution=48):
        self.sphere = YinYang(resolution)
        self.kernel = Kernel('nematic_sphere', self.sphere.shape,
                             [self.sphere.h]*2, [False, False])
        self.qi, self.ri = self.kernel.indices('Q_'), self.kernel.indices('rhs_')
        st = np.sin(self.sphere.theta)
        self.scale = np.array([np.ones_like(st), st, st*st])

    def rhs(self, q, exchange=True):
        if exchange:
            q = self.sphere.exchange(q, tensor=True, tangent=True, trace_free=True)
        result = np.zeros_like(q)
        for p in range(2):
            data = self.kernel.empty()
            data[self.qi] = q[p]/self.scale
            result[p] = self.kernel.apply(data)[self.ri]*self.scale
        return result

    def initial(self, perturb=True):
        s = self.sphere
        tensor = np.diag([1., 0., -1.])
        if perturb:
            x,y,z = s.xyz[:,0],s.xyz[:,1],s.xyz[:,2]
            tensor = np.broadcast_to(tensor[:,:,None,None,None], (3,3,2,*s.shape)).copy()
            # Smooth global polynomial initial data; all tensor entries vary.
            # The same physical field is used on both panels and every grid.
            rng=np.random.default_rng(314159)
            for feature in [x,y,z,x*y,y*z,z*x]:
                matrix=rng.normal(size=(3,3))
                matrix=(matrix+matrix.T)/2
                matrix-=np.eye(3)*np.trace(matrix)/3
                tensor+=.4*matrix[:,:,None,None,None]*feature[None,None]
            mats = np.einsum('paibc,ijpbc,pdjbc->padbc', s.basis[:,1:], tensor, s.basis[:,1:])
        else:
            mats = np.einsum('paibc,ij,pdjbc->padbc', s.basis[:,1:], tensor, s.basis[:,1:])
        tr = np.einsum('piiab->pab', mats)/2
        mats[:,0,0] -= tr
        mats[:,1,1] -= tr
        return np.array([pack(m) for m in mats])*.35

    def reference(self, q):
        """Independent component implementation of the same centered SBP formula."""
        th = self.sphere.theta
        si, co = np.sin(th), np.cos(th)
        gamma = np.zeros((2,2,2,*th.shape))
        gamma[0,1,1] = -si*co
        gamma[1,0,1] = gamma[1,1,0] = co/si
        metric_inverse = [np.ones_like(si), 1/si**2]
        results=[]
        for panel in q:
            Q = unpack(panel/self.scale, 2)
            H = np.empty((2,2,2,*th.shape))
            for k in range(2):
                for i in range(2):
                    for j in range(2):
                        H[k,i,j] = derivative(Q[i,j], k, self.sphere.h, True)
                        for m in range(2):
                            H[k,i,j] += gamma[i,k,m]*Q[m,j]+gamma[j,k,m]*Q[i,m]
            lap = np.zeros_like(Q)
            for i in range(2):
                for j in range(2):
                    for k in range(2):
                        term = derivative(H[k,i,j], k, self.sphere.h, True)
                        for m in range(2):
                            term += (gamma[i,k,m]*H[k,m,j] + gamma[j,k,m]*H[k,i,m]
                                     - gamma[m,k,k]*H[m,i,j])
                        lap[i,j] += metric_inverse[k]*term
            physical = pack(lap)*self.scale
            tr=(physical[0]+physical[2])/2
            physical[0]-=tr
            physical[2]-=tr
            norm = panel[0]**2+2*panel[1]**2+panel[2]**2
            results.append(.02*physical+(1-2*norm)*panel)
        return np.array(results)

    def defects(self, q):
        s=self.sphere
        points=[]
        for p in range(2):
            z=(q[p,0]-q[p,2])/2+1j*q[p,1]
            angles=np.angle(z)
            d=lambda a,b: np.angle(np.exp(1j*(b-a)))
            winding=(d(angles[:-1,:-1],angles[1:,:-1])
                     +d(angles[1:,:-1],angles[1:,1:])
                     +d(angles[1:,1:],angles[:-1,1:])
                     +d(angles[:-1,1:],angles[:-1,:-1]))/(2*np.pi)
            winding[:s.rim]=0;winding[-s.rim:]=0
            winding[:,:s.rim]=0;winding[:,-s.rim:]=0
            for i,j in zip(*np.where(abs(winding)>.5)):
                xyz=s.xyz[p,:,i:i+2,j:j+2].mean(axis=(1,2));xyz/=np.linalg.norm(xyz)
                charge=round(winding[i,j])/2
                duplicate=next((k for k,(pt,ch) in enumerate(points)
                                if ch==charge and np.linalg.norm(pt-xyz)<3*s.h),None)
                if duplicate is None:
                    points.append((xyz,charge))
        return [{'position':pt.tolist(),'charge':ch} for pt,ch in points]

    def energy(self,q):
        a,b=(q[:,0]-q[:,2])/2,q[:,1]
        h=self.sphere.h
        si,co=np.sin(self.sphere.theta),np.cos(self.sphere.theta)
        gradient=2*(derivative(a,1,h,True)**2+derivative(b,1,h,True)**2
                    +((derivative(a,2,h,True)-2*co*b)/si)**2
                    +((derivative(b,2,h,True)+2*co*a)/si)**2)
        norm=2*(a*a+b*b)
        return float(np.sum((.01*gradient-.5*norm+.5*norm**2)*self.sphere.area_weights))


def validate():
    rows=[]
    for n in [24,48,96]:
        model=Nematic(n)
        q=model.initial(False)
        rhs=model.rhs(q,False)
        reference=model.reference(q)
        err=float(np.max(np.abs((rhs-reference)[...,3:-3,3:-3])))
        assert err<1e-10,err
        norm=q[:,0]**2+2*q[:,1]**2+q[:,2]**2
        lap=(rhs-(1-2*norm[:,None])*q)/.02
        # Compare a fixed physical region across resolutions; a fixed number
        # of excluded cells would move the measurement towards chart edges.
        region=((model.sphere.theta>=np.pi/3-1e-12)
                & (model.sphere.theta<=2*np.pi/3+1e-12)
                & (abs(model.sphere.phi)<=2*np.pi/3+1e-12))
        error=float(np.max(np.abs((lap+2*q)[...,region])))
        exchanged=model.sphere.exchange(q,tensor=True,tangent=True,trace_free=True)
        seam=float(np.max(np.abs(exchanged-q)))
        rows.append(dict(resolution=n,reference_error=err,eigenmode_error=error,exchange_error=seam))
        print('nematic validation',rows[-1],flush=True)
    orders=[float(np.log2(rows[k]['eigenmode_error']/rows[k+1]['eigenmode_error'])) for k in range(2)]
    assert min(orders)>1.6,orders
    return dict(runs=rows,spatial_orders=orders)


def simulate(resolution=48, end=30., frames=121):
    model=Nematic(resolution)
    q=model.initial()
    dt=min(.004, .5*model.sphere.h**2)
    frame_steps=max(1,round(end/(frames-1)/dt))
    dt=end/((frames-1)*frame_steps)
    output=WORK/'nematic';output.mkdir(parents=True,exist_ok=True)
    start=time.monotonic()
    records=[]
    for frame in range(frames):
        if frame:
            for _ in range(frame_steps):
                k1=model.rhs(q)
                k2=model.rhs(q+dt*k1)
                q += .5*dt*(k1+k2)
                q=model.sphere.exchange(q,tensor=True,tangent=True,trace_free=True)
        assert np.isfinite(q).all()
        trace=float(np.max(np.abs(q[:,0]+q[:,2])))
        assert trace<1e-9,trace
        norm=q[:,0]**2+2*q[:,1]**2+q[:,2]**2
        assert norm.max()<2,norm.max()
        defects=model.defects(q)
        charge=sum(d['charge'] for d in defects)
        assert charge==2, (frame,defects)
        records.append(dict(time=frame*frame_steps*dt,trace_error=trace,
                            order_max=float(np.sqrt(2*norm).max()),energy=model.energy(q),
                            total_defect_charge=charge,defects=defects))
        np.savez_compressed(output/f'frame-{frame:04d}.npz',q=q.astype(np.float32),time=records[-1]['time'])
        if frame%10==0:
            print('nematic',frame,'t',records[-1]['time'],'defects',len(defects),
                  'charge',sum(d['charge'] for d in defects),'elapsed',round(time.monotonic()-start,1),flush=True)
    report=dict(model='Intrinsic surface Landau-de Gennes relaxation',kernel=model.kernel.record,
                resolution=resolution,dt=dt,steps=(frames-1)*frame_steps,frames=records)
    write_report('nematic',report)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--validate',action='store_true')
    parser.add_argument('--resolution',type=int,default=48)
    parser.add_argument('--end',type=float,default=30)
    args=parser.parse_args()
    if args.validate:
        write_report('nematic-validation',validate())
    else:
        simulate(args.resolution,args.end)
