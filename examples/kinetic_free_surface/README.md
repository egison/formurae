# Moving free surface with continuous D2Q9 transport

This experiment couples D2Q9 (two spatial dimensions, nine discrete velocities)
to a moving water fraction using finite-volume transport (shared face fluxes). It is under development; completion of the breaking-wave and
shoreline-retreat checks must be established by the saved verification results.

All physical calculations, initialization, geometry, boundary reconstruction,
time integration, wetting/drying and diagnostics are in
`kinetic_free_surface.fme`. Python controls the normal compiler pipeline and
renders saved fields. C only passes configuration, calls the generated solver
and writes generated diagnostics and fields.

## Current checks and remaining target

The numerical results below describe the eight-phase MC reference version
(MC limits each extrapolated cell slope using its neighboring differences)
(source SHA-256 `807242cd97a480543669873877f84572258d39a5e8c2ac9cd26b012cabfc5c68`).
The current candidate adds sharper fraction transport and a standing-wave
initial pressure profile; it is being rebuilt and needs its own regression
and physical checks. The previous eight-phase reference matched all five saved
fields and all physical diagnostics of its six-phase predecessor exactly in a
two-time-unit pressure-control run.

The 64×64 Cartesian/curved-grid foundation suite currently passes ten cases:
stationary water, uniform transport, time-resolved collision relaxation and
its half-timestep comparison, two fast-relaxation cases, and two shear-wave
viscosities. The measured collision error falls by a factor 0.24997 when the
timestep is halved. At `tau=0.0006`, the shear decay differs from the continuum
reference by 3.49%. These checks do not establish accuracy of a breaking wave.

The earlier six-phase 64×64 dam-collapse calculation (`scenario=3`, `g=0.04`, `H=0.1`, height
increment 0.3, initial front X=0.4, `tau=0.0006`, duration 8) preserves water
mass to relative 1.73e-15. The raw fraction stays between 0 and 1+2.44e-13,
and the largest retained liquid speed is 0.274. Its downstream wall is part
of that test; it is not used to demonstrate shoreline retreat.

Separate standing-wave tests at 64×64, `tau=0.0025` and `timeScale=2`
have not passed the fixed 5% period criterion. With shared surface heights,
amplitude 0.03 gives a measured period 15.9903 versus reference 17.7577
(9.95% discrepancy); amplitude 0.003 gives 19.3065 (8.72%). Both pass the
basic conservation and fraction-bound checks. The older per-face height
method at amplitude 0.03 gave 5.71% discrepancy. The surface develops
additional structure, and the local height gauge and whole-domain cosine
moment do not give the same return time. Waveform, period measurement and
mesh refinement therefore still need an accuracy study. These failed checks
are not counted among the passing foundation cases.

On the fitted beach (160×64 cells, physical domain 6.4×0.8, bed slope 0.1,
`H=0.2`, `g=0.08`, `tau=0.0006`, `timeScale=2`, duration 2), shared heights
reduce the largest spurious speed in still water from 0.00334349 in the older
per-face version to 0.000306894. This passes the fixed 0.001 speed criterion.
Water mass changes by relative 6.27e-16; the integrated fraction change is
4.29e-6. The fitted-beach equilibrium is therefore approximate, unlike the
flat reference equilibrium. This short check does not establish long-time
rest or wave accuracy.

The target remains a connected curling crest, a cavity, impact, runup and
retreat of the shoreline including the thin-water contour. A positive
`overhangCells` count alone does not establish this sequence. The fitted-beach
reference trial with shared heights (`A=0.12`, slope 0.1) was stopped at
`t=28.3371`: its thin-water front reached X=6.37975, next to the far wall at
6.4, and no connected curl had appeared. Basic conservation/bounds passed,
but stages 5 and 6 did not. The earlier steep-beach trial also reached the far
wall and left a thin layer there. Neither is an accepted beach example.

Reproduce the foundation checks after building the 64×64 MPI executable:

```sh
EGISON_HEAP_LIMIT=9G python3 examples/kinetic_free_surface/run.py --normalize --grid 64 64 --mpi 2 2
python3 examples/kinetic_free_surface/foundation.py --mpi 2 2
```

The suite runs its cases sequentially and writes the complete results to
`.build/kinetic-free-surface/grid-64-64-mpi-2-2/foundation.json`. On the current
Mac, set the MPI environment variables documented below first.

## Current candidate foundation result

The fraction-transport candidate (`aa8b7793a58415dbb6579b533be332efd8a846a067a0ee17de808612d7127ba2`),
archived before the boundary correction, passed the ten foundation cases on 160×64 cells, physical domain 6.4×0.8,
with `method=2`, `heightMethod=2` and MPI 2×2. Halving the collision timestep
reduces its measured error by a factor 0.249954. The low-viscosity shear decay
error is 2.795%. This suite uses `timeScale=1`, a level plane at H=0.4 and no
sloping bed; the beach's timestep and sloping rest are separate checks.

The unchanged-physics beach control (`method=1`, t=1.98857) matches the
previous eight-process reference in all five saved fields exactly. The largest
aggregate diagnostic difference is 7.77e-16. Four processes took 90.94 seconds
for that control; no speedup is established by that comparison.

```sh
python3 examples/kinetic_free_surface/run.py --grid 160 64 --length 6.4 .8 --mpi 2 2
python3 examples/kinetic_free_surface/foundation.py --grid 160 64 --length 6.4 .8 --mpi 2 2 --method 2
```

These results are archived in
`.build/kinetic-free-surface/before-column-boundary/grid-160-64-mpi-2-2/foundation.json` and
`.build/kinetic-free-surface/before-column-boundary/superbee-control-comparison.json`. The current-source fitted-bed rest also passes (peak unwanted speed
0.000306341), and the actual beach timestep passes the shear test (decay
error 2.785%). The incoming-wave comparison stopped at t=19.2229 after its crest ran ashore
without a connected curl or cavity. Basic conservation/bounds passed (relative
mass change 3.15e-15), but stage 5 was not achieved. This interrupted trial
does not establish stage 6. Standing-wave accuracy still requires current-source
results; a detached-layer gravity diagnostic is being investigated separately.

## Detached-layer pressure defect and candidate correction

A diagnostic copy of the fraction-transport candidate changes only its initial
state to a horizontal detached layer with density one and zero velocity, and
adds analytic free-fall references in FME. It uses the same transport,
collision, gravity, boundary reconstruction and air extension. At 32×32,
a layer occupying one quarter of a single row accelerates **upwards** with
`heightMethod=2`: its first-step vertical momentum is +1.30209e-7 versus the
reference -2.60417e-7. A three-quarter-cell layer falls at approximately half
the correct acceleration. A resolved three-cell layer is much closer, with
relative momentum error 9.58e-6 after 100 steps. Fixing atmospheric pressure
on the numerical faces gives relative momentum errors about 3e-7 for all
three thicknesses. This isolates a pressure-boundary defect. Its contribution to the failed
curling wave still needs to be established by a new wave calculation. The
discrete boundary-stress residual can be near roundoff even with this defect:
that residual checks the chosen pressure condition, not whether the interface
location or resulting net force is physically correct.

The private diagnostic sources, normal-pipeline outputs and all six case
histories are saved under `.build/kinetic-free-surface/falling-layer-probe/`.
The current main candidate adds this test as `scenario=7`, with layer centre
`level` and thickness `amplitude`. Its analytic momentum and centroid moment
are new FME diagnostics, computed at the same physical time as the observed
state. `falling.py` checks momentum and centroid-displacement errors against a
fixed 2% limit, includes a thicker layer whose ends cut through cells, and retains the old boundary as an explicitly failing control.

The `heightMethod=3` trial accepts a height only from a monotone column with
full/empty ends and stops each column at the first wall. Its four stationary
and uniform-transport checks pass on Cartesian and curved grids. However,
the 32×32 falling-layer suite **fails**: the quarter-cell layer's centroid
error is 3.85%, and the aligned three-cell layer's maximum momentum error is
17.37%. The thicker partial-cell layer has 13.34% momentum error. All results
and sources are archived under `.build/kinetic-free-surface/before-dynamic-pressure/`.
Pressure-on-face control reduces the thick-layer momentum error to 7.38e-7
and its centroid error to 0.269%, but thin-layer centroid errors remain.

The current candidate tests two separate changes. `heightMethod=4` estimates
the gradient of log density from neighboring liquid samples in physical
coordinates, rather than assuming hydrostatic pressure during motion. An affine
least-squares fit uses both X and Y; insufficiently supported fits retain the
hydrostatic slope. The pressure at the reconstructed surface remains atmospheric.
Unsupported height columns retain direct atmospheric pressure at the face.
`heightMethod=5` additionally uses the equilibrium distribution as the numerical
flux state at a water/air face. This imposes atmospheric stress and mass flux
consistent with the extrapolated liquid velocity. A new FME diagnostic measures
that mass-flux consistency separately from the stress residual. Modes 2 and 3
are retained as experimental controls, not as compatibility paths.

An additional `method=3` comparison keeps the Superbee fraction slopes where
the cell or a face neighbor is full, and uses constant reconstruction where
all these cells are partial or empty. Population reconstruction remains MC.
This tests unresolved-layer transport without changing the pressure algorithm.
`falling.py` runs the four required layers with `method=4`, and as controls the
same thick layer with `compression=8`, the previous `method=3` transport, the
incoming-only boundary flux (`heightMethod=4`), ordinary Superbee, first-order
transport and the old boundary that reproduces the upward acceleration; every
failure is recorded.

With `method=4` (below) the falling suite passes; the `heightMethod=4` variant
with the new transport also passes the thick layer (8.4e-4), so the remaining
thick-layer error was the fraction transport, not the pressure flux. The fixed
2% momentum/centroid criteria are unchanged. Stages 5 and 6 are not achieved
by these tests. The parameter count is 26 (`compression`, `launch`), there are
eight generated phases per physical timestep, and all new calculations are in FME.

```sh
EGISON_HEAP_LIMIT=12G python3 examples/kinetic_free_surface/run.py --normalize --grid 32 32
python3 examples/kinetic_free_surface/falling.py
```

## Thick partial-cell layer: transport, not pressure

With `heightMethod=5` and `method=3` the falling suite passed the quarter-cell,
three-quarter-cell and aligned three-cell layers but failed the thick layer with
partially filled end cells (0.32 thick, end fractions 0.3): its centroid drop was
2.96% smaller than the analytic drop while its momentum matched to 1e-5. A
one-dimensional emulation of the fraction transport alone (uniform velocity
`-g t`, density one, the same reconstruction formulas and Heun steps) reproduces
the model's end-cell fractions (0.0013, 0.3737 | 0.9474, 0.2776) and the -2.96%
exactly, so the kinetic part is not involved. The cause is the reconstruction:
Superbee gives an outflow face value of `2*alpha` for an end cell with `alpha <
1/3`, so the upper end cell (water held against the full cell below it) drains at
60% of the correct rate while the cell below loses fraction, and the layer's top
smears.

The plain cell-centre moment is also not a valid measure of that layer. If the
transport were exact, the end fractions would become 0.375 and 0.225 and the
measured first moment would change by `(N+1)/(N+a_b+a_t) = 10/9.6`, i.e. 4.17%
more than the analytic moment, because the water of a partially filled cell is
counted at the cell centre. The emulation confirms +4.17% for exact transport.
Both findings are addressed below: `method=4` transports such end cells exactly,
and `resolvedCentroidY` measures the moment with the sub-cell water position.

## Equations and coordinates

The nine velocities are vectors in a fixed physical orthonormal basis. Their
flux through each computational face is their scalar product with that face's
oriented physical area vector. Both Cartesian and smoothly curved grids use the
same transport, collision and boundary equations. The coordinate map places
the inner side-wall faces at X=0 and X=lengthX and the top at Y=lengthY.
With `fittedBed=1`, the bottom face follows `bedSlope*max(X-bedStart,0)`;
`fittedBed=0` retains the staircase-mask control. These physical dimensions and the initial water depth therefore
remain fixed when the number of cells changes. The outer array cells hold the
wall; the remaining cells cover the specified physical tank. Sampling the two sides of a
face uses `sampleLower` and `sampleUpper`; the model does not require exact
lattice-cell streaming.

The state is the deviation `h_a = f_a - w_a rho_H` from a hydrostatic reference,
where `rho_H = exp(3 g (H - Y))`. Its equation is

```
d_t h_a + div(c_a h_a)
  = (f_eq(rho,u)_a - w_a rho_H - h_a) / tau
    + S_a(rho,u) - S_a(rho_H,0).
```

Subtracting the analytic hydrostatic balance avoids a residual gravity force
from differentiating an exponential on the mesh. The density and momentum are
`rho = rho_H + sum(h_a)` and `rho u = sum(c_a h_a)`.

The conserved water mass in a cell is `m = rho alpha`, where `alpha` is its water
fraction. The sum of the actual distribution fluxes supplies the mass flux used
to transport `m`. A predictor and corrector advance the distributions and water
mass using the same two evaluations of those face fluxes. Each stage uses four
generated phases: estimate surface heights from the current fraction, store
its right-hand side, solve local collision and extend the air state, and
refresh density, velocity and fraction. Thus eight generated updates complete
one physical timestep. Storing the candidate
avoids expanding all nine population equations again in every wet/dry test.
No global mass correction or removal of thin water films is part of this model.

With `boundarySlope=1`, an outgoing distribution next to air or a wall is
extrapolated to the face using the difference to the next liquid cell inside
the domain. The projected air state does not supply the slope of a liquid
distribution. Interior cells still use the limited MUSCL reconstruction.
`boundarySlope=0` retains the two-sided reconstruction as a control. This
extends the boundary reconstruction used in `kinetic_surface`; it does not
establish second-order accuracy of the complete moving-interface model.

## Local implicit collision

`collisionImplicit=0` uses explicit SSPRK2 (two-stage, second-order
Runge–Kutta integration). The default `collisionImplicit=1` combines explicit
Heun transport with a backward-Euler collision predictor and a trapezoidal
collision corrector. Let `T(h)` denote transport plus gravity,
`E(h)=f_eq(rho(h),u(h))-w*rho_H`, and `C(h)=(E(h)-h)/tau`. For `r=dt/tau`,
the two stages are

```
p = h_n + dt*T(h_n),
h_star = (p + r*E(p))/(1+r),
q = h_n + dt/2*(T(h_n) + C(h_n) + T(h_star)),
h_next = (q + r/2*E(q))/(1+r/2).
```

Collision preserves density and momentum. Consequently, the equilibrium in
each implicit stage is known from its stored right-hand side, and the solve
is algebraic and local to one cell. No global equation solve is introduced.
Water mass uses the explicit Heun update with the same two mass fluxes; its
density pairing is preserved because collision does not change density.
The air projection is applied after each collision solve. `originalFraction`
retains the initial fraction for wetting/drying diagnostics, independently of
the right-hand side retained in `original_a`.

The trapezoidal collision step is second order but does not remove a very
fast transient in a single large timestep. It can alternate about equilibrium
when `dt > 2*tau`; positivity and accuracy are not guaranteed for arbitrary
timesteps. A spatially uniform relaxation case (`scenario=6`) compares the
computed stress with its exact exponential decay. A periodic weak shear wave
(`scenario=5`) compares velocity with the hydrodynamic viscosity `tau/3`.
Timestep refinement, retained-population positivity and the wave checks remain
necessary before using shorter relaxation times in the beach calculation.
For the shear test, the verifier checks both the final amplitude and the amount
of decay against the reference. A small absolute amplitude error alone can
hide a large error in weak damping on a coarse grid.

## Moving pressure boundary

A cell is active liquid when `alpha >= wetFraction` (default 0.01).
The 0.5 cutoff remains available as a control. Keeping partially filled cells
active lets their momentum respond to gravity while a thin layer drains.
This cutoff is a numerical parameter, and sensitivity to it must be tested. On a face between active liquid and
air, the incoming distribution is reconstructed from the outgoing opposite
population and the two equilibrium populations at the boundary density:

```
f_in,a = f_eq,a(rho_face,u_liquid) + f_eq,opposite(a)(rho_face,u_liquid)
           - f_out,opposite(a).
```

For `heightMethod=0` or `1`, the `surfacePosition=0` control fixes atmospheric
pressure on the numerical face. With `surfacePosition=1`, pressure is extended hydrostatically from the
estimated interface to that face. `heightMethod=0` is the original two-cell
control:

```
delta_Y = sign(active_left - active_right)
          * (alpha_left + alpha_right - 1) * (Y_right - Y_left).
```

The default `heightMethod=1` uses a height function: it sums the water fractions
in a short column to estimate the interface position. Four cells on each side
of the face give

```
S = sum(alpha_left[k] + alpha_right[k], k=1..4),
delta_Y = sign(active_left - active_right) * (S-4) * (Y_right - Y_left),
rho_face = exp(3*g*delta_Y).
```

This column is used only when fractions are monotone (within 1e-9) and its ends
are full/empty to within 0.001. Other faces, including nearby multiple interfaces,
use the two-cell estimate. Solid cells count as full only for this geometric
extension; no water mass is added to them. For modes 0 and 1, `heightReconstructions` counts uses of this column and
`surfaceReconstructions` counts all free-surface face evaluations. In mode 2,
`heightReconstructions` still counts eligibility of these original face columns;
it does not measure coverage of the shared-height reconstruction.
On a Cartesian horizontal interface the column accounts for water spread across
several cells, unlike the two-cell formula. On a curved mesh the local physical
centre displacement approximates the column geometry, so refinement and chart
comparisons remain necessary. This is not a polygonal interface reconstruction.

The experimental `heightMethod=2` requires `surfacePosition=1` and shares reconstructed surface heights between
adjacent pressure faces. A computational column is eligible when its physical
direction is closer to gravity than to the horizontal. It uses a monotone
eight-cell profile, or the local two-cell interface when the wider profile is
unavailable. Oppositely oriented interfaces in the same short column are not
combined. Eligible column estimates give a cell height and orientation;
adjacent cells with compatible orientations supply the face height. The
pressure density is then `rho_H(face)*exp(3*g*(height-H))`. Faces without a
usable height retain the original estimate. This permits local overhangs;
it does not impose a single height over the whole water surface.

These heights are computed and stored before each right-hand-side evaluation.
They are not recomputed from an out-of-date predictor state. Their definition
uses physical geometry to choose between the computational axes. This avoids
using a nearly horizontal sampling direction to infer the height of a flat
water surface. A separate static geometry probe eliminates the pressure error
on the fitted, unwarped beach and reduces it on a further warped grid. Full
flow, conservation, waveform and chart tests are still required. This is not
a polygonal reconstruction of the interface or a proof for arbitrary maps.
`heightMethod=1` remains the default reference until those checks pass.

The kinetic stress is tested against the corresponding equilibrium stress at
each wet–dry face. The air-side
state is an extension of atmospheric equilibrium and nearby water velocity; it
does not represent a second fluid with its own inertia. Newly wetted cells use
the transported state. Solid faces have zero normal water flux. `wallSlip=0` reverses the outgoing
populations and stops tangential motion as well. The default `wallSlip=1` adds
a correction that cancels tangential momentum flux (a slip boundary). The fitted bottom uses the actual inclined cell faces; its
solid mask occupies the outer array row. Cell areas come from the four physical
vertices, so both the flat tank and the fitted bottom use the same flux equations.

The moving surface is represented through faces separating the two cell
classes, together with the offset above. Resolution and coordinate-map
comparisons are required. This is not a geometrically reconstructed
volume-of-fluid boundary. Air compression, surface
tension and unresolved droplets are outside this experiment.

## Development checks

1. Static water and uniform translation, including a curved grid.
2. Gravity-driven oscillation of a small surface disturbance.
3. Large deformation and impact in a dam-break problem.
4. A traveling elevation approaching a sloped bed.
5. A connected overturning crest, enclosed cavity and impact.
6. Runup followed by offshore flow and retreat of the actual shoreline.

Each moving-interface run must also report mass conservation, raw fraction
bounds, positive density/populations, wetting/drying and the resolved speeds.
Shoreline retreat must be measured from the computed water fraction rather than
inferred solely from an offshore velocity or achieved by rendering a thin film
invisible.

## Development commands

The current full normalization uses an explicit 9 GiB heap cap, above this
runner's default 5 GiB. Run the compiler by itself:

```sh
EGISON_HEAP_LIMIT=9G python3 examples/kinetic_free_surface/run.py --normalize --grid 32 32
python3 examples/kinetic_free_surface/experiment.py rest-cart --duration 2
python3 examples/kinetic_free_surface/verify.py .build/kinetic-free-surface/grid-32-32/rest-cart/result.json --case rest
```

The grid and physical lengths passed to `experiment.py` must match the
executable generated by `run.py`. Saved fields and diagnostic histories are
kept under `.build/kinetic-free-surface/`; the development runner draws six
snapshots from those saved fields.

The existing Formura MPI backend can divide the same domain between processes:

```sh
python3 examples/kinetic_free_surface/run.py --grid 32 32 --mpi 2 2
python3 examples/kinetic_free_surface/experiment.py mpi-check --grid 32 32 --mpi 2 2 --scenario 2 --tau .0025 --duration .4 --reports 20
```

The grid and lengths supplied here describe the whole domain. The build script
passes the per-process sizes to Formura and uses `mpicc`; `mpirun` starts the
generated solver. Geometry, boundary conditions and all updates remain in the
same FME program. Rank zero writes the generated global diagnostics. The field
recorder gathers disjoint pieces of saved fields and checks that every global
cell has exactly one owner before writing a frame. This gathering is output
assembly only. Serial/MPI field and diagnostic comparisons are required before
using this path for refined wave calculations.

## Diagnostic definitions

`wetFront` is the furthest physical X of a cell with fraction at least 0.5
and a solid neighbour below it. `bulkFront` also requires the cell above
to have fraction at least 0.5. `thinFront` uses fraction greater than 0.01,
so a retreat of the 0.5 contour cannot hide a persistent thin layer. These
are cell-resolution measurements; the use of the neighbouring logical row
must be considered when comparing strongly distorted grids.
`shoreWaterMass` is all water mass shoreward of the initial physical waterline
on the slope, including fractions smaller than either front threshold.
`thinWaterMass` is mass in every cell with fraction strictly between 0 and 0.5.
`resolvedCentroidY` is the first moment of water mass in which the water of an
interface cell held against a fuller vertical neighbour (the `method=4` rule,
weighted by the vertical alignment of the fraction gradient) is placed at the
centre of the part of the cell it occupies, `(1-alpha)/2` of the distance to that
neighbour away from the cell centre; `waterCentroidY` keeps the cell-centre
moment. The falling verifier compares `resolvedCentroidY` for a layer that
contains a full cell and `waterCentroidY` for a layer thinner than one cell,
whose sub-cell position no cell-average measure can infer; both errors are
recorded for every case.
`shoreFlux` is an area-integrated offshore/onshore momentum over a narrow strip
at the beach toe, divided by that strip width. It is an approximate section
flux, not the exact flux through a reconstructed beach-toe surface.

For a small standing wave, Formurae tracks two successive, oppositely directed
zero crossings of a column-height gauge near the initial water level and
the tank centre. The gauge uses the same eight-cell column at the beginning
of each completed physical timestep; it measures height rather than just
the fractions of the nearest two cells. Twice their time difference gives `wavePeriod`.
`expectedPeriod` is the inviscid gravity-wave reference
`2*pi/sqrt(g*k*tanh(k*H))`, k=2*pi/lengthX. It is not the exact solution of
the viscous, weakly compressible kinetic model. A nonzero measured period
requires both crossings; zero denotes a missing measurement.

The initial vertical velocity is extended above the wave using its value at
the initial surface, rather than continuing to grow with height in the empty
region. `overhangCells` excludes cells next to any solid wall: a positive
vertical fraction gradient at the seabed is not an overturning free surface.
An overturning crest must still be identified from a connected surface and
its subsequent impact in the saved fields.

The column-sum approach is informed by the [Basilisk height-function implementation](https://basilisk.fr/src/heights.h). The local eight-cell formula, monotonicity test, fallback, curved-grid approximation and kinetic-pressure coupling above are this experiment's choices and require their own validation.

## Slip wall on an arbitrary physical face

Let N be the oriented physical face vector, T=(-N_y,N_x) its tangent,
B_a=c_a dot N, and t_a=c_a dot T. Start with opposite-population reflection.
For a wall on the right of liquid, correct the incoming populations by
`K*w_a*t_a`, where

```
D = sum_{B_a>0} B_a*w_a*t_a^2,
K = 2*sum_{B_a>0} B_a*t_a*h_out,a / D.
```

For a wall on the left, use the outgoing negative-B directions and -B in the
sum. Opposite pairs have equal weights. Half of the isotropic second moment
gives `sum_incoming B_a*w_a*t_a = 0`, so the correction does not change the
zero normal mass flux. Its tangential momentum flux cancels that of the
reflected outgoing populations. The hydrostatic reference has zero tangential
stress and need not appear in the numerator. `wallMassResidual` checks the
actual unmasked mass flux; `wallSlipResidual` checks actual tangential stress
on slip walls. This is a moment-based boundary reconstruction, not a lookup
of a reflected direction in the nine-velocity set.

The slip boundary is the default for comparing with ideal gravity-wave
periods and for the first beach-wave experiment. It does not resolve friction
in a seabed boundary layer. The no-slip control remains available, so its
damping and influence on runup can be examined without changing the equations.

The collision relaxation time is the continuous-time parameter tau. At small
speeds and long wavelengths the kinematic viscosity is tau/3; the standard
one-cell-per-step lattice-streaming viscosity formula does not apply here.
The explicit control must resolve collision as well as transport. The local
implicit option must be checked for the chosen timestep and relaxation time;
it does not make the moving-boundary calculation unconditionally stable.
`populationLowest` is the minimum of f_a/w_a over retained states and all
velocity directions, including intermediate projected states. It establishes
positivity of those populations, not of every unretained ghost or candidate.

On the current Mac, Open MPI's automatic CPU-topology discovery crashes before
starting the solver. The same environment settings used by the elastic-wave
examples allow the normal MPI launcher to run:

```sh
export HWLOC_SYNTHETIC='node:1 core:10 pu:1'
export MPIRUN_ARGS='--bind-to none'
```

These settings describe the local ten-core CPU layout and leave scheduling to
the operating system; they do not change the simulation. The runner records
them in each `configuration.json`. They are machine-specific, not universal MPI
defaults. `compare.py SERIAL_DIRECTORY MPI_DIRECTORY --output report.json`
checks all saved fields and every generated diagnostic of identical executions.

The recorded launcher hash identifies the version used for each run. Verification
checks the actual ordered physical arguments against the recorded parameters,
in addition to the model, generated-build identity and saved-file hashes. Adding
CLI validation or changing drawing code does not require repeating an unchanged
physical calculation. Original provenance hashes are retained.

## Fitted-beach development run

The current beach uses 160×64 cells over a physical 6.4×0.8 tank, with depth
0.2, Gaussian elevation 0.12, width 0.3 and a 0.1 bed slope starting at X=1.6.
The initial shoreline is X=3.6, leaving room for runup before the far wall.
The Gaussian and its initial velocity are an approximate incoming wave, not
an exact solitary-wave solution. All quantities below are in the model's
consistent dimensionless units.

After the foundation suite, build and check this grid sequentially:

```sh
python3 examples/kinetic_free_surface/run.py --grid 160 64 --length 6.4 .8 --mpi 2 2
python3 examples/kinetic_free_surface/experiment.py shared-height-bed-rest --grid 160 64 --length 6.4 .8 --mpi 2 2 --height-method 2 --scenario 4 --gravity .08 --level .2 --amplitude 0 --center .85 --width .3 --bed-start 1.6 --bed-slope .1 --tau .0006 --time-scale 2 --duration 2 --reports 40
python3 examples/kinetic_free_surface/verify.py .build/kinetic-free-surface/grid-160-64-mpi-2-2/shared-height-bed-rest/result.json --case bed-rest
python3 examples/kinetic_free_surface/experiment.py shared-height-beach-shear --grid 160 64 --length 6.4 .8 --mpi 2 2 --height-method 2 --scenario 5 --periodic --gravity 0 --speed .01 --tau .0006 --time-scale 2 --duration 2 --reports 40
python3 examples/kinetic_free_surface/verify.py .build/kinetic-free-surface/grid-160-64-mpi-2-2/shared-height-beach-shear/result.json --case shear
python3 examples/kinetic_free_surface/experiment.py beach-shared-height --grid 160 64 --length 6.4 .8 --mpi 2 2 --height-method 2 --scenario 4 --gravity .08 --level .2 --amplitude .12 --center .85 --width .3 --bed-start 1.6 --bed-slope .1 --tau .0006 --time-scale 2 --duration 40 --reports 240
python3 examples/kinetic_free_surface/verify.py .build/kinetic-free-surface/grid-160-64-mpi-2-2/beach-shared-height/result.json --case backwash
```

Use the Mac-specific MPI environment above if needed. The reference two short control
runs took approximately 84 and 88 seconds with eight MPI processes. The
current four-process build is being compared on this Mac (Apple M5, four
performance cores and six efficiency cores). The long incoming
wave is substantially more expensive. Do not overlap it with another solver or
compiler. Completion of a run is not a passing result: `verify.py --case
backwash` retains the fixed retreat criteria and checks both water contours
against the far wall. A connected crest, cavity and impact must also be checked
in the saved frames.

The standing-wave accuracy checks use the 64×64 MPI executable:

```sh
python3 examples/kinetic_free_surface/experiment.py shared-height-wave --grid 64 64 --mpi 2 2 --scenario 2 --height-method 2 --amplitude .03 --tau .0025 --time-scale 2 --duration 20 --reports 100
python3 examples/kinetic_free_surface/experiment.py shared-height-small-wave --grid 64 64 --mpi 2 2 --scenario 2 --height-method 2 --amplitude .003 --tau .0025 --time-scale 2 --duration 20 --reports 100
```

`assess.py --beach-label beach-shared-height` rechecks the saved cases and
writes `results/verification.json`, including failed criteria and unchanged
provenance. It does not rerun or modify the simulation. Add `--require-all` to
return a failing exit status if any numerical acceptance check remains open.
A successful collection without that flag does **not** mean all checks passed.
The page generator requires valid conservation/bounds, matching media hashes
and a separate `surface-review.json` tied to the saved frames. Numerical cell
counts do not replace this visual review. Development results may be displayed
with their failed criteria explicitly visible.

## Candidate comparison: fraction slopes and standing-wave initialization

`method=0` is first-order upwind. `method=1` uses MC slopes for both
populations and water fraction. The candidate `method=2` keeps MC for the nine
populations and uses Superbee, a more compressive slope limiter, only for the
water fraction. For backward/forward differences a and b it uses

```
s = maxmod(minmod(2*a,b), minmod(a,2*b)).
```

Here minmod chooses the smaller magnitude when signs agree and zero otherwise;
maxmod chooses the larger magnitude of the two same-sign candidates. This is
the [standard Superbee formula in Clawpack's reference implementation](https://github.com/clawpack/classic/blob/master/src/2d/philim.f90).
The opposite face values are `alpha ± s/2`; they remain within neighboring
bounds and the four face values still sum to `4*alpha`. The existing sufficient
condition on explicit mass transport therefore remains applicable. This does
not prove positivity of the full projected, implicit-collision model: all
moving-boundary checks are repeated. No clipping, film removal, added water
or drawing-generated surface is used.

The standing-wave scenario now initializes liquid density with the linear
pressure profile

```
rho_initial = rho_H * (1 + 3*g*A*cos(k*X)*cosh(k*Y)/cosh(k*H)),
k = 2*pi/lengthX.
```

This uses the same depth dependence as the existing `kinetic_surface` gravity
mode. The previous hydrostatic profile beneath a wavy column also excites an
acoustic adjustment; its effect on the measured first half-cycle is being
compared. This profile is a small-amplitude initialization, not an exact
nonlinear or compressible solution. Other scenarios retain their initial data.
Test the standing wave with method 1 first, then method 2, so this initialization
change and the fraction limiter can be distinguished. The unchanged-beach
method-1 control compares all saved fields with the reference before testing
the new fraction method.

## Interface cells held against a full neighbour (`method=4`)

`method=4` keeps the `method=3` reconstruction everywhere except in an interface
cell (`0 < alpha < 1`) whose neighbour on one side along an axis is full (solid
counts as full, as in the height columns) and whose neighbour on the other side
holds a strictly smaller fraction. Such a cell holds its water against the full
neighbour: the face value toward that neighbour is `min(1, K*alpha)` and the
opposite face value is `max(0, 1-K*(1-alpha))`, with `K = compression` (default
5). The rule fades in with the neighbour's fraction above one half
(`ramp(2*filled-1)`), so a neighbour that is nearly full does not switch the rule
off discontinuously, and it is weighted by the alignment of the fraction gradient
with the axis (the squared cosine, from the neighbouring fractions divided by the
physical cell extents `spanAlongX`/`spanAlongY`), so an interface parallel to the
flow keeps the limited slopes. The weight is exactly one when the other gradient
component is below a hundredth of the axis component, so an axis-aligned
interface is packed exactly and rounding differences between rows cannot leak
water through the `(1-weight)` blend (a leak of that kind produced a tail that
decayed into the denormal range and then a 0 times infinity). Otherwise it is
the squared cosine with the denominator floored by `alignmentFloor` (default
1e-12, a runtime parameter: a literal that small is folded to zero by the code
generator, and the generated quotient is a product with a reciprocal that
overflows for a denormal denominator). The gradient differences are bound to
locals (`gradX`, `gradY`) before they are squared: an inline squared
difference is expanded by the CAS into cancelling terms, and in nearly full
cells that expansion produced roundoff garbage and a 0/0 in the diagnostic.

For a layer whose end cells hold at least `1/K` of a cell this reproduces the
exact one-dimensional transport (the emulation gives 0.375 | 0.225 and a resolved
centroid error of 0.00%). On the 32x32 build (source SHA-256 prefix `c70ea9bc`, identical numbers on the earlier `2bf62a6a`)
the falling suite passes all four required layers: momentum errors 7.4e-3,
6.1e-3, 3.4e-3 and 1.8e-6, centroid errors 0.79% and 1.77% (plain moment, thin
layers) and 0.23% and 0.084% (resolved moment, three-cell and thick layers). The
thick layer's plain moment still reads 3.99%, the discretisation bias derived
above. `compression=8` gives the same thick-layer numbers; the previous
`method=3` transport fails the thick layer at 3.30% under the resolved moment,
and the `method=3` control run reproduces the archived `method=3` result
exactly (saved fields and diagnostics differ by 0.0), so methods 0-3 are
unchanged by the new code. On the beach-size domain (160x64 cells, 6.4x0.8,
MPI 2x2, `method=4`, `heightMethod=5`) the ten foundation cases pass: halving
the collision timestep reduces the stress error by the factor 0.24995, the
`tau=0.02` shear decay differs from the reference by 1.03% and the
`tau=0.0006` decay by 2.79%. The fitted-beach rest (depth 0.2, slope 0.1,
`tau=0.0006`, `timeScale=2`, duration 2) passes the fixed 0.001 speed criterion
with a largest spurious speed of 8.2e-4 (the `method=3` transport gave 3.1e-4)
and an integrated fraction change of 2.1e-5 (4.3e-6 before): the packed face
values on the sloping bed leave a larger, still bounded, spurious motion. The
beach-grid shear wave at the beach timestep (`tau=0.0006`, `timeScale=2`)
decays within 2.785% of the reference, as with the previous transport.

The same incoming wave (`A=0.12`, width 0.3, slope 0.1, `g=0.08`,
`tau=0.0006`, `timeScale=2`, duration 40) with `method=4` and `heightMethod=5`
(`beach-packing`) again produces no connected curl or cavity: the crest
flattens into a diffuse horizontal tongue from about t=12 and runs up the slope
as before. In addition the packed reconstruction creates an unphysical
structure: behind the wave, at X about 0.6-0.7, the trough steepens from t=2
into a nearly vertical water step that persists to the end of the run instead of
collapsing under gravity (columns of partially filled cells at the step, water
level 0.22 on its left and 0.12 on its right at t=36). This is the staircasing
of a compressive reconstruction applied per axis to an oblique surface: the
horizontal packing of a surface cell whose neighbour to the left is fuller holds
water against that face, so the tangential flux through the other face falls and
the surface cannot relax. The falling-layer improvement therefore does not carry
over to the wave, and `method=4` in this form is not adopted for the beach; the
`method=3` transport remains the reference for the wave calculations, and a
version that packs only nearly axis-aligned interfaces (weight one or zero, no
partial compression) is the next variant to test. The run itself completed
(t=40, 73 minutes on four processes sharing the machine with other runs); the
basic checks pass (relative mass drift 3.5e-15, raw fraction within
[0, 1+1.9e-12], lowest population 0.216 of its weight, largest retained speed
0.267). The retreat criteria fail as in the earlier trials: the 0.5 waterline
reaches 6.38 next to the far wall at 6.4 and the 0.01 layer touches the wall
and never retreats (`thin_layer_retreat`, `waterline_avoids_far_wall` and
`thin_layer_avoids_far_wall` fail), the 0.5 contour then withdraws by 0.69 and
the two-cell-deep front by 0.24, and 0.010 of the 0.044 of water that passed the
initial shoreline returns. The largest `overhangCells` count, 18 at t=37,
comes from the vertical step behind the wave, not from a crest. Stages 5 and 6
remain unachieved.

## Stronger incoming wave (step 3)

The dimensionless conditions of the older lattice-Boltzmann example
(`examples/breaking_wave`: height ratio 0.73 of the depth, sech-squared width
0.5 depth, bed slope 0.2, launch factor 2.5, depth Reynolds number about 83)
were transferred to this model on 256x64 cells over 2.25x0.5625 with depth 0.2,
Gaussian amplitude 0.1544, width 0.1059, centre 0.3, bed toe 0.52, `g=0.02`,
`tau=0.0005`, `timeScale=2`. With `launch=2.5` the run is invalid: the factor
also scales the divergence-free vertical velocity of scenario 4, the crest is
thrown upward into a vertical spout at X about 0.5 by t=1.2, retained speeds
reach 0.75 (`method=3`) and 0.88 (`method=4`) against a sound speed of 0.577,
and populations turn negative before t=2.9. Both runs were stopped and are not
physical results; the older example started with zero vertical velocity, so a
launch factor must not multiply the vertical component. The stronger wave is
therefore run with `launch=1` and the previous `method=3` transport
(`strong-launch1-method3`). That run also fails the fixed criteria, for a
different reason: scenario 4 gives the hump a divergence-free vertical
velocity proportional to `1/waveWidth^2`, and with the narrow width 0.1059 that
initial field is about eight times stronger than on the wide beach wave. Within
t=0.24 wet cells reach a speed of 0.35 and populations become negative, so the
running `peakSpeed` (0.71) and `populationLowest` (-0.25) records exclude the
run under the unchanged positivity and 0.3 criteria. The transient decays:
at t=3.4 the largest speed anywhere is 0.128 and 0.103 in wet cells, and the
crest at X about 0.5 leans forward over a diffuse tongue, which is closer to an
overturning crest than anything the wide wave produced but cannot be counted
while the criteria fail. The run reached t=10 in 45 minutes with mass conserved
to 5.6e-15, but it is not a physical result: at t=4 the crest had become a
vertical spout at X about 0.45, which collapsed into spray by t=6, the density
left the [0.5, 1.5] range, the lowest population reached -1.6 of its weight and
the recorded speed 1.21, and the surface at t=10 is chaotic with 348 overhang
cells. The next experiment starts the stronger wave without the vertical
velocity (the older example started from rest vertically) so that the criteria
are met from the first step, and treats the spout as an initial-condition
artifact to be removed before any breaking is judged. `verticalStart=0`
(parameter 28, `--vertical-start 0`) starts scenario 4 with zero vertical
velocity; at the default 1 the reference expression is unchanged. The runs
`strong-vertical0-launch1` and `strong-vertical0-launch2.5` use it with the
`method=3` transport. Removing the vertical velocity does not rescue the
stronger wave: the speed record exceeds 0.3 at t=0.25 and populations turn
negative by t=3.9 (lowest -0.23, speed record 0.66). The first violation is
located in a cell on the rear flank of the hump (X=0.18, Y=0.23) that has just
become wet: at t=0.39 its fraction is 0.011, its density 2.19 and its speed
0.65, while its full neighbours have densities 1.0-1.1. A newly wetted cell
takes the transported candidate state, and on a steep, fast flank that state
carries far more mass than the cell's water; the excess pressure then ejects
the water. This wetting initialization, not the incoming wave itself, is what
the stronger wave exposes, and it is the next defect to correct (for example by
initializing a newly wetted cell from its liquid neighbours' equilibrium).
Qualitatively this run is the closest to breaking so far: without the spout,
the hump steepens at its front and by t=2.8 the crest at X about 0.35 leans
forward with the 0.5 contour beginning to curl, after which the crest smears
and small spurious bumps from the wetting defect appear ahead of it; by t=4
the surface is fragmented and it stays irregular to t=10 (density range
0.44-2.20, lowest population -0.23, speed record 0.66, 109 overhang cells at
t=10, mass conserved to 6e-15). It is shown on the wave page as a development
result with its failed criteria. `strong-vertical0-launch2.5` (the older
example's horizontal launch factor, no vertical velocity) fails the same way
from t=0.15 (lowest population -0.43, speed record 0.70, density 0.41-2.52).

The standing-wave period checks were repeated on the 64x64 four-process build
with `method=3` and `heightMethod=5` (`reference-wave`, `reference-small-wave`):
the amplitude-0.03 wave now measures 18.119 against 17.758 (2.04%, within the
5% limit), the amplitude-0.003 wave 20.425 (15.0%, failing). The small wave's
period is measured from a gauge column whose deflection is a few thousandths of
a cell, so its failure needs a refinement study before it says anything about
the dynamics; the criterion is unchanged and the case stays open. Both
standing-wave runs also fail the basic checks: speed records 0.47 and 0.80,
density up to 1.89 and 2.76, and a lowest population of -0.10 for the small
wave. As in the stronger wave, these spikes sit in cells that the moving
surface has just wetted, so the wetting initialization defect affects every
case whose surface crosses cells, not only steep waves. The reference beach
run with `method=3` and `heightMethod=5` (`beach-reference`, 45 minutes)
conserves mass to 4.8e-15 with fractions in [0, 1+2.2e-12] and positive
populations, but its speed record 0.330 (first above 0.3 at t=15.6, when the
front wets the slope) fails the 0.3 limit; its retreat criteria fail as before
(waterline and thin layer at the far wall). The wave page shows these runs as
development results with the failed criteria listed. Thinner end cells drain at a rate proportional to their
fraction, and isolated layers without a full neighbour keep the constant
reconstruction of `method=3`. Face values stay within `K*alpha` of zero and within
`K*(1-alpha)` of one, so the explicit sufficient condition for positivity becomes
`K*fractionCourant <= 1`; `verify.basic` asserts it for `method>=4`. The beach
runs so far have `fractionCourant` about 0.056, five times below the bound at
`K=5`. This is a compressive donor-cell reconstruction with a per-axis packing
rule, not a geometric interface reconstruction; oblique interfaces receive
partial compression along both axes. `launch` (default 1) scales the incoming
wave's initial velocity in scenario 4 and leaves the reference expressions
untouched at 1, for the stronger-wave comparison planned after the beach retrial.

The four face fractions of a cell (`faceFractionWest/East/South/North`) are
computed once per stage in the locating phase and stored, like the surface
heights; the transport samples the stored values. The fraction does not change
between the locating and the preparing phase, so the values are the ones the
earlier inline reconstruction produced. Storing them keeps the generated C from
expanding the reconstruction at every face of every flux evaluation: with the
reconstruction inlined, Formura's C generation exceeded 45 minutes and 30 MB.
