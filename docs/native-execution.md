# One Formurae program, from equations to execution

Install the Formurae executables and their data files with `cabal install all:exes`.
Egison and a C11 compiler must be available. A user supplies one `.fme` file:

```sh
formurae run examples/tensor_demos/oldroyd_couette.fme
```

This generates and compiles the complete simulation, including initialization,
time integration, wall values, and the order of global operations. It does not
invoke Python. Results appear in `oldroyd_couette.native/output/` next to the
input file. `formurae compile MODEL.fme` builds without running. Runtime options
include `--grid NX NY`, `--dt DT`, `--steps N`, `--every N`, and `--output DIR`.

The current native backend executes a serial two-dimensional collocated grid:
every component is stored at the same grid points. The first axis includes both
walls and extra cells outside them for boundary calculations (ghost cells).
The second axis is periodic and has a power-of-two number of points. The
ordinary Formura backend remains available for its distributed stencil code.
Both backends use the same checked tensor expressions and finite-difference
lowering. The native backend emits C loops from that representation; it does
not copy the physical equations into a handwritten C solver.

## Program structure

Declarations, `def` functions, geometry and `init:` retain their usual meanings.
Named `stage NAME:` blocks contain the same tensor assignments and local
definitions as an ordinary `step:`. An omitted field is unchanged by that stage.
Within a stage, a primed field denotes an earlier update in that stage; an
unprimed field denotes the state on entry. Later stages see completed updates.
The extracted stage files retain the source line numbers for diagnostics.

```text
dimension 2
axes x, y
param gain = 2
field q
field time
field dt
init:
  q = 1
  time = 0
  dt = 0.125
stage advance:
  q' = q + dt * gain
  time' = time + dt
runtime:
  grid 9 8
  extent 1 1
  halo 1
  time time
  timestep dt
  steps 2
  every 1
  output q
  monitor value first q 0
advance:
  call advance
observe:
  require min q > 0 0
```

`prepare:` runs once after initialization; `advance:` runs once per time step;
`observe:` runs before saving each frame. Commands execute in written order.
The model must fill enough boundary cells for its nested derivatives.

| Command | Meaning |
|---|---|
| `call NAME` | Execute a generated stage. |
| `copy FROM TO` | Copy all independent components of a field. |
| `mean FROM TO` | Average a scalar component over the periodic axis and broadcast it on each row. |
| `ghost reflect FIELD SCALE` | Reflect scaled values about the wall value. |
| `ghost extend FIELD SCALE` | Extend the scaled wall value constantly. |
| `ghost odd FIELD SCALE` | Reflect scaled values with opposite sign about zero. |
| `poisson OUT RHS LOWER DIAGONAL UPPER ANGULAR` | Solve the separable elliptic system described below. |
| `require min FIELD > VALUE MARGIN` | Abort if the reduced field fails the condition. `max`, `maxabs`, and `<` are also supported. |

`SCALE` is a model-generated field with matching components. This expresses,
for example, transfer in a physical orthonormal basis without embedding a
coordinate system in the runtime. Individual components use source notation,
such as `v~2` or `C~1~2`.

The elliptic operation uses homogeneous Dirichlet values on the radial walls
and removes the periodic zero mode. For each nonzero Fourier mode `k`, it solves

```text
LOWER[i] u[i-1] + (DIAGONAL[i] + 4 sin²(pi k/NY) ANGULAR[i]) u[i]
    + UPPER[i] u[i+1] = RHS[i].
```

All four coefficients are generated fields, constant along the periodic axis.
The runtime uses a fast Fourier transform and a tridiagonal linear solve;
factorizations are reused only while their coefficients are unchanged.
In the Couette program, the periodic mean velocity has its own generated time
update, preserving the circulation of the annulus.

`runtime:` declares grid sizes, physical extents, ghost width, time and time-step
fields, step count, frame interval, output fields and monitors. A monitor has
the form `monitor NAME OP FIELD MARGIN`, with `OP` equal to `min`, `max`, `maxabs`,
`sum`, or `first`. `MARGIN` excludes that many physical rows from each wall.
`report.json` records the component order and observations. C writes `.npy`
arrays directly; this binary array format does not require a Python runtime.

## Couette validation and visualization

`make couette-check` compares generated transport and tensor updates with
independent component formulas, verifies spatial convergence on an exact
steady solution, and verifies time convergence. It also checks the Fourier
transform against a direct transform and the elliptic solver against a known
discrete solution. `make native-tests` exercises source diagnostics and the
semantics of sequential generated updates. C checks use undefined-behavior
instrumentation. AddressSanitizer initialization deadlocks in the tested macOS
runtime before reaching `main`, so those checks do not claim an ASan result.

`make couette-simulate` writes gallery snapshots. `make couette-render` uses
Python to draw them. Marker paths in the recoil movie are computed from saved
velocities solely for visualization; they do not feed back into the fluid.
