#!/usr/bin/env python3
"""Build the FME water tank through Egison, FEIR, Formura and C, then run it.

Only build configuration, process execution and file I/O live in this script.
The normalized program is cached with its source and compiler inputs hashed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "wave_train"


def call(command, directory, label, stdout=None, cwd=ROOT):
    print(label, flush=True)
    with (directory / (label + ".log")).open("w") as log:
        if stdout:
            with Path(stdout).open("w") as out:
                result = subprocess.run(list(map(str, command)), cwd=cwd,
                                        stdout=out, stderr=log)
        else:
            result = subprocess.run(list(map(str, command)), cwd=cwd,
                                    stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((directory / (label + ".log")).read_text()[-6000:])
        raise RuntimeError(f"{label} failed ({result.returncode})")


def build(directory, grid=(416, 64), overrides=None):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    source = (HERE / (NAME + ".fme")).read_text()
    for name, value in {"nx": grid[0], "ny": grid[1], **(overrides or {})}.items():
        source, count = re.subn(r"^param " + re.escape(name) + r" = .*$",
                                f"param {name} = {value}", source, flags=re.M)
        if count != 1:
            raise ValueError("unknown parameter: " + name)
    model = directory / (NAME + ".fme")
    model.write_text(source)
    # Parameters are substituted in Formura after normalization, as in the
    # existing nematic_torus example. All expressions still originate in FME.
    neutral = re.sub(r"^param (\w+) = .*$", r"param \1", source, flags=re.M)
    digest = hashlib.sha256(neutral.encode())
    for base in (ROOT / "lib", ROOT / "src", ROOT / "app", ROOT / "spec"):
        if base.exists():
            for path in sorted(p for p in base.rglob("*") if p.is_file()):
                digest.update(str(path.relative_to(ROOT)).encode())
                digest.update(path.read_bytes())
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    digest.update(subprocess.check_output(["git", "-C", egison, "rev-parse", "HEAD"]))
    cache = ROOT / ".build" / NAME / "normalized" / digest.hexdigest()[:20]
    cache.mkdir(parents=True, exist_ok=True)
    normalized = cache / (NAME + ".fmr")
    if not normalized.exists():
        unit = cache / (NAME + ".fme")
        unit.write_text(source)
        call(["cabal", "run", "-v0", "formurae-pre", "--", unit], cache,
             "pre", cache / (NAME + ".egi"))
        call([ROOT / "tools/run_formurae_normalization.sh", egison,
              cache / (NAME + ".egi")], cache, "egison", cache / (NAME + ".feir"))
        pending = cache / "pending.fmr"
        call(["cabal", "run", "-v0", "formurae-post", "--",
              cache / (NAME + ".feir")], cache, "post", pending)
        pending.rename(normalized)
    parameters = dict(re.findall(r"^param (\w+) = (.*)$", source, flags=re.M))
    program = normalized.read_text()
    for name, value in parameters.items():
        program, count = re.subn(r"^double :: " + re.escape(name) + r" = .*$",
                                 f"double :: {name} = {value}", program, flags=re.M)
        if count != 1:
            raise ValueError("missing generated parameter: " + name)
    (directory / (NAME + ".fmr")).write_text(program)
    config = ["length_per_node: " + json.dumps(list(grid)),
              "grid_per_node: " + json.dumps(list(grid)), "mpi_shape: [1, 1]",
              "boundary: [periodic, periodic]",
              "reduces: [water = sum water, bank = absmax bank, speed = max speed, "
              "rmin = min density, rmax = max density, overhang = sum overhang, bad = sum bad, gauge_offshore = sum gaugeOffshore, gauge_surf = sum gaugeSurf, shore_overhang = sum shoreOverhang, downward_speed = max downwardSpeed, runup = max runup]"]
    (directory / (NAME + ".yaml")).write_text("\n".join(config) + "\n")
    call([os.environ.get("FORMURA", ROOT / "bin/formura"), NAME + ".fmr"],
         directory, "formura", cwd=directory)
    (directory / "driver.c").write_text((HERE / "driver.c").read_text())
    call([os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(ROOT / "mpistub"),
          directory / "driver.c", directory / (NAME + ".c"), "-lm", "-o", directory / "run"],
         directory, "cc")
    metadata = {"grid": list(grid), "parameters": parameters,
                "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                "normalization_cache": cache.name}
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return directory


def run(directory, steps, every):
    directory = Path(directory).resolve()
    data = directory / "data"
    data.mkdir(exist_ok=True)
    for path in data.glob("frame-*.bin"):
        path.unlink()
    call([directory / "run", steps, every, data], directory, "run", directory / "stats.csv")
    metadata = json.loads((directory / "metadata.json").read_text())
    metadata.update(steps=steps, every=every)
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print((directory / "run.log").read_text(), end="")
    print(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grid", type=int, nargs=2, default=[416, 64])
    parser.add_argument("--steps", type=int, default=4200)
    parser.add_argument("--every", type=int, default=20)
    parser.add_argument("--param", action="append", default=[])
    parser.add_argument("--output", type=Path, default=ROOT / ".build/wave_train/demo")
    args = parser.parse_args()
    if min(*args.grid, args.every) < 1 or args.steps < 0 or args.steps % args.every:
        parser.error("positive grid/every and nonnegative steps divisible by every required")
    build(args.output, tuple(args.grid), dict(x.split("=", 1) for x in args.param))
    run(args.output, args.steps, args.every)


if __name__ == "__main__":
    main()
