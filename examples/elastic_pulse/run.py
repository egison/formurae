#!/usr/bin/env python3
"""Build and run the FME model through the normal Egison/Formura pipeline.

This script only selects parameters and grid layouts, invokes the tools, and
handles files.  The coordinate map, initial pulse, coefficient fields, time
integration, and every diagnostic belong to FME.  Builds and runs are
sequential.
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
NAME = "elastic_pulse"
LENGTH = 4.0
CASES = {
    "cartesian": {"shear": "0.0"},
    "sheared": {"shear": "0.3"},
}
# Forward reach of one step: the Verlet update differentiates the stress,
# then the half-step velocity, then the new stress (three centered differences).
SLEEVE = 3
REDUCTIONS = ("energy = sum energy, modified = sum modified, pw = sum pw, pr = sum pr, "
              "sw = sum sw, sr = sum sr, pfront = max pfront, sfront = max sfront, vmax = absmax v_up1")


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


def parameter_lines(fmr):
    return re.findall(r"^double :: (\S+) = (.*)$", fmr, flags=re.MULTILINE)


def instantiate(fmr, parameters):
    """Rewrite the parameter lines of a generated Formura source, in order."""
    lines = parameter_lines(fmr)
    if len(lines) != len(parameters):
        raise ValueError("parameter count differs between the model and its Formura source")
    for (name, _), value in zip(lines, parameters.values()):
        fmr, count = re.subn(r"^double :: " + re.escape(name) + r" = .*$",
                             lambda m: "double :: " + name + " = " + value, fmr,
                             count=1, flags=re.MULTILINE)
        if count != 1:
            raise ValueError("parameter line not found: " + name)
    return fmr


def build(directory, case="cartesian", grid=(192, 192, 192), mpi=(1, 1, 1), blocking=4,
          overrides=None, source=NAME + ".fme", substitutions=None, extra_fme="",
          reductions=None, flag="ACCURACY", fresh=False):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    text = (HERE / source).read_text()
    # Whole-line substitutions replace the initial state (plane waves instead
    # of the pulse); extra_fme appends declarations, initializers and updates.
    for old, new in (substitutions or {}).items():
        if text.count(old) != 1:
            raise ValueError("substitution target not unique: " + old)
        text = text.replace(old, new)
    if extra_fme:
        declarations, initializers, updates = extra_fme.split("---\n")
        text = text.replace("\ninit:\n", "\n" + declarations + "\ninit:\n" + initializers)
        text += updates
    changes = CASES[case] | (overrides or {})
    for key, value in changes.items():
        text, count = re.subn(r"^param " + re.escape(key) + r" = .*$",
                              "param " + key + " = " + str(value), text,
                              flags=re.MULTILINE)
        if count != 1:
            raise ValueError("unknown or repeated parameter: " + key)
    model = directory / (NAME + ".fme")
    model.write_text(text)
    parameters = dict(re.findall(r"^param (\S+) = (.*)$", text, flags=re.MULTILINE))
    if any(n % p for n, p in zip(grid, mpi)):
        raise ValueError("grid must divide evenly among MPI ranks")
    local = [n // p for n, p in zip(grid, mpi)]
    config = ["length_per_node: " + json.dumps([LENGTH / p for p in mpi]),
              "grid_per_node: " + json.dumps(local),
              "mpi_shape: " + json.dumps(list(mpi)),
              "boundary: [periodic, periodic, periodic]"]
    if blocking:
        config += ["grid_per_block: " + json.dumps([block_size(n, blocking) for n in local]),
                   "temporal_blocking_interval: " + str(blocking)]
    config += ["reduces: [" + REDUCTIONS + (", " + reductions if reductions else "") + "]"]
    (directory / (NAME + ".yaml")).write_text("\n".join(config) + "\n")
    signature = {"source_sha256": hashlib.sha256(text.encode()).hexdigest(), "grid": list(grid),
                 "mpi": list(mpi), "blocking": blocking, "config": config}
    previous = directory / "metadata.json"
    if os.environ.get("ELASTIC_PULSE_REUSE") and previous.exists() and (directory / "check").exists():
        recorded = json.loads(previous.read_text())
        if all(recorded.get(key) == value for key, value in signature.items()):
            print("reuse", directory.name, flush=True)
            return directory
    env = dict(os.environ, EGISON_HEAP_LIMIT=os.environ.get("EGISON_HEAP_LIMIT", "4G"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    if fresh:
        normalize(model, directory, env, egison)
    else:
        # Parameters stay symbolic through Egison, so one normalization serves
        # every parameter value of the same source: the cached Formura source
        # is instantiated by rewriting its parameter lines.  verify.py checks
        # this equivalence on fresh builds of both coordinate systems.
        key = hashlib.sha256(re.sub(r"^(param \S+ = ).*$", r"\1@", text, flags=re.MULTILINE).encode()).hexdigest()[:16]
        cache = ROOT / ".build/elastic_pulse/normalized" / key
        if not (cache / (NAME + ".fmr")).exists():
            cache.mkdir(parents=True, exist_ok=True)
            (cache / (NAME + ".fme")).write_text(text)
            normalize(cache / (NAME + ".fme"), cache, env, egison)
        (directory / (NAME + ".fmr")).write_text(instantiate((cache / (NAME + ".fmr")).read_text(), parameters))
    formura = os.environ.get("FORMURA", str(ROOT / "bin/formura"))
    with (directory / "formura.log").open("w") as log:
        subprocess.run([formura, NAME + ".fmr"], cwd=directory,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    parallel = mpi != (1, 1, 1)
    compiler = os.environ.get("MPICC", "mpicc") if parallel else os.environ.get("CC", "cc")
    flags = [] if parallel else ["-I" + str(ROOT / "mpistub")]
    if extra_fme:
        flags += ["-D" + flag]
    # The driver is copied next to the generated header so that its include
    # resolves to this build's array layout, never to another grid's.
    (directory / "driver.c").write_text((HERE / "driver.c").read_text())
    call([compiler, "-O2", "-std=c11", "-I" + str(directory), *flags,
          directory / "driver.c", directory / (NAME + ".c"), "-lm", "-o", directory / "check"],
         directory, "cc", env)
    metadata = {"case": case, "source": source, "grid": list(grid), "mpi": list(mpi), "blocking": blocking,
                "fresh": fresh, "config": config,
                "parameters": parameters, "source_sha256": hashlib.sha256(text.encode()).hexdigest(),
                "egison_revision": subprocess.check_output(["git", "-C", str(egison), "rev-parse", "HEAD"], text=True).strip()}
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return directory


def run(directory, steps, every, mpi=(1, 1, 1), dump=True, full=False):
    directory = Path(directory).resolve()
    data = directory / "data"
    data.mkdir(exist_ok=True)
    metadata = json.loads((directory / "metadata.json").read_text())
    if (os.environ.get("ELASTIC_PULSE_REUSE") and metadata.get("steps") == steps
            and metadata.get("output_interval") == every and (directory / "run.log").exists()
            and "bounds=ok" in (directory / "run.log").read_text()):
        print("reuse run", directory.name, flush=True)
        return
    for old in data.glob("*-rank-*.bin"):
        old.unlink()
    command = [directory / "check", steps, every]
    if dump:
        command.append(data)
        if full:
            command.append("full")
    if mpi != (1, 1, 1):
        command = [os.environ.get("MPIRUN", "mpirun"),
                   *shlex.split(os.environ.get("MPIRUN_ARGS", "")),
                   "-np", mpi[0] * mpi[1] * mpi[2], *command]
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
    parser.add_argument("--source", default=NAME + ".fme",
                        help="model file in this directory (the anisotropic variant is elastic_pulse_anisotropic.fme)")
    parser.add_argument("--grid", type=int, default=128)
    parser.add_argument("--mpi", type=int, nargs=3, default=[1, 1, 1])
    parser.add_argument("--blocking", type=int, default=4, help="0 disables time blocking")
    parser.add_argument("--steps", type=int, default=256)
    parser.add_argument("--every", type=int, default=16)
    parser.add_argument("--param", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/elastic_pulse/demo")
    parser.add_argument("--fresh", action="store_true", help="run the complete generation pipeline instead of instantiating a cached normalization")
    args = parser.parse_args()
    if min(args.grid, *args.mpi, args.steps, args.every) < 1 or args.blocking < 0:
        parser.error("sizes and intervals must be positive")
    if args.steps % args.every or args.every % (args.blocking or 1):
        parser.error("steps/every must align with the output/blocking interval")
    overrides = dict(value.split("=", 1) for value in args.param)
    label = "" if args.source == NAME + ".fme" else "-" + Path(args.source).stem.replace(NAME + "_", "")
    for case in CASES if args.case == "all" else [args.case]:
        directory = build(args.output / (case + label), case, (args.grid,) * 3, tuple(args.mpi),
                          args.blocking, overrides, source=args.source, fresh=args.fresh)
        run(directory, args.steps, args.every, tuple(args.mpi))


if __name__ == "__main__":
    main()
