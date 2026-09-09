"""Two overlapping spherical coordinate panels with tensor-aware exchange.

Arrays exchanged here hold orthonormal physical components. Each donor tensor
is rotated at its own grid point before interpolation into the recipient basis.
The Formurae kernels use coordinate components; callers convert using metric
scale factors. Neither the PDE nor the plotted motion is prescribed here.
"""
import numpy as np

ROTATION = np.array([[-1., 0, 0], [0, 0, 1], [0, 1, 0]])
TH0, PH0 = np.pi/6, -5*np.pi/6


def basis(theta, phi):
    theta, phi = np.broadcast_arrays(theta, phi)
    z = np.zeros_like(theta)
    return np.array([[np.sin(theta)*np.cos(phi), np.sin(theta)*np.sin(phi), np.cos(theta)],
                     [np.cos(theta)*np.cos(phi), np.cos(theta)*np.sin(phi), -np.sin(theta)],
                     [-np.sin(phi), np.cos(phi), z]])


def unpack(values, dim):
    result = np.zeros((dim, dim, *values.shape[1:]))
    for k, (i, j) in enumerate((i,j) for i in range(dim) for j in range(i,dim)):
        result[i,j] = result[j,i] = values[k]
    return result


def pack(values):
    dim = values.shape[0]
    return np.array([values[i,j] for i in range(dim) for j in range(i,dim)])


class YinYang:
    def __init__(self, resolution=48, rim=2):
        assert resolution % 6 == 0
        self.h = np.pi/resolution
        self.shape = (2*resolution//3+1, 5*resolution//3+1)
        self.rim = rim
        self.theta, self.phi = np.meshgrid(TH0+np.arange(self.shape[0])*self.h,
                                         PH0+np.arange(self.shape[1])*self.h, indexing='ij')
        local = basis(self.theta, self.phi)
        self.basis = np.array([local, np.einsum('ab,ib...->ia...', ROTATION, local)])
        self.xyz = self.basis[:,0]
        mask = np.ones(self.shape, dtype=bool)
        mask[rim:-rim, rim:-rim] = False
        self.rim_indices = np.where(mask)
        self.tables = []
        for p in range(2):
            xyz = self.xyz[p,:,mask].T
            self.tables.append(self.interpolation(1-p, xyz))
        self.area_weights = []
        # Partition unity prevents counting the panel overlap twice.
        for p in range(2):
            own = np.sin(self.theta)**8
            other_theta = self.angles(1-p, self.xyz[p].reshape(3,-1))[0].reshape(self.shape)
            other_phi = self.angles(1-p, self.xyz[p].reshape(3,-1))[1].reshape(self.shape)
            present = ((other_theta >= TH0) & (other_theta <= np.pi-TH0)
                       & (other_phi >= PH0) & (other_phi <= -PH0))
            other = np.where(present, np.sin(other_theta)**8, 0)
            self.area_weights.append(np.sin(self.theta)*self.h**2*own/(own+other))
        self.area_weights = np.array(self.area_weights)
        self.area_weights *= 4*np.pi/self.area_weights.sum()

    def angles(self, panel, xyz):
        local = xyz if panel == 0 else ROTATION @ xyz
        return np.arccos(np.clip(local[2], -1, 1)), np.arctan2(local[1], local[0])

    def interpolation(self, panel, xyz):
        th, ph = self.angles(panel, xyz)
        a, b = (th-TH0)/self.h, (ph-PH0)/self.h
        i, j = np.floor(a).astype(int), np.floor(b).astype(int)
        assert np.all((i >= 0) & (i < self.shape[0]-1) & (j >= 0) & (j < self.shape[1]-1))
        a, b = a-i, b-j
        return i, j, np.array([(1-a)*(1-b), a*(1-b), (1-a)*b, a*b])

    def interpolate_global(self, values, points, tensor=False, tangent=False):
        """Sample physical components at global unit vectors, returning Cartesian data."""
        th0, ph0 = self.angles(0, points)
        th1, ph1 = self.angles(1, points)
        ok0 = ((th0 > TH0+self.h) & (th0 < np.pi-TH0-self.h)
               & (ph0 > PH0+self.h) & (ph0 < -PH0-self.h))
        ok1 = ((th1 > TH0+self.h) & (th1 < np.pi-TH0-self.h)
               & (ph1 > PH0+self.h) & (ph1 < -PH0-self.h))
        assert (ok0 | ok1).all()
        choose = np.where(ok0 & (~ok1 | (np.sin(th0) >= np.sin(th1))), 0, 1)
        result = np.zeros(((3,3) if tensor else (3,)) + (points.shape[1],))
        for p in range(2):
            sel = choose == p
            if not sel.any():
                continue
            i, j, weights = self.interpolation(p, points[:,sel])
            sampled = np.zeros(result[...,sel].shape)
            for w, (di,dj) in zip(weights, [(0,0),(1,0),(0,1),(1,1)]):
                frame = self.basis[p,1:] if tangent else self.basis[p]
                frame = frame[:,:,i+di,j+dj]
                if tensor:
                    mat = unpack(values[p,:,i+di,j+dj].T, 2 if tangent else 3)
                    sampled += w*np.einsum('iac,ijc,jbc->abc', frame, mat, frame)
                else:
                    sampled += w*np.einsum('iac,ic->ac', frame, values[p,:,i+di,j+dj].T)
            result[...,sel] = sampled
        return result

    def exchange(self, values, tensor=False, tangent=False, trace_free=False):
        """Mutual rim update; values shape (2, components, [batch...], theta, phi)."""
        values = values.copy()
        originals = values.copy()
        dim = 2 if tangent else 3
        ri, rj = self.rim_indices
        for p in range(2):
            i, j, weights = self.tables[p]
            dst = self.basis[p,1:] if tangent else self.basis[p]
            dst = dst[:,:,ri,rj]
            accum = np.zeros_like(values[p,...,ri,rj])
            # Move advanced point index back to the last axis for einsum.
            accum = np.moveaxis(accum, 0, -1)
            for w, (di,dj) in zip(weights, [(0,0),(1,0),(0,1),(1,1)]):
                src = self.basis[1-p,1:] if tangent else self.basis[1-p]
                src = src[:,:,i+di,j+dj]
                rotation = np.einsum('iac,jac->ijc', dst, src)
                donor = np.moveaxis(originals[1-p,...,i+di,j+dj], 0, -1)
                if tensor:
                    mat = unpack(donor, dim)
                    transformed = np.einsum('ikc,kl...c,jlc->ij...c', rotation, mat, rotation)
                    if trace_free:
                        tr = np.einsum('ii...c->...c', transformed)/dim
                        for k in range(dim):
                            transformed[k,k] -= tr
                    accum += w*pack(transformed)
                else:
                    accum += w*np.einsum('ijc,j...c->i...c', rotation, donor)
            values[p,...,ri,rj] = np.moveaxis(accum, -1, 0)
        return values


def validate():
    """Constant Cartesian tensors must survive basis exchange exactly."""
    sphere=YinYang(24)
    vector=np.array([.3,-.4,.7])
    matrix=np.array([[1.,.2,-.1],[.2,.5,.3],[-.1,.3,.8]])
    v=np.einsum('pijab,j->piab',sphere.basis,vector)
    q=np.einsum('pikab,kl,pjlab->pijab',sphere.basis,matrix,sphere.basis)
    q=np.array([pack(p) for p in q])
    vector_error=float(abs(sphere.exchange(v)-v).max())
    tensor_error=float(abs(sphere.exchange(q,tensor=True)-q).max())
    points=sphere.xyz.reshape(2,3,-1)[0]
    sample_vector=float(abs(sphere.interpolate_global(v,points)-vector[:,None]).max())
    sample_tensor=float(abs(sphere.interpolate_global(q,points,tensor=True)-matrix[:,:,None]).max())
    report=dict(vector_exchange_error=vector_error,tensor_exchange_error=tensor_error,
                vector_sampling_error=sample_vector,tensor_sampling_error=sample_tensor,
                sphere_area=float(sphere.area_weights.sum()))
    assert max(vector_error,tensor_error,sample_vector,sample_tensor)<1e-12,report
    print('spherical basis validation',report,flush=True)
    return report


if __name__=='__main__':
    from tensor_demo_common import write_report
    write_report('sphere-exchange-validation',validate())
