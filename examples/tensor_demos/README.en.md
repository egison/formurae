# Tensor PDE demos on cylinders and spheres

[English gallery](../../html/en/gallery.html#tensor-demos) · [日本語の説明](README.md)

Three applications produce four detailed animations and three introductory views:
press, twist, and stir. Every frame comes from a saved
numerical state, with fixed cameras and colour scales throughout the movie.
After rendering, the [animation checks](results/animation-validation.json) verify
continued changes in the surface images before clock/caption overlays, along
with MP4/GIF frame counts and file hashes.

Start with [three familiar actions](../../html/en/gallery.html#tensor-intro).

| Action | Source | View |
|---|---|---|
| Press a hollow ball, then let go | [press_ball.fme](press_ball.fme) | The orange patch dents and recovers; vibrations reach the opposite side. Displacement magnified 8 times. |
| Twist a tube, then let go | [twist_tube.fme](twist_tube.fme) | Fix the bottom and turn the top. Follow the twisting material lines. Displacement magnified 6 times. |
| Stop stirring a liquid | [oldroyd_couette.fme](oldroyd_couette.fme) | Liquid markers reverse after the cylinder stops. Displacements are unscaled. |

In [the liquid view](../../html/en/gallery.html#recoil-intro),
Moving markers reveal the sequence: turn the cylinder, stop it, and watch the
liquid briefly reverse. This is another view of the same viscoelastic simulation
described below. Saved velocities are interpolated linearly in time and space;
48 marker paths are integrated with fourth-order Runge–Kutta. Displacements are
not magnified, and the entire clip plays at approximately half speed. Arrows
indicate direction only. The clip covers the first reversal, at `t=11…17.4`.
The [record](results/couette-recoil.json) checks that the cylinder remains still
after `t=14` and compares marker paths after halving the integration step.
Rendering the Japanese version requires a Japanese font such as Hiragino Sans
or Noto Sans CJK JP.

| Application | Formurae source | What to observe |
|---|---|---|
| Anisotropic elasticity | [Cylinder](anisotropic_cylinder.fme), [hollow sphere](anisotropic_sphere.fme) | Different vibrations of an isotropic material and a radially reinforced material with the same initial velocity |
| Viscoelastic Taylor–Couette flow | [Rotating annulus](oldroyd_couette.fme) | Transport and deformation of polymer stress, followed by relaxation when the inner cylinder stops |
| Nematic liquid crystal | [Complete sphere](nematic_sphere.fme) | Relaxation of molecular alignment and motion of orientation defects |

## Reproduction

Use the repository's Cabal environment, a C compiler, `bin/formura` from
`make setup`, and the adjacent Egison Git repository. The existing
`tools/prepare_elastic_validation.sh` selects a fixed Egison commit. Python
3.11 or newer and an off-screen VTK rendering environment are required.

```sh
python3 -m venv .build/tensor-demo-venv
.build/tensor-demo-venv/bin/pip install -r examples/tensor_demos/requirements.txt
make tensor-demos TENSOR_PYTHON=.build/tensor-demo-venv/bin/python
```

This runs checks, all six simulations, and MP4/GIF/PNG rendering serially.
Individual stages are `tensor-demo-checks`, `tensor-demo-simulate`, and
`tensor-demo-render`. These are separate from the existing `make all` examples.
The generated `.egi`, `.feir`, and `.fmr` files are kept alongside the models;
`results/` contains numerical records, `gallery/tensor/` contains movies, and
`.build/tensor-demos/` contains generated C, libraries, and time-series data.
Reports record source and generated-C SHA-256 hashes at execution time.

## Equations and implementation

The metric `g` describes lengths and angles in a coordinate system. Covariant
derivatives `∇` include the spatial variation of the coordinate basis. Upper
and lower indices denote contravariant and covariant components; repeated
upper/lower indices are summed. A declaration such as `{~i~j}` specifies
symmetry under index exchange.

The `.fme` files define strain, stress divergence, tensor transport, derivatives,
and contractions as ordinary user functions. No operator-specific compiler
rules are added. Formurae, Egison, and Formura generate the C spatial kernels.
For viscoelastic flow, the user writes one `.fme` file containing equations,
initial conditions, physical parameters, time updates, wall values, and the
execution order. `formurae run` validates it, generates C, and runs the result.
A generic C runtime supplies array means, ghost-cell transfers and the Poisson
solve. Python visualizes saved results. See the [execution specification](../../docs/native-execution.md).

```sh
formurae run examples/tensor_demos/oldroyd_couette.fme
```

Generated C and the executable are written to `oldroyd_couette.native/` next
to the input; snapshots and the report go in its `output/` subdirectory.
The user does not write C or Python. For gallery reproduction, use
`make couette-check`, `make couette-simulate`, and `make couette-render`.
The first two commands do not invoke Python. Archived stages are in
`generated/oldroyd_couette/`.
The [comparison with previously saved results](results/couette-native-regression.json)
records the numerical agreement with the former driver.

The elastic and nematic demos continue to use Python for time integration,
boundaries, and exchange between coordinate panels.

### Pressing, twisting, and release

`press_ball.fme` and `twist_tube.fme` use the three-dimensional velocity and
symmetric-stress equations in the next section, with `λ=2, μ=1, ρ=1, α=0` for
isotropic linear elasticity. Generated C computes spatial operators;
`tools/tensor_demo_manipulation.py` supplies moving boundary grips and time
integration. Colours identify material markers; no stress or velocity scale is
needed to read the introductory animations.

The complete hollow sphere has radii 1–2 and starts at rest. A patch of the outer
surface, centred on +x with angular radius 0.65, receives a prescribed normal
displacement. It tapers smoothly to zero at the patch edge. The central depth is
`0.035 s(t/1.5)`, where `s(x)=10x³−15x⁴+6x⁵`. At `t=1.5` the grip is released
and every surface becomes traction-free. The grip is idealised as a prescribed
normal displacement. There are 17 radial points and angular resolution 48;
the run continues to `t=9`. Cutting away a 90-degree sector changes only the view;
the entire inner and outer spherical surfaces are part of the simulation.

The tube has radii 1–2 and finite length `2π`. The lower end is fixed. The upper
end turns through `0.065 s(t/4)`, imposed through its tangential velocity.
At `t=4` the upper end becomes traction-free while the bottom remains fixed.
Both sidewalls are also traction-free. The grid has 17 radial, 48 circumferential,
and 25 axial points; the run ends at `t=22`. The axial direction is not periodic.

Time integration uses four-stage Runge–Kutta. Free-surface stresses and their
rates are projected orthogonally in the elastic-energy inner product. At edges,
both intersecting free-surface constraints are solved together. The release
projection is checked not to increase energy. The tube is checked against the
fixed/free torsional mode
`uθ=a r sin(kz) cos(kt), σθz=a k r cos(kz) cos(kt), k=1/4`, in an orthonormal
basis, with shear speed `sqrt(μ/ρ)=1`. Spatial convergence, boundary constraints,
finite values, and energy variation after release are recorded in
[validation](results/manipulation-validation.json), [ball](results/press-ball.json),
and [tube](results/twist-tube.json).

Prescribed grip displacements are reapplied after coordinate interpolation.
The last stage up to the release time uses the loading boundary condition;
the grip is released immediately afterwards. Refinement in time across this
switch and an exact torsional transient are checked in the
[time-accuracy record](results/manipulation-time-validation.json).

### 1. Radially reinforced elastic materials

\[
 \rho\partial_t v^i=\nabla_j\sigma^{ij},\qquad
 e_{ij}=\tfrac12(\nabla_i v_j+\nabla_j v_i),
\]
\[
 \partial_t\sigma^{ij}=\lambda g^{ij}g^{kl}e_{kl}
 +2\mu g^{ik}g^{jl}e_{kl}+\alpha n^in^jn^kn^le_{kl}.
\]

Here `n` is the radial unit vector. Both materials have `ρ=1, λ=2, μ=1`;
`α=0` and `α=6` compare isotropy with extra radial stiffness. This specifies a
fourth-order elasticity tensor without enumerating its components. The
`strain`, `stressRate`, and `stressDiv` definitions are the same in both geometries.

The inner and outer radii are 1 and 2, with zero traction at both surfaces.
The cylinder is periodic in its axial direction, with period `2π`; its displayed
ends are not free ends. The spherical domain includes both poles. Initial
stress and displacement are zero; velocity has smooth angular dependence and
three nonzero components. There are 17 radial points, 48 circumferential and
24 axial points for the cylinder, and two 33×81 angular panels for the sphere.
Fourth-order Runge–Kutta integration uses `dt=0.005` up to `t=5`.

Movies cut away half the body and colour the opaque outer, inner, and cut
surfaces by speed. Displacement is magnified eight times. Cutting is a
rendering operation and introduces no simulation boundary.

Checks transform affine Cartesian velocity and constant Cartesian stress into
the curvilinear basis and compare generated kernels with independent component
formulas and analytic values. Radial subdivisions 8, 16, and 32 measure spatial
convergence. Every saved animation frame is checked for finite values, zero
surface traction, and kinetic-plus-elastic energy variation.

### 2. Viscoelastic rotation and stopping

The Oldroyd-B model couples solvent viscosity to a symmetric positive-definite
conformation tensor `C`, describing polymer deformation. Its equilibrium value
is the inverse metric. Positive definiteness means positive extension in every
direction.

\[
 \nabla_i v^i=0,\quad
 \rho(\partial_t v^i+v^j\nabla_jv^i)
 =-\nabla^ip+\nabla_j(2\eta_s e^{ij}+\tau^{ij}),\quad
 \tau^{ij}=\frac{\eta_p}{\lambda_r}(C^{ij}-g^{ij}),
\]
\[
 \partial_tC^{ij}+v^k\nabla_kC^{ij}
 -C^{kj}\nabla_kv^i-C^{ik}\nabla_kv^j
 =-(C^{ij}-g^{ij})/\lambda_r.
\]

The connection terms cancel in this transport-and-stretching combination,
allowing `upperConvectedRHS` to use partial derivatives and index contractions.
Curvature remains in the metric-dependent momentum equation and stress divergence.

A two-dimensional annulus of radii 1 and 2 has inner-wall speed 1 and a fixed
outer wall. The inner cylinder slows smoothly during `t=12…14`, then remains
stationary. Parameters are `ηs=0.04, ηp=0.16, λr=1.5, ρ=1`. Small smooth
angular variations in velocity and polymer orientation perturb exact steady
Couette initial data. There is no axial variation. The grid has 49 radial and 128 angular points;
`dt=1/3840` advances to `t=24`.

Velocity is reconstructed using vorticity and a streamfunction, a scalar whose
derivatives give divergence-free velocity. The azimuthal mean is evolved
separately to retain circulation in the annulus. Wall vorticity is determined
from the streamfunction and prescribed velocity. Generated upwind transport,
congruence transformations `F C Fᵀ` for stretching, and convex relaxation towards
identity preserve positive definiteness. The split time integration is first
order; it does not clip negative eigenvalues. The `.fme` velocity stage supplies
absolute coordinate velocities as the numerical transport coefficients. All
physical parameters, including relaxation time, come from `.fme` declarations.

The analytic steady benchmark is `vθ=(4/r−r)/3`, with physical orthonormal
components `Crr=1, Crθ=λr γ, Cθθ=1+2(λr γ)², γ=−8/(3r²)`.
Checks compare transport and tensor evolution with independent component
formulas, measure spatial and time convergence, and monitor velocity divergence
and the smallest conformation eigenvalue at every saved frame. Movies show
polymer stress, velocity arrows, the mean velocity profile, and kinetic-plus-
polymer energy through drive cessation and relaxation.

### 3. Orientational relaxation on the complete sphere

In a nematic liquid crystal, molecular orientations `d` and `−d` are equivalent.
A symmetric, trace-free tangent tensor `Q` represents alignment and orientation.
The intrinsic surface Landau–de Gennes relaxation model is

\[
 \partial_tQ^{ij}=\mathcal P_0[
 L\nabla^k\nabla_kQ^{ij}+(A-BQ_{kl}Q^{kl})Q^{ij}],
 \quad L=0.02,\ A=1,\ B=2.
\]

The projection `𝒫₀` removes the metric trace. This passive orientational model
has no coupled ambient fluid or active stress. User functions compose the
connection, rank-two covariant gradient, rank-three derivative and contraction,
and trace removal.

A smooth global Cartesian matrix field is projected onto the tangent plane to
create initial data. Two overlapping spherical-coordinate panels (a Yin–Yang
grid) cover the poles without singular coordinate lines or holes. Both tensor
indices are transformed at donor points before interpolation into the other
panel. Each panel has 33×81 points; a second-order Runge–Kutta method advances
from `t=0` to `t=30`.

The animation presents front and back views simultaneously. Colour denotes
alignment strength, unoriented line segments show the molecular director, and
cyan markers show defects detected from the winding of the computed `Q` field.
No marker motion is prescribed.

For validation, projecting a constant Cartesian symmetric matrix onto tangent
planes and removing its trace produces an analytic tensor mode with
`∇ᵏ∇ₖQ = −2Q`. Subdivisions 24, 48, and 96 measure convergence and comparison
with independent component formulas. The simulation checks finite values,
zero trace, bounded alignment, total defect charge `+2`, and records free energy.

## References

- [Review of the Oldroyd-B model](https://arxiv.org/abs/2202.08305).
- [Curvature and viscoelastic instability](https://arxiv.org/abs/1806.00328).
- [Tensor models for spherical nematics](https://www.nature.com/articles/ncomms13483).
- [Vorticity boundary conditions](https://www.sciencedirect.com/science/article/pii/S0021999196900662).

These sources provide physical and numerical background; they are not reference
runs under all the same settings. Results specific to this implementation are
recorded in `results/`.
