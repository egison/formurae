#!/usr/bin/env python3
"""Build and run the FME model through the normal Egison/Formura pipeline.

This script only selects parameters/grid layouts, invokes tools, and handles
files. Numerical initialization, integration and diagnostics belong to FME.
All builds and numerical runs are sequential.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "excitable_torus"
CASES = {
    "isotropic": {"perpendicular": "0.625", "parallel": "0.625", "twist": "0.0"},
    "oblique": {"perpendicular": "0.25", "parallel": "1.0", "twist": "0.0"},
    "twisted": {"perpendicular": "0.25", "parallel": "1.0", "twist": "0.75"},
}


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
    # Formura includes the one-cell stencil halo for each blocked step.
    total = n + 2 * interval
    choices = [b for b in range(2 * interval, min(64, total) + 1) if total % b == 0]
    if not choices:
        raise ValueError("grid has no suitable block divisor")
    return choices[-1]


def build(directory, case="oblique", grid=(120, 248), mpi=(1, 1), blocking=4,
          overrides=None, extra_fme="", reductions=None, flag="ACCURACY",
          substitutions=None, length=(6.283185307179586, 6.283185307179586),
          boundary=("periodic", "periodic")):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    source = (HERE / (NAME + ".fme")).read_text()
    # Whole-line substitutions select another surface (metric scale, direction
    # vector, stimulus region); see surfaces.py.
    for old, new in (substitutions or {}).items():
        if old not in source:
            raise ValueError("substitution target not found: " + old)
        source = source.replace(old, new)
    changes = CASES[case] | (overrides or {})
    for key, value in changes.items():
        source, count = re.subn(r"^param " + re.escape(key) + r" = .*$",
                                "param " + key + " = " + str(value), source,
                                flags=re.MULTILINE)
        if count != 1:
            raise ValueError("unknown or repeated parameter: " + key)
    if extra_fme:
        declarations, initializers, updates = extra_fme.split("---\n")
        source = source.replace("init:\n", declarations + "\ninit:\n" + initializers)
        source += updates
    model = directory / (NAME + ".fme")
    model.write_text(source)
    if any(n % p for n, p in zip(grid, mpi)):
        raise ValueError("grid must divide evenly among MPI ranks")
    local = [n // p for n, p in zip(grid, mpi)]
    lengths = [l / p for l, p in zip(length, mpi)]
    config = ["length_per_node: " + json.dumps(lengths),
              "grid_per_node: " + json.dumps(local),
              "mpi_shape: " + json.dumps(mpi),
              "boundary: [" + ", ".join(boundary) + "]"]
    if blocking:
        config += ["grid_per_block: " + json.dumps([block_size(n, blocking) for n in local]),
                   "temporal_blocking_interval: " + str(blocking)]
    base = "umin = min u, umax = max u, vmin = min v, vmax = max v, mass = sum mass, square = sum square, active = sum active"
    if extra_fme and reductions is None:
        reductions = "error = sum error, reference = sum reference"
    config += ["reduces: [" + base + (", " + reductions if reductions else "") + "]"]
    (directory / (NAME + ".yaml")).write_text("\n".join(config) + "\n")
    env = dict(os.environ, EGISON_HEAP_LIMIT=os.environ.get("EGISON_HEAP_LIMIT", "1G"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    call(["cabal", "run", "-v0", "formurae-pre", "--", model], directory, "pre",
         env, directory / (NAME + ".egi"))
    call([ROOT / "tools/run_formurae_normalization.sh", egison, directory / (NAME + ".egi")],
         directory, "egison", env, directory / (NAME + ".feir"))
    call(["cabal", "run", "-v0", "formurae-post", "--", directory / (NAME + ".feir")],
         directory, "post", env, directory / (NAME + ".fmr"))
    formura = os.environ.get("FORMURA", str(ROOT / "bin/formura"))
    with (directory / "formura.log").open("w") as log:
        subprocess.run([formura, NAME + ".fmr"], cwd=directory,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    compiler = os.environ.get("MPICC", "mpicc") if mpi != (1, 1) else os.environ.get("CC", "cc")
    flags = [] if mpi != (1, 1) else ["-I" + str(ROOT / "mpistub")]
    if extra_fme:
        flags += ["-D" + flag]
    # The driver is copied next to the generated header so that its include
    # resolves to this build's array layout, never to another grid's.
    (directory / "driver.c").write_text((HERE / "driver.c").read_text())
    call([compiler, "-O2", "-std=c11", "-I" + str(directory), *flags,
          directory / "driver.c", directory / (NAME + ".c"), "-lm", "-o", directory / "check"],
         directory, "cc", env)
    parameters = dict(re.findall(r"^param (\w+) = (.*)$", source, flags=re.MULTILINE))
    metadata = {"case": case, "grid": grid, "mpi": mpi, "blocking": blocking,
                "parameters": parameters, "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                "egison_revision": subprocess.check_output(["git", "-C", str(egison), "rev-parse", "HEAD"], text=True).strip()}
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return directory


def run(directory, steps, every, mpi=(1, 1), dump=True):
    directory = Path(directory).resolve()
    data = directory / "data"
    data.mkdir(exist_ok=True)
    # Remove only this run's previous frames, so reusing an output directory
    # cannot silently append stale frames from a longer previous run.
    for old in data.glob("frame-*-rank-*.bin"):
        old.unlink()
    command = [directory / "check", steps, every]
    if dump:
        command.append(data)
    if mpi != (1, 1):
        command = [os.environ.get("MPIRUN", "mpirun"),
                   *shlex.split(os.environ.get("MPIRUN_ARGS", "")),
                   "-np", mpi[0] * mpi[1], *command]
    call(command, directory, "run", stdout=directory / "stats.csv")
    metadata = json.loads((directory / "metadata.json").read_text())
    metadata.update(steps=steps, output_interval=every,
                    mpi_environment={key: os.environ[key] for key in
                                     ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in os.environ})
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print((directory / "run.log").read_text().strip(), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=[*CASES, "all"], default="all")
    parser.add_argument("--grid", type=int, nargs=2, default=[120, 248])
    parser.add_argument("--mpi", type=int, nargs=2, default=[1, 1])
    parser.add_argument("--blocking", type=int, default=4, help="0 disables time blocking")
    parser.add_argument("--steps", type=int, default=24000)
    parser.add_argument("--every", type=int, default=200)
    parser.add_argument("--param", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/excitable_torus/demo")
    args = parser.parse_args()
    if min(*args.grid, *args.mpi, args.steps, args.every) < 1 or args.blocking < 0:
        parser.error("sizes and intervals must be positive")
    if args.steps % args.every or args.every % (args.blocking or 1):
        parser.error("steps/every must align with the output/blocking interval")
    overrides = dict(value.split("=", 1) for value in args.param)
    for case in CASES if args.case == "all" else [args.case]:
        directory = build(args.output / case, case, tuple(args.grid), tuple(args.mpi),
                          args.blocking, overrides)
        run(directory, args.steps, args.every, tuple(args.mpi))


if __name__ == "__main__":
    main()
