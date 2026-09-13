#!/usr/bin/env python3
"""Build and run one configuration of the Taylor-Couette model through the
normal Egison/Formura pipeline.

This script only selects parameters and grid layouts, invokes the tools, and
handles files.  The initial state, the projection, the wall conditions and the
diagnostics belong to the FME model.

The gap is the annulus R1 = 1 < r < R2 = 2 (walls on the radial faces 0 and
NR - 1, so NR slots give the spacing 1/(NR - 1)) and the axial period is LZ,
divided into NZ cells.  The Reynolds number RE = Ω1 R1 (R2 - R1) / ν fixes the
viscosity; the run starts from the laminar Couette flow with a small axial
perturbation of the radial velocity.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "taylor_couette"
# Forward reach of one step (Ns of the generated header): the four unrolled
# Jacobi sweeps plus the predictor, the divergence and the gradient.
SLEEVE = 6
REDUCTIONS = "res = absmax res, dv = absmax dv, ur = absmax u_down1, uz = absmax u_down2"


def call(command, directory, name, env=None, stdout=None):
    print(name, flush=True)
    log = directory / (name + ".log")
    try:
        with log.open("w") as err:
            if stdout is None:
                subprocess.run([str(x) for x in command], cwd=ROOT, env=env,
                               stdout=err, stderr=subprocess.STDOUT, check=True)
            else:
                with stdout.open("w") as out:
                    subprocess.run([str(x) for x in command], cwd=ROOT, env=env,
                                   stdout=out, stderr=err, check=True)
    except subprocess.CalledProcessError:
        print(log.read_text()[-5000:], flush=True)
        raise


def block_size(n, interval):
    # Formura pads each axis by 2*sleeve*interval cells and needs the padded
    # extent to be a multiple of the block; blocks must also cover that halo.
    total = n + 2 * SLEEVE * interval
    least = 2 * SLEEVE * interval
    choices = [b for b in range(least, total + 1) if total % b == 0]
    if not choices:
        raise ValueError("grid has no suitable block divisor")
    preferred = [b for b in choices if b <= 128]
    return (preferred or choices)[-1]


def normalize(model, directory, env, egison):
    """The three generation stages: formurae-pre, Egison normalization, formurae-post."""
    call(["cabal", "run", "-v0", "formurae-pre", "--", model], directory, "pre",
         env, directory / (NAME + ".egi"))
    call([ROOT / "tools/run_formurae_normalization.sh", egison, directory / (NAME + ".egi")],
         directory, "egison", env, directory / (NAME + ".feir"))
    call(["cabal", "run", "-v0", "formurae-post", "--", directory / (NAME + ".feir")],
         directory, "post", env, directory / (NAME + ".fmr"))


def build(directory, re_number=100.0, grid=(65, 256), lz=4.0, dt=0.003, seed=1e-3,
          mpi=(1, 1), blocking=0):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    nr, nz = grid
    text = (HERE / (NAME + ".fme")).read_text()
    overrides = {"ν": repr(1.0 * 1.0 * (2.0 - 1.0) / re_number), "dt": repr(dt),
                 "Lz": repr(lz), "start": "1.0", "seed": repr(seed)}
    for key, value in overrides.items():
        text, count = re.subn(r"^param " + re.escape(key) + r" = .*$",
                              "param " + key + " = " + value, text, flags=re.MULTILINE)
        if count != 1:
            raise ValueError("unknown or repeated parameter: " + key)
    model = directory / (NAME + ".fme")
    model.write_text(text)
    parameters = dict(re.findall(r"^param (\S+) = (.*)$", text, flags=re.MULTILINE))
    if mpi[0] != 1:
        raise ValueError("the radial axis is not decomposed (one rank in r)")
    if nz % mpi[1]:
        raise ValueError("the axial cells must divide evenly among the ranks")
    local = [nr, nz // mpi[1]]
    dr = 1.0 / (nr - 1)
    config = ["length_per_node: " + json.dumps([nr * dr, lz / mpi[1]]),
              "grid_per_node: " + json.dumps(local),
              "mpi_shape: " + json.dumps(list(mpi)),
              "boundary: [fixed 0.0, periodic]"]
    if blocking:
        config += ["grid_per_block: " + json.dumps([block_size(n, blocking) for n in local]),
                   "temporal_blocking_interval: " + str(blocking)]
    config += ["reduces: [" + REDUCTIONS + "]"]
    (directory / (NAME + ".yaml")).write_text("\n".join(config) + "\n")
    env = dict(os.environ, EGISON_HEAP_LIMIT=os.environ.get("EGISON_HEAP_LIMIT", "4G"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    normalize(model, directory, env, egison)
    formura = os.environ.get("FORMURA", str(ROOT / "bin/formura"))
    with (directory / "formura.log").open("w") as log:
        subprocess.run([formura, NAME + ".fmr"], cwd=directory,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    parallel = mpi != (1, 1)
    compiler = os.environ.get("MPICC", "mpicc") if parallel else os.environ.get("CC", "cc")
    flags = [] if parallel else ["-I" + str(ROOT / "mpistub")]
    # The driver is copied next to the generated header so that its include
    # resolves to this build's array layout, never to another grid's.
    (directory / "driver.c").write_text((HERE / "driver.c").read_text())
    call([compiler, "-O2", "-std=c11", "-I" + str(directory), *flags,
          directory / "driver.c", directory / (NAME + ".c"), "-lm", "-o", directory / "check"],
         directory, "cc", env)
    metadata = {"re": re_number, "grid": list(grid), "lz": lz, "dt": dt, "seed": seed,
                "mpi": list(mpi), "blocking": blocking, "config": config,
                "parameters": parameters,
                "source_sha256": hashlib.sha256(text.encode()).hexdigest(),
                "egison_revision": subprocess.check_output(
                    ["git", "-C", str(egison), "rev-parse", "HEAD"], text=True).strip()}
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n")
    return directory


def run(directory, steps, every, mpi=(1, 1)):
    directory = Path(directory).resolve()
    data = directory / "data"
    data.mkdir(exist_ok=True)
    for old in data.glob("*-rank-*.bin"):
        old.unlink()
    command = [directory / "check", steps, every, data]
    env = dict(os.environ)
    if mpi != (1, 1):
        command = [os.environ.get("MPIRUN", "mpirun"),
                   *shlex.split(os.environ.get("MPIRUN_ARGS", "")),
                   "-np", mpi[0] * mpi[1], *command]
        # Open MPI's launcher crashes in the topology detection on some Macs;
        # a synthetic topology only affects process binding.
        if sys.platform == "darwin":
            env.setdefault("HWLOC_SYNTHETIC", "node:1 core:10 pu:1")
    call(command, directory, "run", env=env, stdout=directory / "stats.csv")
    metadata = json.loads((directory / "metadata.json").read_text())
    metadata.update(steps=steps, output_interval=every,
                    mpi_environment={key: env[key] for key in
                                     ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in env})
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n")
    print((directory / "run.log").read_text().strip(), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--re", type=float, default=100.0, help="Reynolds number Ω1 R1 d / ν")
    parser.add_argument("--grid", type=int, nargs=2, default=[65, 256], metavar=("NR", "NZ"),
                        help="radial slots (walls on both ends) and axial cells")
    parser.add_argument("--lz", type=float, default=4.0, help="axial period")
    parser.add_argument("--dt", type=float, default=0.003)
    parser.add_argument("--seed", type=float, default=1e-3, help="amplitude of the initial perturbation")
    parser.add_argument("--mpi", type=int, nargs=2, default=[1, 1], metavar=("PR", "PZ"))
    parser.add_argument("--blocking", type=int, default=0, help="0 disables time blocking")
    parser.add_argument("--steps", type=int, default=60000)
    parser.add_argument("--every", type=int, default=2000, help="interval of the records")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/taylor_couette/demo")
    args = parser.parse_args()
    if min(*args.grid, *args.mpi, args.steps, args.every) < 1 or args.blocking < 0:
        parser.error("sizes and intervals must be positive")
    if args.steps % args.every or args.every % (args.blocking or 1):
        parser.error("steps/every must align with the output/blocking interval")
    directory = build(args.output, args.re, tuple(args.grid), args.lz, args.dt, args.seed,
                      tuple(args.mpi), args.blocking)
    run(directory, args.steps, args.every, tuple(args.mpi))


if __name__ == "__main__":
    main()
