#!/usr/bin/env python3
"""Ordinary-pipeline builds and sequential free-surface runs; no model updates."""
import argparse
import csv
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "kinetic_surface"
module = importlib.util.spec_from_file_location("kinetic_build_tools", HERE.parent / "kinetic_coordinates/run.py")
helpers = importlib.util.module_from_spec(module)
module.loader.exec_module(helpers)
CHARTS = {"cartesian": (0, 0), "mapped": (0.2, 0.15)}
REDUCTIONS = ["elapsed = max elapsed", "waterMass = sum waterMass", "surfaceMode = sum surfaceMode",
              "surfaceMean = sum surfaceMean", "surfaceMaximum = max surfaceMaximum", "speed = max speed",
              "lowest = min lowest", "collisionResidual = max collisionResidual", "forceResidual = max forceResidual",
              "wallMassFlux = max wallMassFlux", "surfaceStressError = max surfaceStressError",
              "surfaceShearError = max surfaceShearError", "couplingError = max couplingError",
              "crossingTime = max crossingTime", "period = max period", "periodError = max periodError",
              "referencePeriod = max referencePeriod", "minArea = min minArea"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(base):
    helpers.call(["cabal", "run", "-v0", "formurae-pre", "--", HERE / f"{NAME}.fme"], base, "pre", base / f"{NAME}.egi")
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    helpers.call([ROOT / "tools/run_formurae_normalization.sh", egison, base / f"{NAME}.egi"], base, "egison", base / f"{NAME}.feir")
    helpers.call(["cabal", "run", "-v0", "formurae-post", "--", base / f"{NAME}.feir"], base, "post", base / f"{NAME}.fmr")


def build(base, size):
    directory = base / f"grid-{size}"
    directory.mkdir(exist_ok=True)
    fmr = (base / f"{NAME}.fmr").read_text()
    for key, name in enumerate(("warpX", "warpY", "scenario", "gravity", "timeScale", "boundarySlope")):
        fmr, count = re.subn(r"^double :: " + name + r" = .*$", f"double :: {name} = surfaceConfig({key})", fmr, flags=re.M)
        assert count == 1
    (directory / f"{NAME}.fmr").write_text(fmr)
    (directory / f"{NAME}.yaml").write_text(
        f"length_per_node: [{2*math.pi!r}, {math.pi*(size//2+2)/(size//2)!r}]\n"
        f"grid_per_node: [{size}, {size//2+2}]\nmpi_shape: [1, 1]\nboundary: [periodic, fixed 0.0]\n"
        + "reduces: [" + ", ".join(REDUCTIONS) + "]\n")
    helpers.call([os.environ.get("FORMURA", str(ROOT / "bin/formura")), f"{NAME}.fmr"], directory, "formura", cwd=directory)
    driver = directory / "driver.c"
    shutil.copyfile(HERE / "driver.c", driver)
    cc = [os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(ROOT / "mpistub"),
          "-I" + str(directory), "-include", HERE / "config.h"]
    helpers.call([*cc, "-c", directory / f"{NAME}.c", "-o", directory / "solver.o"], directory, "cc-solver")
    helpers.call([*cc, driver, directory / "solver.o", "-lm", "-o", directory / "run"], directory, "cc-driver")
    fields = ("surface", "velocityX", "velocityY", "densityDeviation")
    definitions = [f'-DHDR="{NAME}.h"', "-DDIM=2", "-DFRAME_FIELDS=4", f"-DFRAME_EVERY={4*size}"]
    definitions += [f"-DF{k}=formura_data.{field}[i][j]" for k, field in enumerate(fields, 1)]
    helpers.call([*cc, *definitions, "-include", ROOT / "gallery/tools/field_frames.h", "-c", driver,
                  "-o", directory / "record.o"], directory, "cc-recorder")
    helpers.call([cc[0], directory / "record.o", directory / "solver.o", "-lm", "-o", directory / "record"], directory, "cc-link")
    return directory


def simulate(directory, size, chart, scenario, gravity=0.02, time_scale=1, factor=320, record=False, boundary_slope=1):
    case = f"{chart}-{scenario}-g{gravity}-dt{time_scale}-b{boundary_slope}"
    output = directory / case
    output.mkdir(exist_ok=True)
    steps = int(factor*size/time_scale)
    args = [steps, max(1, int(2*size/time_scale)), *CHARTS[chart], 0 if scenario == "rest" else 1, gravity, time_scale, boundary_slope]
    print(size, case, steps, flush=True)
    env = dict(os.environ)
    if record:
        raw = output / "raw"
        raw.mkdir(exist_ok=True)
        for file in raw.glob("*.bin"):
            file.unlink()
        env["FORMURAE_FRAME_DIR"] = str(raw)
    text = subprocess.check_output([str(directory / ("record" if record else "run")), *map(str, args)],
                                   cwd=directory, env=env, text=True)
    recorder_check = None
    if record and size == 16:
        baseline = subprocess.check_output([str(directory / "run"), *map(str, args)], cwd=directory, text=True)
        assert baseline == text, "recording changed diagnostic output"
        recorder_check = True
    (output / "diagnostics.csv").write_text(text)
    rows = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(io.StringIO(text))]
    assert rows and all(math.isfinite(v) for r in rows for v in r.values()), case
    drift = max(abs(r["waterMass"]-rows[0]["waterMass"])/rows[0]["waterMass"] for r in rows)
    if record:
        files = sorted(raw.glob("*.bin"))
        updates = np.array([int(p.stem) for p in files])
        np.testing.assert_array_equal(updates, np.arange(0, 2*steps+1, 4*size))
        values = np.stack([np.fromfile(p, dtype=np.float64).reshape(4, size//2+2, size) for p in files])
        assert np.isfinite(values).all()
        np.savez_compressed(output / "frames.npz", fields=values, updates=updates,
                            time=updates*time_scale*0.025*(2*math.pi/size)/2)
        for file in files:
            file.unlink()
        raw.rmdir()
    result = dict(grid=[size, size//2], chart=chart, scenario=scenario, gravity=gravity, time_scale=time_scale,
                  factor=factor, boundary_slope=boundary_slope, arguments=args, mass_drift=drift, final=rows[-1],
                  history=rows, csv=str((output / "diagnostics.csv").relative_to(directory.parent)),
                  diagnostics_sha256=digest(output / "diagnostics.csv"), recorder_check=recorder_check)
    if record:
        result["frames_sha256"] = digest(output / "frames.npz")
    print(json.dumps(dict(mass_drift=drift, final=rows[-1])), flush=True)
    return result


def verify(record, finest):
    rows = record["history"]
    assert record["mass_drift"] < 2e-11
    assert rows[-1]["lowest"] > 0 and min(r["minArea"] for r in rows) > 0
    for key in ("collisionResidual", "forceResidual", "wallMassFlux", "surfaceStressError", "surfaceShearError", "couplingError"):
        assert max(r[key] for r in rows) < 2e-12, (key, record["grid"], rows[-1])
    assert abs(rows[-1]["elapsed"] - record["factor"]*0.025*2*math.pi) < 1e-9
    if record["scenario"] == "rest" or record["gravity"] == 0:
        assert max(r["speed"] for r in rows) < 2e-12
        assert max(abs(r["surfaceMode"]-rows[0]["surfaceMode"]) for r in rows) < 2e-12
    else:
        assert min(r["surfaceMode"] for r in rows) < -0.002
        assert rows[-1]["surfaceMode"] > 0
        assert max(r["surfaceMaximum"] for r in rows) <= 1.05*rows[0]["surfaceMaximum"]
        assert rows[-1]["period"] > 0
        if record["boundary_slope"] == 1 and record["grid"][0] == finest:
            assert rows[-1]["periodError"] < 0.05, rows[-1]


def compare(records, grids):
    def wave(size, chart, dt=1, boundary=1):
        return next(r for r in records if r["grid"][0] == size and r["chart"] == chart
                    and r["scenario"] == "wave" and r["gravity"] == 0.02
                    and r["time_scale"] == dt and r["boundary_slope"] == boundary)
    gaps = []
    for size in grids:
        a, b = wave(size, "cartesian"), wave(size, "mapped")
        assert len(a["history"]) == len(b["history"])
        gaps.append(max(abs(x["surfaceMode"]-y["surfaceMode"])/0.01 for x, y in zip(a["history"], b["history"])))
    if len(grids) > 1:
        assert gaps[-1] < gaps[0]/2, gaps
    if max(grids) >= 64:
        assert gaps[-1] < 0.02, gaps
    checks = dict(chart_amplitude_gaps=gaps)
    if 32 in grids:
        for chart in CHARTS:
            improved, control = wave(32, chart), wave(32, chart, boundary=0)
            assert improved["final"]["periodError"] < control["final"]["periodError"]
            checks[chart+"-boundary-period-errors"] = [control["final"]["periodError"], improved["final"]["periodError"]]
    if 64 in grids:
        for chart in CHARTS:
            a, b = wave(64, chart), wave(64, chart, dt=0.5)
            assert len(a["history"]) == len(b["history"])
            gap = max(abs(x["surfaceMode"]-y["surfaceMode"])/0.01 for x, y in zip(a["history"], b["history"]))
            assert gap < 0.001, gap
            checks[chart+"-half-step-amplitude-gap"] = gap
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids", type=int, nargs="+", default=[16, 32, 64, 96])
    parser.add_argument("--reuse-normalized", action="store_true")
    parser.add_argument("--reuse-runs", action="store_true", help="reuse saved runs with matching model, toolchain, arguments and output hashes")
    parser.add_argument("--probe", action="store_true")
    args = parser.parse_args()
    if args.grids != sorted(set(args.grids)) or min(args.grids) < 16 or any(n % 2 for n in args.grids):
        parser.error("use increasing distinct even grid sizes, at least 16")
    base = ROOT / ".build/kinetic-surface"
    base.mkdir(exist_ok=True)
    identity = dict(source_sha256=digest(HERE / f"{NAME}.fme"), toolchain=helpers.toolchain())
    marker = base / "normalization.json"
    if args.reuse_normalized:
        assert json.loads(marker.read_text()) == identity
    else:
        normalize(base)
        marker.write_text(json.dumps(identity, indent=2)+"\n")
    cached = []
    reused = []
    prior = None
    if args.reuse_runs:
        previous = base / "probe.json"
        cache = json.loads(previous.read_text())
        for key, value in identity.items():
            assert cache[key] == value, f"cached run {key} changed"
        for key, path in (("driver_sha256", HERE / "driver.c"), ("config_sha256", HERE / "config.h")):
            assert cache[key] == digest(path), f"cached run {key} changed"
        for suffix, value in cache["generated"].items():
            assert value == digest(base / f"{NAME}.{suffix}"), "normalized solver changed"
        cached = cache["runs"]
        prior = dict(report_sha256=digest(previous), orchestration_sha256=cache["orchestration_sha256"])
        archive = base / ("previous-" + prior["report_sha256"] + ".json")
        shutil.copyfile(previous, archive)
    records = []
    built = set()

    def run_case(size, chart, scenario, gravity=0.02, time_scale=1, factor=320, record=False, boundary_slope=1):
        steps = int(factor*size/time_scale)
        expected = [steps, max(1, int(2*size/time_scale)), *CHARTS[chart],
                    0 if scenario == "rest" else 1, gravity, time_scale, boundary_slope]
        matches = [r for r in cached if r["grid"] == [size, size//2] and r["chart"] == chart
                   and r["scenario"] == scenario and r["arguments"] == expected]
        if matches:
            assert len(matches) == 1
            saved = matches[0]
            csv_path = base / saved["csv"]
            assert digest(csv_path) == saved["diagnostics_sha256"], "cached diagnostics changed"
            with csv_path.open() as stream:
                rows = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(stream)]
            assert rows == saved["history"] and rows[-1] == saved["final"]
            assert all(math.isfinite(v) for r in rows for v in r.values())
            if record:
                assert digest(csv_path.with_name("frames.npz")) == saved["frames_sha256"], "cached frames changed"
                if size == 16:
                    assert saved["recorder_check"] is True
            reused.append(saved["csv"])
            print("reuse", size, chart, scenario, gravity, time_scale, boundary_slope, flush=True)
            return saved
        if size not in built:
            build(base, size)
            built.add(size)
        return simulate(base / f"grid-{size}", size, chart, scenario, gravity, time_scale, factor, record, boundary_slope)

    for size in args.grids:
        for chart in CHARTS:
            if args.probe or size == 32:
                records.append(run_case(size, chart, "rest", factor=10 if args.probe else 320))
            records.append(run_case(size, chart, "wave", factor=320, record=True))
            if not args.probe and size == 32:
                records.append(run_case(size, chart, "wave", gravity=0))
                records.append(run_case(size, chart, "wave", boundary_slope=0))
            if not args.probe and size == 64:
                records.append(run_case(size, chart, "wave", time_scale=0.5))
    report = dict(**identity, driver_sha256=digest(HERE / "driver.c"), config_sha256=digest(HERE / "config.h"),
                  orchestration_sha256=digest(Path(__file__)),
                  generated={suffix: digest(base / f"{NAME}.{suffix}") for suffix in ("egi", "feir", "fmr")}, runs=records,
                  reuse=dict(prior=prior, diagnostics=reused), period_check_grid=max(args.grids))
    # Preserve results before checks as an audit trail if an accuracy check fails.
    (base / "probe.json").write_text(json.dumps(report, indent=2)+"\n")
    if not args.probe:
        for record in records:
            verify(record, max(args.grids))
        report["checks"] = compare(records, args.grids)
        report["passed"] = True
        (HERE / "results/verification.json").write_text(json.dumps(report, indent=2)+"\n")
        for suffix in ("egi", "feir", "fmr"):
            shutil.copyfile(base / f"{NAME}.{suffix}", HERE / f"{NAME}.{suffix}")
        print(json.dumps(report["checks"], indent=2))


if __name__ == "__main__":
    main()
