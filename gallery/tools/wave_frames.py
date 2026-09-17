#!/usr/bin/env python3
"""Record generated fields, keeping every existing simulation driver unchanged.

All builds and executions are sequential. Cached normalization is reused only
when its FME and toolchain identity match. Otherwise use the ordinary pipeline.
An uninstrumented run must produce exactly the same diagnostics as recording.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / ".build/wave-visualizations"
TOOLS = Path(__file__).resolve().parent
MODELS = ("shallowwater", "lbm_d3q19", "kinetic_coordinates", "kinetic_fv",
          "kinetic_viscosity", "kinetic_hydrostatic")


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "examples" / name / "run.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


helpers = module("kinetic_coordinates")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def settings(name):
    # Driver arguments are exactly the existing verification configurations.
    # last / every count generated updates, not physical RK steps.
    if name == "shallowwater":
        return dict(grid=[256, 8, 8], dim=3, fields=["h"], every=4, last=400,
                    dt=0.05, stages=1, cases={"surface": [400]})
    if name == "lbm_d3q19":
        return dict(grid=[64, 4, 4], dim=3, fields=["velocity_down2"], every=10,
                    last=1000, dt=1, stages=1, cases={"shear": [1000]})
    if name == "kinetic_coordinates":
        return dict(grid=[64, 64], dim=2, fields=["f_down2"], every=6, last=768,
                    dt=0.1*2*math.pi/64, stages=3,
                    cases={"cartesian": [256, 64, 0, 0, 1], "curved": [256, 64, 0.2, 0.3, 1]})
    if name == "kinetic_fv":
        return dict(grid=[64, 64], dim=2, fields=["f_down2"], every=2, last=128,
                    dt=0.1*2*math.pi/64, stages=2,
                    cases={"upwind": [64, 0.2, 0.15, 2, 3], "muscl": [64, 0.2, 0.15, 2, 2]})
    if name == "kinetic_viscosity":
        return dict(grid=[64, 64], dim=2, fields=["mass", "momentumX", "momentumY"],
                    every=20, last=2560, dt=0.05*2*math.pi/64, stages=2,
                    cases={"cartesian": [1280, 0, 0, 2, 1, 0.008, 1],
                           "mapped": [1280, 0.2, 0.15, 2, 1, 0.008, 1]})
    if name == "kinetic_hydrostatic":
        return dict(grid=[32, 34], dim=2, fields=["densityError", "mass", "momentumX", "momentumY"],
                    every=10, last=1280, dt=0.05*2*math.pi/32, stages=2,
                    cases={"balanced": [640, 0.2, 0.15, 1, 0, 1],
                           "ordinary": [640, 0.2, 0.15, 0, 0, 1],
                           "disturbed": [640, 0.2, 0.15, 1, 1, 1]})
    raise ValueError(name)


def normalize(name, base, identity):
    marker = base / "normalization.json"
    if marker.exists() and json.loads(marker.read_text()) == identity:
        return
    # Existing verification caches already record source and compiler identity.
    old = ROOT / ".build" / name.replace("_", "-")
    old_marker = old / "normalization.json"
    if old_marker.exists() and json.loads(old_marker.read_text()) == identity:
        for extension in ("egi", "feir", "fmr"):
            shutil.copyfile(old / f"{name}.{extension}", base / f"{name}.{extension}")
        print(f"{name}: reuse verified normalization", flush=True)
    else:
        source = ROOT / "examples" / name / f"{name}.fme"
        helpers.call(["cabal", "run", "-v0", "formurae-pre", "--", source], base, "pre", base / f"{name}.egi")
        egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
        helpers.call([ROOT / "tools/run_formurae_normalization.sh", egison, base / f"{name}.egi"],
                     base, "egison", base / f"{name}.feir")
        helpers.call(["cabal", "run", "-v0", "formurae-post", "--", base / f"{name}.feir"],
                     base, "post", base / f"{name}.fmr")
    write_json(marker, identity)


def build(name, base, spec):
    here = ROOT / "examples" / name
    if name.startswith("kinetic_"):
        model = module(name)
        if name == "kinetic_coordinates":
            directory, _, _ = model.build(base, (base / f"{name}.fmr").read_text(), spec["grid"][0])
        else:
            directory = model.build(base, spec["grid"][0])
        driver = here / "driver.c"
    else:
        directory = base / "solver"
        directory.mkdir(exist_ok=True)
        shutil.copyfile(base / f"{name}.fmr", directory / f"{name}.fmr")
        shutil.copyfile(here / f"{name}.yaml", directory / f"{name}.yaml")
        helpers.call([os.environ.get("FORMURA", ROOT / "bin/formura"), f"{name}.fmr"],
                     directory, "formura", cwd=directory)
        driver = here / ("sw_check.c" if name == "shallowwater" else "lbm_check.c")
    # Quoted includes must resolve the freshly generated header, even if an
    # older generated header is present next to the original example driver.
    original_driver = driver
    driver = directory / "capture_driver.c"
    shutil.copyfile(original_driver, driver)
    flags = [os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(ROOT / "mpistub"), "-I" + str(directory)]
    if (here / "config.h").exists():
        flags += ["-include", str(here / "config.h")]
    # The generated solver must not see the driver function wrappers.
    helpers.call([*flags, "-c", directory / f"{name}.c", "-o", directory / "solver.o"], directory, "cc-solver")
    helpers.call([*flags, driver, directory / "solver.o", "-lm", "-o", directory / "baseline"], directory, "cc-baseline")
    definitions = [f'-DHDR="{name}.h"', f'-DDIM={spec["dim"]}',
                   f'-DFRAME_EVERY={spec["every"]}', f'-DFRAME_FIELDS={len(spec["fields"])}']
    suffix = "[i][j][k]" if spec["dim"] == 3 else "[i][j]"
    definitions += [f"-DF{index}=formura_data.{field}{suffix}" for index, field in enumerate(spec["fields"], 1)]
    helpers.call([*flags, *definitions, "-include", TOOLS / "field_frames.h", "-c", driver,
                  "-o", directory / "record.o"], directory, "cc-recorder")
    helpers.call([flags[0], directory / "record.o", directory / "solver.o", "-lm", "-o", directory / "record"],
                 directory, "cc-link")
    return directory, driver


def capture(name):
    spec = settings(name)
    assert spec["every"] % spec["stages"] == 0 and spec["last"] % spec["every"] == 0
    base = BUILD / name
    base.mkdir(parents=True, exist_ok=True)
    identity = dict(toolchain=helpers.toolchain(), source_sha256=sha(ROOT / "examples" / name / f"{name}.fme"))
    normalize(name, base, identity)
    directory, driver = build(name, base, spec)
    records = {}
    for case, arguments in spec["cases"].items():
        print(f"{name}: record {case}", flush=True)
        output = base / case
        output.mkdir(exist_ok=True)
        raw = output / "raw"
        raw.mkdir(exist_ok=True)
        for stale in raw.glob("*.bin"):
            stale.unlink()
        args = list(map(str, arguments))
        baseline = subprocess.check_output([str(directory / "baseline"), *args], cwd=directory)
        recorded = subprocess.check_output([str(directory / "record"), *args], cwd=directory,
                                           env=dict(os.environ, FORMURAE_FRAME_DIR=str(raw)))
        if recorded != baseline:
            raise AssertionError(f"recording changed {name}/{case} diagnostics")
        (output / "diagnostics.txt").write_bytes(recorded)
        # Reuse the existing numerical checks; their quantities are computed in FME.
        if name == "kinetic_viscosity":
            module(name).verify_output(recorded.decode(), 64, case, "shear")
        if name == "kinetic_hydrostatic":
            module(name).verify_output(recorded.decode(), 32, "mapped",
                                      "perturbation" if case == "disturbed" else "rest",
                                      balanced=0 if case == "ordinary" else 1)
        files = sorted(raw.glob("*.bin"))
        updates = np.array([int(p.stem) for p in files])
        expected = np.arange(0, spec["last"] + 1, spec["every"])
        np.testing.assert_array_equal(updates, expected)
        shape = (len(spec["fields"]), spec["grid"][1], spec["grid"][0])
        fields = np.stack([np.fromfile(p, dtype=np.float64).reshape(shape) for p in files])
        assert np.isfinite(fields).all()
        archive = output / "frames.npz"
        np.savez_compressed(archive, fields=fields, updates=updates,
                            time=updates * (spec["dt"] / spec["stages"]))
        records[case] = dict(arguments=arguments, frames=len(files), shape=list(fields.shape),
                             archive_sha256=sha(archive), diagnostics_sha256=hashlib.sha256(recorded).hexdigest(),
                             baseline_diagnostics_identical=True)
        for file in files:
            file.unlink()
        raw.rmdir()
    report = dict(model=name, **identity, settings=spec, cases=records,
                  byteorder=sys.byteorder, driver_sha256=sha(driver),
                  recorder_sha256=sha(TOOLS / "field_frames.h"),
                  capture_script_sha256=sha(Path(__file__)),
                  normalized_fmr_sha256=sha(base / f"{name}.fmr"),
                  instantiated_fmr_sha256=sha(directory / f"{name}.fmr"),
                  config_sha256=sha(directory / f"{name}.yaml"),
                  generated_c_sha256=sha(directory / f"{name}.c"))
    write_json(base / "capture.json", report)
    print(f"{name}: all frames finite, diagnostic outputs identical", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", nargs="*", metavar="MODEL", help="models to record; default: all six")
    args = parser.parse_args()
    if any(name not in MODELS for name in args.models):
        parser.error("choose models from: " + ", ".join(MODELS))
    for name in args.models or MODELS:
        capture(name)
