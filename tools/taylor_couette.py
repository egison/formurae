"""Taylor--Couette experiment driven by the actual Formurae-generated C RHS.

No fluid momentum equations are implemented in Python. This driver supplies
staggered no-slip boundaries, a compatible pressure solve, and RK2 integration.
All compiler and simulation commands run serially.
"""
import argparse
import json
import time
from pathlib import Path

import numpy as np
from scipy.fft import rfft2, irfft2

from taylor_couette_kernel import Kernel, ROOT, sha

WORK = ROOT / '.build/taylor-couette'
RESULTS = ROOT / 'examples/taylor_couette/results'
HALO = 2


class TaylorCouette:
    def __init__(self, nr=24, nt=64, nz=48, length=4., reynolds=120.):
        self.nr, self.nt, self.nz = nr, nt, nz
        self.length, self.reynolds = length, reynolds
        self.dr, self.ht, self.hz = 1/nr, 2*np.pi/nt, length/nz
        self.shape = (nr+2*HALO+1, nt, nz)
        self.rc = (3+(np.arange(nr)+.5)*self.dr)[:, None, None]
        self.rf = (3+np.arange(nr+1)*self.dr)[:, None, None]
        self.kernel = Kernel('taylor_couette3d', self.shape,
                             [self.dr, self.ht, self.hz], [False, True, True])
        self.state = self.kernel.initial()
        self.vi = [self.kernel.fields.index(s) for s in ('u', 'v', 'w')]
        self.ai = [self.kernel.fields.index(s) for s in ('au', 'av', 'aw')]
        self.state[self.kernel.fields.index('viscosity')] = 1/reynolds
        self._factor_pressure()

    def _factor_pressure(self):
        # -D G on the same cylindrical finite-volume grid as div() and project().
        a = -(self.rc[:, 0, 0]-.5*self.dr)/(self.rc[:, 0, 0]*self.dr**2)
        c = -(self.rc[:, 0, 0]+.5*self.dr)/(self.rc[:, 0, 0]*self.dr**2)
        a[0] = 0
        c[-1] = 0
        kt = (2*np.sin(np.pi*np.arange(self.nt)/self.nt)/self.ht)**2
        kz = (2*np.sin(np.pi*np.arange(self.nz//2+1)/self.nz)/self.hz)**2
        b = -a[:, None, None]-c[:, None, None]+kt[None, :, None]/self.rc**2+kz[None, None, :]
        self.a = np.broadcast_to(a[:, None, None], b.shape).copy()
        self.c = np.broadcast_to(c[:, None, None], b.shape).copy()
        # Pin one pressure value in the constant Fourier mode only.
        self.a[-1, 0, 0] = 0
        b[-1, 0, 0] = 1
        self.inv = np.empty_like(b)
        self.cp = np.empty_like(b)
        for i in range(self.nr):
            self.inv[i] = 1/(b[i]-(self.a[i]*self.cp[i-1] if i else 0))
            self.cp[i] = self.c[i]*self.inv[i]

    def boundaries(self, q):
        h, n = HALO, self.nr
        q[0, h] = q[0, h+n] = 0
        for j in range(1, HALO+1):
            q[0, h-j] = -q[0, h+j]
            q[0, h+n+j] = -q[0, h+n-j]
        for component, wall in ((1, 1.), (2, 0.)):
            for j in range(1, HALO+1):
                q[component, h-j] = 2*wall-q[component, h+j-1]
            for j in range(1, HALO+2):
                q[component, h+n+j-1] = -q[component, h+n-j]
        return q

    def initial(self, amplitude=.002):
        q = np.zeros((3, *self.shape))
        h, n = HALO, self.nr
        q[1, h:h+n] = (48/self.rc-3*self.rc)/7
        # Curl of an edge streamfunction gives a divergence-free initial seed.
        theta = (np.arange(self.nt)+.5)*self.ht
        z = np.arange(self.nz)*self.hz
        envelope = np.sin(np.pi*(self.rf-3))**2
        # Distinct axial phases break reflection symmetry. A separable seed
        # sin(k z)*f(theta) would keep u,v even and w odd in z, excluding the
        # axial displacement of vortex boundaries that defines a wavy vortex.
        axial = 2*np.pi*z/self.length
        pattern = np.broadcast_to(np.sin(2*axial)+.15*np.sin(axial), (self.nt, self.nz)).copy()
        for mode in range(1, 5):
            pattern += .15*np.cos(mode*theta[:, None]+.31*mode)*np.sin(2*axial[None, :]+.73*mode)
            pattern += .04*np.sin(mode*theta[:, None]+.27*mode)*np.cos(axial[None, :]+.43*mode)
        psi = amplitude*envelope*pattern[None, :, :]
        q[0, h:h+n+1] = (np.roll(psi, -1, axis=2)-psi)/(self.rf*self.hz)
        q[2, h:h+n] = -(psi[1:]-psi[:-1])/(self.rc*self.dr)
        return self.boundaries(q)

    def rhs(self, q):
        self.boundaries(q)
        for i, field in enumerate(self.vi):
            self.state[field] = q[i]
        out = self.kernel.apply(self.state)
        f = np.ascontiguousarray(out[self.ai])
        f[0, HALO] = f[0, HALO+self.nr] = 0
        return self.project(f)

    def div(self, q):
        h, n = HALO, self.nr
        u = q[0, h:h+n+1]
        v, w = q[1:, h:h+n]
        return ((self.rf[1:]*u[1:]-self.rf[:-1]*u[:-1])/(self.rc*self.dr)
                +(np.roll(v, -1, axis=1)-v)/(self.rc*self.ht)
                +(np.roll(w, -1, axis=2)-w)/self.hz)

    def pressure(self, rhs):
        # Solve -D G p = rhs. The weighted zero-mode mean is a roundoff residual.
        x = rfft2(rhs, axes=(1, 2), workers=1)
        x[:, 0, 0] -= np.sum(x[:, 0, 0]*self.rc[:, 0, 0])/np.sum(self.rc)
        x[-1, 0, 0] = 0
        for i in range(self.nr):
            x[i] = (x[i]-(self.a[i]*x[i-1] if i else 0))*self.inv[i]
        for i in range(self.nr-2, -1, -1):
            x[i] -= self.cp[i]*x[i+1]
        return irfft2(x, s=(self.nt, self.nz), axes=(1, 2), workers=1)

    def project(self, q):
        h, n = HALO, self.nr
        p = self.pressure(-self.div(q))
        q[0, h+1:h+n] -= (p[1:]-p[:-1])/self.dr
        q[1, h:h+n] -= (p-np.roll(p, 1, axis=1))/(self.rc*self.ht)
        q[2, h:h+n] -= (p-np.roll(p, 1, axis=2))/self.hz
        return q

    def step(self, q, dt):
        f = self.rhs(q)
        predictor = q+dt*f
        q += .5*dt*(f+self.rhs(predictor))
        return self.boundaries(q)

    def centered(self, q):
        h, n = HALO, self.nr
        u = .5*(q[0, h:h+n]+q[0, h+1:h+n+1])
        v = q[1, h:h+n]
        w = q[2, h:h+n]
        return np.array([u, .5*(v+np.roll(v, -1, axis=1)),
                         .5*(w+np.roll(w, -1, axis=2))])

    def diagnostics(self, q, t, dt):
        if not np.isfinite(q).all():
            raise RuntimeError(f'Nonfinite velocity at t={t}')
        v = self.centered(q)
        weight = np.broadcast_to(self.rc, v[0].shape)
        mean = lambda a: float(np.sum(weight*a)/np.sum(weight))
        secondary = mean(v[0]**2+v[2]**2)
        nonaxis = mean(np.sum((v-v.mean(axis=2, keepdims=True))**2, axis=0))
        divergence = float(np.max(np.abs(self.div(q))))
        cfl = dt*float(np.max(np.abs(v[0])/self.dr+np.abs(v[1])/(self.rc*self.ht)+np.abs(v[2])/self.hz))
        if divergence > 1e-8 or cfl > .8:
            raise RuntimeError(f'Failed numerical check at t={t}: divergence={divergence}, CFL={cfl}')
        return dict(time=t, secondary_rms=np.sqrt(secondary), nonaxisymmetric_rms=np.sqrt(nonaxis),
                    max_divergence=divergence, courant=cfl, max_speed=float(np.max(np.sqrt(np.sum(v*v, axis=0)))))


def provenance(model):
    return dict(kernel=model.kernel.record, source_sha256=sha(ROOT/'examples/taylor_couette/taylor_couette3d.fme'),
                driver_sha256=sha(__file__), numpy_version=np.__version__)


def simulate(args):
    model = TaylorCouette(args.nr, args.nt, args.nz, args.length, args.reynolds)
    dt = min(args.dt, .18/(1/args.reynolds*(1/model.dr**2+1/(3*model.ht)**2+1/model.hz**2)))
    steps = int(np.ceil(args.time/dt))
    dt = args.time/steps
    save_steps = set(np.rint(np.linspace(0, steps, args.frames+1)).astype(int))
    q = model.initial(args.amplitude)
    if args.restart:
        saved = np.load(args.restart)
        if saved['state'].shape != q.shape:
            raise ValueError('Restart grid does not match')
        q = model.boundaries(saved['state'].copy())
    directory = WORK/args.name
    directory.mkdir(parents=True, exist_ok=True)
    records, frames = [], []
    wall_start, last_print = time.monotonic(), 0
    for step in range(steps+1):
        if step in save_steps:
            record = model.diagnostics(q, step*dt, dt)
            records.append(record)
            frames.append(model.centered(q).astype(np.float32))
            if time.monotonic()-last_print > 20 or step == steps:
                print(f'{args.name}: {step}/{steps} t={step*dt:.2f} secondary={record["secondary_rms"]:.6g} nonaxis={record["nonaxisymmetric_rms"]:.6g} elapsed={time.monotonic()-wall_start:.1f}s', flush=True)
                last_print = time.monotonic()
        if step != steps:
            q = model.step(q, dt)
    np.savez_compressed(directory/'frames.npz', velocity=np.array(frames), time=[r['time'] for r in records],
                        radius=model.rc[:, 0, 0], length=args.length, reynolds=args.reynolds)
    np.savez_compressed(directory/'restart.npz', state=q)
    report = dict(reynolds=args.reynolds, inner_radius=3, outer_radius=4, radius_ratio=.75,
                  axial_period=args.length, grid=[args.nr, args.nt, args.nz], dt=dt, steps=steps,
                  initial_amplitude=args.amplitude, restart=str(args.restart) if args.restart else None,
                  wall_seconds=time.monotonic()-wall_start, observations=records, **provenance(model))
    RESULTS.mkdir(exist_ok=True)
    (RESULTS/f'taylor-couette-{args.name}.json').write_text(json.dumps(report, indent=2, allow_nan=False)+'\n')


def validate(args):
    reports = []
    # A manufactured smooth field checks all 3 nonlinear cylindrical components,
    # staggering, interpolation and viscous metric terms against continuum values.
    for n in (8, 16, 32):
        m = TaylorCouette(n, 4*n, 2*n)
        q = np.zeros((3, *m.shape))
        exact = []
        for target in range(3):
            r = 3+(np.arange(m.shape[0])-HALO+.5-(.5 if target == 0 else 0))*m.dr
            th = (np.arange(m.nt)+(.0 if target == 1 else .5))*m.ht
            z = (np.arange(m.nz)+(.0 if target == 2 else .5))*m.hz
            R, T, Z = np.meshgrid(r, th, z, indexing='ij')
            def value(component):
                k, b = component+1, 2*np.pi/m.length
                f, fr, frr = np.sin(np.pi*(R-3))**2, np.pi*np.sin(2*np.pi*(R-3)), 2*np.pi**2*np.cos(2*np.pi*(R-3))
                a = np.sin(k*T)*np.cos(b*Z)
                v = f*a
                return (v, fr*a, f*k*np.cos(k*T)*np.cos(b*Z), -f*b*np.sin(k*T)*np.sin(b*Z),
                        frr*a+fr*a/R-k*k*v/R**2-b*b*v)
            U, V, W = [value(j) for j in range(3)]
            q[target] = (U, V, W)[target][0]
            Q = (U, V, W)[target]
            acc = -U[0]*Q[1]-V[0]*Q[2]/R-W[0]*Q[3]+Q[4]/m.reynolds
            if target == 0:
                acc += V[0]**2/R+(-U[0]-2*V[2])/(m.reynolds*R**2)
            elif target == 1:
                acc += -U[0]*V[0]/R+(-V[0]+2*U[2])/(m.reynolds*R**2)
            exact.append(acc)
        for i, field in enumerate(m.vi):
            m.state[field] = q[i]
        got = m.kernel.apply(m.state)[m.ai]
        region = (slice(None), slice(HALO+2, HALO+n-2), slice(None), slice(None))
        error = float(np.sqrt(np.mean((got[region]-np.array(exact)[region])**2)))
        rng = np.random.default_rng(20260909)
        random = rng.normal(size=q.shape)
        random[0, HALO] = random[0, HALO+n] = 0
        projected = m.project(random)
        div = float(np.max(np.abs(m.div(projected))))
        assert div < 1e-9, div
        base = m.initial(0)
        rate = m.rhs(base)
        base_error = float(np.max(np.abs(rate[1, HALO+2:HALO+n-2])))
        assert np.isfinite(error) and np.isfinite(base_error)
        seed = m.initial()
        seed_divergence = float(np.max(np.abs(m.div(seed))))
        uc = m.centered(seed)[0]
        reflection_difference = float(np.sqrt(np.mean((uc-uc[..., ::-1])**2)))
        assert seed_divergence < 1e-10 and reflection_difference > 1e-5
        reports.append(dict(n=n, manufactured_rms_error=error, projected_divergence=div,
                            couette_acceleration_error=base_error, seed_divergence=seed_divergence,
                            seed_reflection_difference=reflection_difference, **provenance(m)))
        print(json.dumps({k:v for k,v in reports[-1].items() if k not in ('kernel',)}), flush=True)
    orders = [np.log2(reports[i]['manufactured_rms_error']/reports[i+1]['manufactured_rms_error']) for i in range(2)]
    assert min(orders) > 1.7, orders
    # Temporal order against a finer trajectory of the generated PDE.
    m = TaylorCouette(12, 32, 24, reynolds=120)
    states = []
    for dt in (.02, .01, .005):
        q = m.initial(.02)
        for _ in range(round(.4/dt)):
            q = m.step(q, dt)
        states.append(m.centered(q))
    errors = [float(np.linalg.norm(states[i]-states[2])) for i in (0, 1)]
    assert errors[0]/errors[1] > 3.5, errors
    result = dict(passed=True, spatial=reports, spatial_orders=orders,
                  time_errors=errors, time_error_ratio=errors[0]/errors[1])
    RESULTS.mkdir(exist_ok=True)
    (RESULTS/'taylor-couette-validation.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k != 'spatial'}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['simulate', 'validate'])
    parser.add_argument('--nr', type=int, default=24)
    parser.add_argument('--nt', type=int, default=64)
    parser.add_argument('--nz', type=int, default=48)
    parser.add_argument('--length', type=float, default=4.)
    parser.add_argument('--reynolds', type=float, default=120.)
    parser.add_argument('--time', type=float, default=300.)
    parser.add_argument('--dt', type=float, default=.02)
    parser.add_argument('--frames', type=int, default=120)
    parser.add_argument('--amplitude', type=float, default=.002)
    parser.add_argument('--restart', type=Path)
    parser.add_argument('--name', default='re120')
    args = parser.parse_args()
    if min(args.nr, args.nt, args.nz) < 8 or args.frames < 1 or min(args.reynolds, args.time, args.dt, args.length) <= 0:
        parser.error('Grid sizes must be at least 8 and physical/time parameters positive')
    (simulate if args.action == 'simulate' else validate)(args)
