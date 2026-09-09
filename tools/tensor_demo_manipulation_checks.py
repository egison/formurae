"""Time refinement across grip release and an independent exact transient."""
import numpy as np

from tensor_demo_common import write_report
from tensor_demo_manipulation import Manipulation


def main():
    records=[]
    for case,end,steps in [('press-ball',2.5,[100,200,400]),('twist-tube',5.,[100,200,400])]:
        m=Manipulation(case,4,24);solutions=[];grip_errors=[]
        for count in steps:
            dt=end/count;state=m.initial();grip_error=0
            for i in range(count):
                state=m.advance(state,i*dt,dt)
                if abs((i+1)*dt-m.release)<1e-10:
                    if m.sphere:
                        grip_error=float(abs((state[2][:,0]+m.amplitude*m.profile)[m.grip]).max())
                    else:grip_error=float(abs(state[2][:,1,...,-1]/m.R[...,-1]-m.amplitude).max())
            solutions.append(state);grip_errors.append(grip_error)
        scale=max(float(abs(a).max()) for a in solutions[-1])
        changes=[max(float(abs(a-b).max()) for a,b in zip(solutions[j],solutions[j+1]))/scale for j in range(2)]
        record=dict(case=case,end=end,steps=steps,relative_successive_changes=changes,
                    observed_time_order=float(np.log2(changes[0]/changes[1])),
                    prescribed_displacement_errors=grip_errors)
        print('release time refinement',record,flush=True)
        assert changes[1]<changes[0]/8 and changes[1]<1e-4,record
        assert max(grip_errors)<1e-6,record
        records.append(record)
    m=Manipulation('twist-tube',8,48);m.release=-1
    v,s,u=m.initial();a=.02;k=.25;phase=.7
    u[:,1]=a*m.R*np.sin(k*m.P)*np.cos(phase)
    v[:,1]=-a*k*m.R*np.sin(k*m.P)*np.sin(phase)
    s[:,4]=a*k*m.R*np.cos(k*m.P)*np.cos(phase)
    state=(v,s,u);initial=m.energy(v,s);end=2.;dt=.01
    for i in range(round(end/dt)):state=m.advance(state,i*dt,dt)
    exact=a*m.R*np.sin(k*m.P)*np.cos(phase+k*end)
    error=float(abs(state[2][:,1]-exact).max())/(2*a)
    drift=m.energy(*state[:2])/initial-1
    print('exact torsional transient',error,drift,flush=True)
    assert error<.002 and abs(drift)<1e-8
    write_report('manipulation-time-validation',dict(release_refinement=records,
        exact_torsion_displacement_relative_error=error,exact_torsion_relative_energy=drift))


if __name__=='__main__':main()
