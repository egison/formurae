#!/usr/bin/env python3
"""Run actual public APIs, rather than emulating another system's parser.

Use the Python environments and source revisions documented in README.md.
The common constitutive test is an algebraic kernel, not a wave-propagation
or performance benchmark. C execution is additionally checked for Devito.
"""
import argparse
import contextlib
import io
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/related-work'
E_VALUES = [[1, 2, 3], [2, 4, 5], [3, 5, 6]]


def expected(coordinate, r=0.5, theta=0.25):
    diagonal = [1, (1+r)**-2,
                1 if coordinate == 'cylindrical' else
                ((1+r)*math.sin(1+theta))**-2]
    trace = sum(diagonal[i]*E_VALUES[i][i] for i in range(3))
    return [[(2*diagonal[i]*trace if i == j else 0)
             + 2*diagonal[i]*diagonal[j]*E_VALUES[i][j]
             + (0.5*E_VALUES[0][0] if i == j == 0 else 0)
             for j in range(3)] for i in range(3)]


def error(actual, target):
    return max(abs(actual[i][j]-target[i][j])
               for i in range(3) for j in range(3))


def nrpylatex_probes():
    import nrpylatex as nl
    from sympy import simplify
    out = {}
    declaration = r'''% declare index latin --dim 3
% declare eDD --dim 3 --sym sym01
% declare GUU --dim 3 --sym sym01
% declare nU mU --dim 3
% declare alpha --const
% declare qUU --dim 3 --sym sym01
'''
    equation = (r'q^{ij}=2 G^{ij} G^{kl} e_{kl}'
                r'+2 G^{ik} G^{jl} e_{kl}'
                r'+\alpha n^i n^j n^k n^l e_{kl}')
    nl.parse_latex(declaration+equation, reset=True)
    tensors = globals()
    correct = tensors['qUU']
    out['anisotropic_symmetric'] = all(
        simplify(correct[i][j]-correct[j][i]) == 0
        for i in range(3) for j in range(3))
    out['coordinates'] = {}
    for coordinate in ['cylindrical', 'spherical']:
        d = [1, 1/1.5**2, 1 if coordinate == 'cylindrical'
             else 1/(1.5*math.sin(1.25))**2]
        subs = {tensors['alpha']: 0.5}
        for i in range(3):
            subs[tensors['nU'][i]] = int(i == 0)
            for j in range(3):
                subs[tensors['eDD'][i][j]] = E_VALUES[i][j]
                subs[tensors['GUU'][i][j]] = d[i] if i == j else 0
        values = [[float(correct[i][j].subs(subs)) for j in range(3)]
                  for i in range(3)]
        out['coordinates'][coordinate] = {
            'max_error': error(values, expected(coordinate)), 'values': values}

    nl.parse_latex(declaration+equation.replace('n^i n^j', 'n^i m^j'),
                   reset=True)
    wrong = globals()['qUU']
    out['asymmetric_update'] = {
        'accepted': True,
        'result_is_symmetric': all(simplify(wrong[i][j]-wrong[j][i]) == 0
                                  for i in range(3) for j in range(3)),
        'difference_01_10': str(simplify(wrong[0][1]-wrong[1][0]))}
    try:
        nl.parse_latex(r'''% declare eUU --dim 3 --sym sym01
% declare CUUUU --dim 3
q^{ij}=C^{ijkl} e^{kl}''', reset=True)
        out['invalid_contraction'] = {'accepted': True}
    except Exception as exc:
        out['invalid_contraction'] = {
            'accepted': False, 'exception': type(exc).__name__,
            'message': str(exc)}

    nl.parse_latex(r'''% declare u --dim 3 --suffix dD
q_i=\partial_i(\frac{u^2}{2})''', reset=True)
    expression = globals()['qD'][0]
    out['nonlinear_flux'] = {
        'expression': str(expression),
        'value_with_centered_field_derivative': float(expression.subs({
            globals()['u']: 4, globals()['u_dD'][0]: 16})),
        'whole_flux_centered_value': 80.0}
    return out


def devito_probes():
    import numpy as np
    from devito import (Grid, Function, TensorFunction, Eq, Operator,
                        Derivative, NODE, centered)
    from sympy import ImmutableDenseMatrix
    out = {'coordinates': {}}
    grid = Grid(shape=(5, 5, 5), dtype=np.float64)
    for coordinate in ['cylindrical', 'spherical']:
        strain = TensorFunction(name='e_'+coordinate, grid=grid,
                                symmetric=True, staggered=NODE)
        stress = TensorFunction(name='q_'+coordinate, grid=grid,
                                symmetric=True, staggered=NODE)
        d = [1, 1/1.5**2, 1 if coordinate == 'cylindrical'
             else 1/(1.5*math.sin(1.25))**2]
        for i in range(3):
            for j in range(i, 3):
                strain[i, j].data[:] = E_VALUES[i][j]
        # General tensor contraction expressed with Python's ordinary loops.
        # The coordinate-dependent metric values are input coefficients here.
        G = [[d[i] if i == j else 0 for j in range(3)] for i in range(3)]
        n = [1, 0, 0]
        def constitutive(e, material_direction):
            return ImmutableDenseMatrix(3, 3, lambda i, j: sum(
                (2*G[i][j]*G[k][l] + G[i][k]*G[j][l]
                 + G[i][l]*G[j][k]
                 + 0.5*n[i]*material_direction[j]*n[k]*n[l]) * e[k, l]
                for k in range(3) for l in range(3)))
        rhs = constitutive(strain, n)
        op = Operator(Eq(stress, rhs), opt='noop')
        op.apply()
        values = [[float(stress[i, j].data[2, 2, 2]) for j in range(3)]
                  for i in range(3)]
        out['coordinates'][coordinate] = {
            'max_error': error(values, expected(coordinate)), 'values': values,
            'compiled_c_executed': True}
        if coordinate == 'cylindrical':
            wrong_rhs = constitutive(strain, [0, 1, 0])
            wrong_op = Operator(Eq(stress, wrong_rhs), opt='noop')
            wrong_op.apply()
            out['asymmetric_update'] = {
                'accepted': True,
                'rhs_is_symmetric': wrong_rhs.is_symmetric(),
                'stored_q01': float(stress[0, 1].data[2, 2, 2]),
                'stored_q10': float(stress[1, 0].data[2, 2, 2]),
                'rhs_q01': float(wrong_rhs[0, 1].xreplace({
                    strain[i, j]: E_VALUES[i][j]
                    for i in range(3) for j in range(3)})),
                'rhs_q10': float(wrong_rhs[1, 0].xreplace({
                    strain[i, j]: E_VALUES[i][j]
                    for i in range(3) for j in range(3)}))}
            (WORK/'devito-asymmetric.c').write_text(str(wrong_op.ccode))

    x, y, z = grid.dimensions
    u = Function(name='u', grid=grid, space_order=2, staggered=NODE)
    q = Function(name='q', grid=grid, space_order=2, staggered=NODE)
    u.data[:] = 0
    u.data[1, :, :] = 1
    u.data[2, :, :] = 4
    u.data[3, :, :] = 9
    # Explicit centered selects the same stencil as the Formurae probe.
    derivative = Derivative(u*u/2, x, fd_order=2, side=centered)
    Operator(Eq(q, derivative), opt='noop').apply(h_x=0.25)
    out['nonlinear_flux'] = {
        'expression': str(derivative.evaluate),
        'whole_flux_centered_value': float(q.data[2, 2, 2])}
    # Assign the same explicitly located derivative to a differently located
    # result. This API accepts it; record the generated operation separately
    # from the question of whether a placement mismatch is diagnosed.
    fixed_derivative = Derivative(u*u/2, x, fd_order=2, x0={x:x+x.spacing/2})
    placed_op = Operator(Eq(q, fixed_derivative), opt='noop')
    (WORK/'devito-placement.c').write_text(str(placed_op.ccode))
    out['placement_policy'] = {
        'accepted_explicit_half_location_to_node': True,
        'explicit_derivative_expression': str(fixed_derivative.evaluate)}
    return out


def opensbli_probes():
    sys.path.insert(0, str(WORK/'sources/opensbli'))
    from opensbli import EinsteinEquation
    expression = ('Eq(q_i_j,2*G_i_j*G_k_l*e_k_l'
                  '+2*G_i_k*G_j_l*e_k_l'
                  '+alpha*n_i*n_j*n_k*n_l*e_k_l)')
    equations = EinsteinEquation().expand(expression, 3, 'x', [], ['alpha'])
    out = {'component_equations': len(equations), 'coordinates': {}}
    by_name = {str(eq.lhs): eq.rhs for eq in equations}
    out['coordinates'] = {}
    for coordinate in ['cylindrical', 'spherical']:
        d = [1, 1/1.5**2, 1 if coordinate == 'cylindrical'
             else 1/(1.5*math.sin(1.25))**2]
        values = []
        for i in range(3):
            row = []
            for j in range(3):
                rhs = by_name['q%d%d' % (i, j)]
                substitutions = {}
                for symbol in rhs.free_symbols:
                    name = str(symbol)
                    if name == 'alpha': value = 0.5
                    elif name.startswith('G'):
                        a, b = map(int, name[1:]); value = d[a] if a == b else 0
                    elif name.startswith('e'):
                        a, b = map(int, name[1:]); value = E_VALUES[a][b]
                    elif name.startswith('n'): value = int(name[1:] == '0')
                    else: raise ValueError(name)
                    substitutions[symbol] = value
                row.append(float(rhs.subs(substitutions)))
            values.append(row)
        out['coordinates'][coordinate] = {
            'max_error': error(values, expected(coordinate)), 'values': values,
            'stage': 'expanded symbolic equations'}
    EinsteinEquation().expand(expression.replace('n_i*n_j','n_i*m_j'),
                              3, 'x', [], ['alpha'])
    out['asymmetric_update'] = {
        'accepted_as_full_tensor': True,
        'symmetric_output_declaration_in_this_api': False}
    try:
        EinsteinEquation().expand('Eq(q_i_j,C_i_j_k_l*e_k_m)',3,'x',[],[])
        out['unbalanced_indices'] = {'accepted': True}
    except Exception as exc:
        out['unbalanced_indices'] = {
            'accepted': False, 'exception': type(exc).__name__,
            'message': str(exc)}
    flux = EinsteinEquation().expand('Eq(q_i,Conservative(u*u/2,x_i))',3,'x',[],[])
    out['nonlinear_flux'] = {'expression': str(flux),
                             'stage': 'unexpanded conservative derivative'}
    return out


def nrpyplus_probes():
    sys.path.insert(0, str(WORK/'sources/nrpyplus'))
    import grid
    import finite_difference as fd
    import NRPy_param_funcs as par
    from outputC import lhrh
    from sympy import Symbol
    grid.register_gridfunctions('EVOL', ['u', 'F'])
    par.set_parval_from_str('finite_difference::FD_CENTDERIVS_ORDER',2)
    generated = fd.FD_outputC('returnstring',
                             [lhrh(lhs='q',rhs=Symbol('F_dD0'))],
                             params='outCverbose=False')
    (WORK/'nrpyplus-flux.c.inc').write_text(generated)
    return {'materialized_flux': {
        'generated_centered_difference': 'i0-1' in generated and 'i0+1' in generated,
        'input_grid_function': 'F',
        'required_computation': 'fill F = u*u/2 before evaluating its derivative',
        'kernel': generated}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('system', choices=['nrpylatex', 'devito', 'opensbli', 'nrpyplus'])
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    from importlib.metadata import version
    packages = ['sympy', 'numpy']
    if args.system in ['devito', 'nrpylatex']: packages.append(args.system)
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        result = globals()[args.system+'_probes']()
    report = {'system': args.system, 'python': sys.version.split()[0],
              'packages': {p: version(p) for p in packages}, 'results': result}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    args.output.with_suffix('.log').write_text(log.getvalue())
    print(json.dumps({'system': args.system, 'output': str(args.output)}))


if __name__ == '__main__':
    main()
