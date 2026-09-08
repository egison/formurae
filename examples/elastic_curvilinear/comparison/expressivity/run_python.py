#!/usr/bin/env python3
"""Compare public indexed-function APIs and record working alternatives."""
import argparse
import contextlib
import hashlib
from importlib.metadata import version
import io
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
WORK = ROOT/'.build/related-work/expressivity-final'


def flux(a, b):
    return (a*a+a*b+b*b)/6


def attempt(fn):
    try:
        return {'accepted':True, 'result':str(fn())}
    except Exception as exc:
        return {'accepted':False, 'exception':type(exc).__name__, 'message':str(exc)}


def ufl_probes():
    from ufl import as_vector, as_matrix, as_tensor, indices, elem_op
    a,b,c = [as_vector(v) for v in [[1.,2.,3.],[4.,5.,6.],[7.,8.,9.]]]
    i,j = indices(2)
    direct = {
        'tensor_arguments':attempt(lambda:flux(a,b)),
        'same_free_index':attempt(lambda:as_tensor(flux(a[i],b[i]),(i,))),
        'different_free_indices':attempt(lambda:as_tensor(flux(a[i],b[j]),(i,j)))}
    aligned = elem_op(flux,a,b)
    pairs = as_matrix([[flux(a[p],b[q]) for q in range(3)] for p in range(3)])
    def inner(X,Y):
        k, = indices(1)
        return X[k]*Y[k]
    # A fresh Index object prevents capture by the caller's i.
    caller = as_tensor(c[i]*inner(a,b),(i,))
    def symmetric_part(T):
        i,j = indices(2)
        return as_tensor((T[i,j]+T[j,i])/2,(i,j))
    S = symmetric_part(as_matrix([[1.,2.,3.],[4.,5.,6.],[7.,8.,9.]]))
    values = [[float(pairs[p,q]) for q in range(3)] for p in range(3)]
    assert all(not r['accepted'] for r in direct.values())
    assert [float(aligned[k]) for k in range(3)] == [3.5,6.5,10.5]
    assert [float(caller[k]) for k in range(3)] == [224,256,288]
    assert all(abs(values[p][q]-flux(p+1,q+4)) < 1e-12 for p in range(3) for q in range(3))
    return {'direct_scalar_function':direct, 'working_aligned_values':[float(aligned[k]) for k in range(3)],
            'working_pairs_values':values, 'working_pairs_method':'as_matrix with explicit component indices',
            'local_indices_avoid_capture':True, 'symmetric_user_function_values':str(S),
            'stage':'UFL expression construction and evaluation; no finite-element solver'}


def sympy_probes():
    from sympy import Array, simplify
    from sympy.diffgeom import Differential, WedgeProduct
    from sympy.diffgeom.rn import R3_r
    from sympy.tensor.tensor import TensorIndexType, TensorHead, TensorSymmetry, tensor_indices
    from sympy.tensor.toperators import PartialDerivative
    L = TensorIndexType('L',dim=3)
    i,j = tensor_indices('i j',L)
    a,b = TensorHead('a',[L]),TensorHead('b',[L])
    direct = {'same_index':attempt(lambda:flux(a(i),b(i))),
              'different_indices':attempt(lambda:flux(a(i),b(j)))}
    assert all(not r['accepted'] for r in direct.values())
    S = TensorHead('S',[L,L],TensorSymmetry.fully_symmetric(2))
    residual = (S(i,j)-S(j,i)).canon_bp()
    assert residual == 0
    differentiated = PartialDerivative(a(i),b(j))
    assert differentiated.get_free_indices() == [i,-j]
    pairs = Array([[flux(p,q) for q in [4,5,6]] for p in [1,2,3]])
    x,y,z = R3_r.base_scalars()
    dx,dy,dz = R3_r.base_oneforms()
    ex,ey,ez = R3_r.base_vectors()
    f = x*y*z
    one_form = x*y*dx+y*z*dy+z*x*dz
    two_form = (x*z*WedgeProduct(dx,dy)+y*z*WedgeProduct(dx,dz)
                +x*y*WedgeProduct(dy,dz))
    df = [Differential(f)(e) for e in [ex,ey,ez]]
    dA = [simplify(Differential(one_form)(p,q))
          for p,q in [(ex,ey),(ex,ez),(ey,ez)]]
    dB = simplify(Differential(two_form)(ex,ey,ez))
    ddf = Differential(Differential(f))
    assert df == [y*z,x*z,x*y] and dA == [-x,z,-y]
    assert simplify(dB-(x+y-z)) == 0 and ddf == 0
    return {'direct_scalar_function':direct,
            'standard_contraction':str(a(i)*b(-i)), 'symmetry_residual':str(residual),
            'derivative_free_indices':[str(v) for v in differentiated.get_free_indices()],
            'working_pairs_values':pairs.tolist(),
            'working_pairs_method':'expand to component arrays, then apply the scalar function',
            'builtin_exterior_derivative':{'df':list(map(str,df)), 'dA':list(map(str,dA)),
                'dB':str(dB), 'ddf':str(ddf), 'method':'sympy.diffgeom.Differential'},
            'stage':'SymPy abstract tensor algebra, component arrays, and differential forms'}


def numpy_probes():
    import numpy as np
    a,b = np.array([1.,2.,3.]),np.array([4.,5.,6.])
    aligned,pairs = flux(a,b),flux(a[:,None],b[None,:])
    assert aligned.tolist() == [3.5,6.5,10.5]
    return {'aligned_values':aligned.tolist(), 'pairs_values':pairs.tolist(),
            'pairs_method':'insert axes explicitly: a[:,None], b[None,:]',
            'sum_aligned':float(aligned.sum())}


def nrpylatex_probes():
    import nrpylatex as nl
    base = r'''% declare index latin --dim 3
% declare aU bD cU
% replace "\mathrm{dot}(\1,\2)" -> "\1^i \2_i"
'''
    scalar = attempt(lambda:nl.parse_latex(base+r's=\mathrm{dot}(a,b)',reset=True))
    collision = attempt(lambda:nl.parse_latex(base+r'q^i=c^i \mathrm{dot}(a,b)',reset=True))
    repaired = attempt(lambda:nl.parse_latex(
        base.replace(r'\1^i \2_i',r'\1^j \2_j')+r'q^i=c^i \mathrm{dot}(a,b)',reset=True))
    assert scalar['accepted'] and not collision['accepted'] and repaired['accepted']
    assert "illegal bound index 'i'" in collision['message']
    return {'custom_dot_macro_scalar_call':scalar, 'macro_with_caller_index_i':collision,
            'macro_after_manual_dummy_index_rename':repaired,
            'note':'This tests a custom replacement template. Built-in tensor derivatives have their own index generation.'}


def devito_probes():
    import numpy as np
    from sympy import ImmutableDenseMatrix, LeviCivita
    from devito import Grid, VectorFunction, TensorFunction, Eq, Operator, Derivative, NODE, centered
    grid = Grid(shape=(7,7,7),extent=(1.5,1.5,1.5),dtype=np.float64)
    a,b = [VectorFunction(name=s,grid=grid,staggered=(NODE,)*3,space_order=2) for s in ['a','b']]
    direct = attempt(lambda:flux(a,b))
    assert not direct['accepted']
    for k in range(3):
        a[k].data[:] = k+1
        b[k].data[:] = k+4
    aligned = VectorFunction(name='aligned',grid=grid,staggered=(NODE,)*3)
    pairs = TensorFunction(name='pairs',grid=grid,staggered=NODE,symmetric=False)
    rhs_aligned = ImmutableDenseMatrix(3,1,lambda i,j:flux(a[i],b[i]))
    rhs_pairs = ImmutableDenseMatrix(3,3,lambda i,j:flux(a[i],b[j]))
    op = Operator([Eq(aligned,rhs_aligned),Eq(pairs,rhs_pairs)],opt='noop')
    op.apply()
    values = [[float(pairs[i,j].data[2,2,2]) for j in range(3)] for i in range(3)]
    max_error = max(abs(values[i][j]-flux(i+1,j+4)) for i in range(3) for j in range(3))
    assert max_error < 1e-12
    X,R = [VectorFunction(name=s,grid=grid,staggered=(NODE,)*3,space_order=2) for s in ['X','R']]
    x,y,z = np.meshgrid(*[np.arange(7)*0.25]*3,indexing='ij')
    for k,values_x in enumerate([x*y,y*z,z*x]): X[k].data[:] = values_x
    def rotation(X):
        return ImmutableDenseMatrix(3,1,lambda i,_:sum(
            LeviCivita(i,j,k)*Derivative(X[k],grid.dimensions[j],fd_order=2,side=centered)
            for j in range(3) for k in range(3)))
    rotation_op = Operator(Eq(R,rotation(X)),opt='noop')
    rotation_op.apply()
    curl = [float(R[i].data[2,3,4]) for i in range(3)]
    assert curl == [-0.75,-1.0,-0.5]
    (WORK/'devito-indexed-functions.c').write_text(str(op.ccode))
    (WORK/'devito-user-curl.c').write_text(str(rotation_op.ccode))
    return {'direct_vector_arguments':direct, 'working_pairs_values':values,
            'working_pairs_method':'construct the component matrix with a Python function',
            'pairs_max_error':max_error, 'user_defined_curl_values':curl,
            'curl_sample_coordinates':[0.5,0.75,1.0],
            'compiled_c_executed':True}


def opensbli_probes():
    sys.path.insert(0,str(ROOT/'.build/related-work/sources/opensbli'))
    from opensbli import EinsteinEquation
    def expand(equation,sub):
        return EinsteinEquation().expand(equation,3,'x',[sub],[])
    scalar = attempt(lambda:expand('Eq(z,s)','Eq(s,a_i*b_i)'))
    collision = attempt(lambda:expand('Eq(q_i,c_i*s)','Eq(s,a_i*b_i)'))
    repaired = attempt(lambda:expand('Eq(q_i,c_i*s)','Eq(s,a_j*b_j)'))
    assert scalar['accepted'] and not collision['accepted'] and repaired['accepted']
    return {'substitution_scalar':scalar, 'substitution_with_caller_index_i':collision,
            'substitution_after_manual_dummy_index_rename':repaired,
            'stage':'EinsteinEquation.expand; no OPS backend execution'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('suite',choices=['modern','opensbli'])
    args = parser.parse_args()
    WORK.mkdir(parents=True,exist_ok=True)
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        names = ['ufl','sympy','numpy','nrpylatex','devito'] if args.suite == 'modern' else ['opensbli']
        results = {name:globals()[name+'_probes']() for name in names}
    packages = ['sympy','numpy']+(['fenics-ufl','nrpylatex','devito'] if args.suite=='modern' else [])
    report = {'all_checks_passed':True,'python':sys.version.split()[0],
              'packages':{p:version(p) for p in packages},
              'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'results':results}
    output = HERE/('results-python.json' if args.suite=='modern' else 'results-opensbli.json')
    output.write_text(json.dumps(report,ensure_ascii=False,indent=2,default=str)+'\n')
    (WORK/(args.suite+'.log')).write_text(log.getvalue())
    print(output.relative_to(ROOT))


if __name__ == '__main__':
    main()
