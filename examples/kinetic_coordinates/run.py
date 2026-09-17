#!/usr/bin/env python3
"""Run mapped D2Q9 experiments through the normal FME/Egison/Formura pipeline.

Only orchestration and file handling live here. Geometry, initialization,
time integration, and every physical diagnostic are implemented in FME.
All compilation and runs are sequential.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "kinetic_coordinates"
CHARTS = {"cartesian": (0, 0), "stretched": (0.2, 0), "curved": (0.2, 0.3)}
SCENARIOS = {"uniform": 0, "transport": 1, "shear": 2}
REDUCTIONS = ("elapsed = max elapsed, mass = sum mass, momentum_x = sum momentumX, "
              "momentum_y = sum momentumY, mode = sum mode, energy = sum energy, "
              "error = max error, rmin = min density, rmax = max density, bad = max bad")


def toolchain():
    """Record the actual compiler/library inputs, including uncommitted fixes."""
    digest = hashlib.sha256()
    for folder, pattern in (("src", "*.hs"), ("app", "*.hs"), ("lib", "*.egi"), ("spec", "*")):
        for path in sorted((ROOT / folder).rglob(pattern)):
            if path.is_file():
                digest.update(str(path.relative_to(ROOT)).encode())
                digest.update(path.read_bytes())
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    revision = subprocess.check_output(["git", "-C", egison, "rev-parse", "HEAD"], text=True).strip()
    executable = Path(os.environ.get("FORMURA", str(ROOT / "bin/formura"))).resolve()
    return dict(formurae_inputs_sha256=digest.hexdigest(), egison_revision=revision,
                formura_executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())


def call(command, directory, name, output=None, cwd=ROOT):
    print(name, flush=True)
    env = dict(os.environ, EGISON_HEAP_LIMIT=os.environ.get("EGISON_HEAP_LIMIT", "3G"))
    with (directory / (name + ".log")).open("w") as log:
        if output is None:
            result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        else:
            with output.open("w") as out:
                result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                                        stdout=out, stderr=log)
    if result.returncode:
        print((directory / (name + ".log")).read_text()[-7000:])
        result.check_returncode()


def normalize(directory):
    directory.mkdir(parents=True, exist_ok=True)
    source = HERE / (NAME + ".fme")
    call(["cabal", "run", "-v0", "formurae-pre", "--", source], directory, "pre",
         directory / (NAME + ".egi"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    call([ROOT / "tools/run_formurae_normalization.sh", egison,
          directory / (NAME + ".egi")], directory, "egison", directory / (NAME + ".feir"))
    call(["cabal", "run", "-v0", "formurae-post", "--", directory / (NAME + ".feir")],
         directory, "post", directory / (NAME + ".fmr"))
    return (directory / (NAME + ".fmr")).read_text()


def build(base, generated, size):
    directory = base / f"grid-{size}"
    directory.mkdir(parents=True, exist_ok=True)
    source = (HERE / (NAME + ".fme")).read_text()
    parameters = dict(re.findall(r"^param (\S+) = (.*)$", source, re.MULTILINE))
    parameters.update(stretch="kineticConfig(0)", shear="kineticConfig(1)",
                      scenario="kineticConfig(2)")
    # Parameters survive normalisation as named Formura constants. Instantiate
    # only those constants, as in elastic_pulse/run.py; numerical code is never
    # generated or rewritten by Python.
    declarations = re.findall(r"^double :: (\S+) = (.*)$", generated, re.MULTILINE)
    if [name for name, _ in declarations] != list(parameters):
        raise ValueError("generated parameter list does not match FME")
    fmr = generated
    for (name, _), value in zip(declarations, parameters.values()):
        fmr, count = re.subn(r"^double :: " + re.escape(name) + r" = .*$",
                             lambda _: f"double :: {name} = {value}", fmr,
                             count=1, flags=re.MULTILINE)
        if count != 1:
            raise ValueError(name)
    (directory / (NAME + ".fmr")).write_text(fmr)
    config = ["length_per_node: " + json.dumps([2*math.pi, 2*math.pi]),
              "grid_per_node: " + json.dumps([size, size]), "mpi_shape: [1, 1]",
              "boundary: [periodic, periodic]", "reduces: [" + REDUCTIONS + "]"]
    (directory / (NAME + ".yaml")).write_text("\n".join(config) + "\n")
    call([os.environ.get("FORMURA", str(ROOT / "bin/formura")), NAME + ".fmr"],
         directory, "formura", cwd=directory)
    (directory / "driver.c").write_text((HERE / "driver.c").read_text())
    call([os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(ROOT / "mpistub"),
          "-include", HERE / "config.h",
          directory / "driver.c", directory / (NAME + ".c"), "-lm", "-o", directory / "run"],
         directory, "cc")
    return directory, config, hashlib.sha256(fmr.encode()).hexdigest()


def run(base, executable, config, fmr_hash, scenario, chart, size, step_factor, provenance):
    directory = base / f"{scenario}-{chart}-{size}"
    directory.mkdir(parents=True, exist_ok=True)
    source = (HERE / (NAME + ".fme")).read_text()
    parameters = dict(re.findall(r"^param (\S+) = (.*)$", source, re.MULTILINE))
    parameters.update(stretch=repr(CHARTS[chart][0]), shear=repr(CHARTS[chart][1]),
                      scenario=str(SCENARIOS[scenario]))
    steps = step_factor*size
    started = time.monotonic()
    call([executable / "run", steps, size, parameters["stretch"], parameters["shear"],
          parameters["scenario"]], directory, "run", directory / "stats.csv")
    metadata = dict(scenario=scenario, chart=chart, grid=[size, size], steps=steps,
                    output_interval=size, parameters=parameters, config=config,
                    source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                    instantiated_fmr_sha256=fmr_hash,
                    toolchain=provenance, elapsed_seconds=time.monotonic()-started)
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids", type=int, nargs="+", default=[16, 32, 64])
    parser.add_argument("--charts", nargs="+", choices=CHARTS, default=list(CHARTS))
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument("--step-factor", type=int, default=4)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/kinetic_coordinates")
    parser.add_argument("--reuse-normalized", action="store_true",
                        help="reuse this directory's generated FMR after verifying the source hash")
    args = parser.parse_args()
    if min(args.grids) < 8 or args.step_factor < 1:
        parser.error("grids must be at least 8 and step-factor positive")
    base = args.output.resolve()
    source_hash = hashlib.sha256((HERE / (NAME + ".fme")).read_bytes()).hexdigest()
    normalized = base / "normalized"
    marker = normalized / "source.sha256"
    provenance = toolchain()
    provenance_path = normalized / "toolchain.json"
    if args.reuse_normalized:
        if marker.read_text().strip() != source_hash:
            raise ValueError("FME changed; normalize again")
        if json.loads(provenance_path.read_text()) != provenance:
            raise ValueError("toolchain changed; normalize again")
        generated = (normalized / (NAME + ".fmr")).read_text()
    else:
        generated = normalize(normalized)
        marker.write_text(source_hash + "\n")
        provenance_path.write_text(json.dumps(provenance, indent=2) + "\n")
    for size in args.grids:
        executable, config, fmr_hash = build(base, generated, size)
        for scenario in args.scenarios:
            for chart in args.charts:
                print(f"{scenario} {chart} {size}x{size}", flush=True)
                run(base, executable, config, fmr_hash, scenario, chart, size,
                    args.step_factor, provenance)


if __name__ == "__main__":
    main()
