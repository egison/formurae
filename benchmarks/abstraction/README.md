# Runtime comparison with handwritten Formura

This benchmark compares five Formurae-generated updates with independently
written Formura implementations of the same differences and time updates.
Both versions pass through the same Formura compiler and C compiler. It
measures the cost of the generated updates for these workloads; it does not
estimate a universal Formurae overhead.

## Workloads

| Model | Formurae source | Independent Formura source | State components |
| --- | --- | --- | ---: |
| Diffusion | [diffusion3d.fme](../../examples/diffusion3d/diffusion3d.fme) | [diffusion3d.fmr](manual/diffusion3d.fmr) | 1 |
| Pearson reaction–diffusion | [pearson3d.fme](../../examples/pearson3d/pearson3d.fme) | [pearson3d.fmr](manual/pearson3d.fmr) | 2 |
| Yee Maxwell | [maxwell3d_yee.fme](../../examples/maxwell3d_yee/maxwell3d_yee.fme) | [maxwell3d_yee.fmr](manual/maxwell3d_yee.fmr) | 6 |
| Elasticity | [elastic3d.fme](../../examples/elastic3d/elastic3d.fme) | [elastic3d.fmr](manual/elastic3d.fmr) | 9 |
| Magnetohydrodynamics (MHD) | [mhd_ot.fme](../../examples/mhd_ot/mhd_ot.fme) | [mhd_ot.fmr](manual/mhd_ot.fmr) | 8 |

Pearson uses the parameters in Listing 1 of Muranushi et al., *Automatic
Generation of Efficient Codes from Mathematical Descriptions of Stencil
Computation* (FHPC 2016): `Fu=1/86400`, `Fv=6/86400`, `Fe=1/900`,
`Du=2.3e-10`, `Dv=6.1e-11`, `dt=200`, and spatial step `0.001`.
That paper also presents MHD. Here both MHD implementations use the
Formurae example's Rusanov flux, a central flux with wave-speed-based
dissipation. This is a comparison of the same numerical method in two
source languages, not a reproduction of the original paper's MHD method
or its performance measurements.

The handwritten references use explicit Formura difference functions and
reuse scalar subexpressions where natural. They were not obtained by
copying generated Formura expressions. A shared C driver replaces each
version's initialization with the same smooth, nonconstant periodic fields,
activating every state component. The full initial expressions are in
`seed` in [run.py](run.py). This initialization is for performance and
equivalence testing; the existing examples separately test physical
solutions and conservation properties.

## Execution and validation

- Periodic `32^3` and `64^3` grids, `8^3` spatial blocks, four-step temporal
  blocking, and one process using the repository's MPI stub.
- Pearson keeps spatial step `0.001`, so its domain length changes with
  grid size. The other models use a unit cube. Generated and handwritten
  versions share each configuration.
- Apple M5, macOS 26.6.2, Apple clang 17.0.0, `-O2 -std=c11`.
- Only calls to `Formura_Forward` are timed with a monotonic clock.
  Initialization, compilation, full-array output, and checks are outside
  the timed region.
- A 32-step warmup precedes measurement. A pilot selects the number of
  steps per model and grid size, targeting at least 0.4 seconds using the
  faster pilot. Counts are multiples of four and are shared by both
  versions. Each of nine pairs alternates which version runs first.
- Every stored value is compared after four steps and after the complete
  warmup plus measured trajectory. All values must be finite, with
  `abs(a-b)/max(1,abs(a),abs(b)) < 2e-10`. This verifies the full arrays,
  not just a checksum or selected samples.
- Preparation records SHA-256 hashes of sources, generated files, drivers,
  and executables. Measurement checks these hashes before running.
  [results.json](results.json) contains the manifest, step counts, individual
  timings, medians, interquartile ranges, and numerical differences.

## Recorded results

Ratios below divide the generated median time by the handwritten median.

| Model | `32^3` ratio | `64^3` ratio | `64^3` handwritten ms/step | `64^3` generated ms/step |
| --- | ---: | ---: | ---: | ---: |
| Diffusion | 1.050 | 1.059 | 0.452 | 0.479 |
| Pearson | 1.028 | 1.030 | 1.865 | 1.921 |
| Yee Maxwell | 1.043 | 1.047 | 5.790 | 6.063 |
| Elasticity | 1.065 | 1.051 | 15.274 | 16.059 |
| MHD | 1.276 | 1.285 | 25.939 | 33.338 |

All ten configurations passed both full-array checks; the largest absolute
difference was `1.709743457922741e-14`. Four models show increases of about
3–7%, while MHD shows about 28–29%. In the MHD sources, symbolic
normalization expands pressure and energy-flux expressions that remain
factored in the handwritten reference. The measurements do not isolate
the contribution of that difference from other generated-code differences.
Removing generation-time function calls does not imply identical runtime
arithmetic or identical performance.

## Reproduction

Run from the Formurae repository with Python 3 and NumPy, Cabal/GHC, a C
compiler, the repository's `bin/formura`, and an Egison checkout. The
recorded run used Egison revision
`1a0298c67cc487dd4a73d96f526f3042b74d6570`; keep it in a separate checkout
without changing an existing working tree. The runner currently obtains
CPU information using macOS `sysctl`.

```sh
python3 benchmarks/abstraction/run.py --prepare --egison-dir /path/to/egison
python3 benchmarks/abstraction/run.py --measure
```

`--prepare` serially runs Formurae, Egison, Formura, and C compilation.
Do not overlap it with other Cabal/GHC builds or tests. `--measure` performs
only execution and numerical comparisons; avoid other CPU-heavy work
while it runs. Build files and logs are under
`.build/abstraction-benchmark/`. The result file is replaced by default;
use `--output /path/to/new-results.json` to retain the recorded results.
Options also select cases, grid sizes, repetitions, and target duration;
record those changes when comparing measurements.
