#!/usr/bin/env python3
"""Sequential ordinary-pipeline builds and verification of FME diagnostics."""
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
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "kinetic_viscosity"
# Share configuration-independent build/log/provenance utilities only.
module = importlib.util.spec_from_file_location("kinetic_build_tools", HERE.parent / "kinetic_coordinates/run.py")
helpers = importlib.util.module_from_spec(module)
module.loader.exec_module(helpers)
CHARTS = {"cartesian": (0, 0), "mapped": (0.2, 0.15)}
METHODS = {0: "upwind", 1: "muscl"}
SCENARIOS = {"uniform": 0, "relaxation": 1, "shear": 2}
ZETAS = (0.002, 0.008, 0.02)
REDUCTIONS = ["elapsed = max elapsed", "mass = sum mass", "momentumX = sum momentumX", "momentumY = sum momentumY",
              "mode = sum mode", "referenceMode = sum referenceMode", "modeError = sum modeError",
              "velocityError = max velocityError", "velocityErrorL1 = sum velocityErrorL1",
              "populationError = max populationError", "densityError = max densityError", "lowest = min lowest",
              "equilibriumLowest = min equilibriumLowest", "cfl = max cfl", "positivityBound = max positivityBound",
              "collisionResidual = max collisionResidual", "minArea = min minArea",
              "relaxationTime = max relaxationTime", "decayRate = max decayRate", "hydrodynamicViscosity = max hydrodynamicViscosity"]


def normalize(base):
    source = HERE / (NAME + ".fme")
    helpers.call(["cabal", "run", "-v0", "formurae-pre", "--", source], base, "pre", base / (NAME + ".egi"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    helpers.call([ROOT / "tools/run_formurae_normalization.sh", egison, base / (NAME + ".egi")],
                 base, "egison", base / (NAME + ".feir"))
    helpers.call(["cabal", "run", "-v0", "formurae-post", "--", base / (NAME + ".feir")],
                 base, "post", base / (NAME + ".fmr"))


def build(base, size):
    directory = base / f"grid-{size}"
    directory.mkdir(exist_ok=True)
    generated = (base / (NAME + ".fmr")).read_text()
    for key, name in enumerate(("warpX", "warpY", "scenario", "method", "zeta", "timeScale")):
        generated, count = re.subn(r"^double :: " + name + r" = .*$",
                                  f"double :: {name} = viscosityConfig({key})", generated, flags=re.MULTILINE)
        if count != 1:
            raise ValueError(f"missing generated parameter {name}")
    (directory / (NAME + ".fmr")).write_text(generated)
    (directory / (NAME + ".yaml")).write_text(
        "length_per_node: [6.283185307179586, 6.283185307179586]\n"
        f"grid_per_node: [{size}, {size}]\nmpi_shape: [1, 1]\nboundary: [periodic, periodic]\n"
        + "reduces: [" + ", ".join(REDUCTIONS) + "]\n")
    helpers.call([os.environ.get("FORMURA", str(ROOT / "bin/formura")), NAME + ".fmr"],
                 directory, "formura", cwd=directory)
    helpers.call([os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(ROOT / "mpistub"),
                  "-I" + str(directory), "-include", HERE / "config.h", HERE / "driver.c",
                  directory / (NAME + ".c"), "-lm", "-o", directory / "run"], directory, "cc")
    return directory


def simulate(directory, size, chart, scenario, method=1, zeta=0.008, time_scale=1):
    print(size, chart, scenario, METHODS[method], zeta, time_scale, flush=True)
    steps = int((20 if scenario == "shear" else 2)*size/time_scale)
    arguments = [steps, *CHARTS[chart], SCENARIOS[scenario], method, zeta, time_scale]
    result = subprocess.run([str(directory / "run"), *map(str, arguments)],
                            cwd=directory, capture_output=True, text=True, check=True)
    filename = f"{chart}-{scenario}-{METHODS[method]}-z{zeta}-dt{time_scale}.csv"
    (directory / filename).write_text(result.stdout)
    return verify_output(result.stdout, size, chart, scenario, method, zeta, time_scale)


def verify_output(output, size, chart, scenario, method=1, zeta=0.008, time_scale=1):
    """Check saved FME diagnostics without rerunning the simulation."""
    steps = int((20 if scenario == "shear" else 2)*size/time_scale)
    rows = [{key: float(value) for key, value in row.items()}
            for row in csv.DictReader(io.StringIO(output))]
    assert len(rows) == 2*steps+1 and all(math.isfinite(v) for row in rows for v in row.values())
    filename = f"{chart}-{scenario}-{METHODS[method]}-z{zeta}-dt{time_scale}.csv"
    drift = max(abs(r["mass"]-rows[0]["mass"])/rows[0]["mass"] for r in rows)
    momentum = max(abs(r[key]-rows[0][key]) for r in rows for key in ("momentumX", "momentumY"))
    record = dict(grid=size, chart=chart, scenario=scenario, method=METHODS[method], zeta=zeta,
                  time_scale=time_scale, generated_updates=2*steps, mass_drift=drift, momentum_drift=momentum,
                  final=rows[-1], max_cfl=max(r["cfl"] for r in rows),
                  max_positivity_bound=max(r["positivityBound"] for r in rows),
                  history=[r for r in rows if int(r["update"]) % (2*max(1,steps//64)) == 0 or r is rows[-1]], csv=filename)
    assert drift < 2e-11 and momentum < 2e-11, record["final"]
    assert record["max_positivity_bound"] < 1, record["final"]
    assert min(r["minArea"] for r in rows) > 0
    assert rows[-1]["lowest"] >= -1e-12 and rows[-1]["equilibriumLowest"] >= 0
    assert rows[-1]["collisionResidual"] < 1e-12
    assert rows[-1]["densityError"] < 0.01
    assert abs(rows[-1]["time"] - (2*math.pi if scenario=="shear" else 0.2*math.pi)) < 1e-11
    if scenario == "uniform":
        assert rows[-1]["populationError"] < 2e-12
        assert rows[-1]["velocityError"] < 2e-12
    if scenario == "shear":
        assert 0 < rows[-1]["mode"] < rows[0]["mode"]
    return record


def verify_convergence(records, grids):
    orders = {}
    if len(grids) < 2:
        return orders
    for chart in CHARTS:
        relaxation = [r for r in records if r["chart"]==chart and r["scenario"]=="relaxation"]
        orders[f"{chart}-relaxation"] = [math.log(a["final"]["populationError"]/b["final"]["populationError"])/math.log(b["grid"]/a["grid"])
                                           for a,b in zip(relaxation,relaxation[1:])]
        assert orders[f"{chart}-relaxation"][-1] > 1.8
        for zeta in ZETAS:
            shear = [r for r in records if r["chart"]==chart and r["scenario"]=="shear"
                     and r["method"]=="muscl" and r["zeta"]==zeta and r["time_scale"]==1]
            for norm in ("velocityError", "velocityErrorL1"):
                key=f"{chart}-z{zeta}-{norm}"
                orders[key]=[math.log(a["final"][norm]/b["final"][norm])/math.log(b["grid"]/a["grid"])
                             for a,b in zip(shear,shear[1:])]
                assert orders[key][-1] > 1, (key,orders[key])
            for fine in (r for r in shear if r["grid"] >= 64):
                assert abs(fine["final"]["modeError"]) < 0.03
                assert fine["final"]["velocityErrorL1"] < 0.02*0.02
    for zeta in ZETAS:
        gaps=[]
        for size in grids:
            same={r["chart"]:r for r in records if r["grid"]==size and r["zeta"]==zeta
                  and r["scenario"]=="shear" and r["method"]=="muscl" and r["time_scale"]==1}
            # Compare errors against each chart's own quadrature projection.
            gaps.append(abs(same["mapped"]["final"]["modeError"]-same["cartesian"]["final"]["modeError"]))
        assert gaps[-1] < gaps[0], (zeta,gaps)
        orders[f"chart-gap-z{zeta}"]=gaps
    if 64 in grids:
        for chart in CHARTS:
            baseline=next(r for r in records if r["grid"]==64 and r["chart"]==chart and r["scenario"]=="shear"
                          and r["method"]=="muscl" and r["zeta"]==0.008 and r["time_scale"]==1)
            half=next(r for r in records if r["grid"]==64 and r["chart"]==chart and r["scenario"]=="shear" and r["time_scale"]==0.5)
            upwind=next(r for r in records if r["grid"]==64 and r["chart"]==chart and r["scenario"]=="shear" and r["method"]=="upwind")
            assert abs(baseline["final"]["modeError"]-half["final"]["modeError"]) < 0.001
            assert upwind["final"]["velocityErrorL1"] > 2*baseline["final"]["velocityErrorL1"]
    return orders


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids",type=int,nargs="+",default=[16,32,64,128])
    parser.add_argument("--reuse-normalized",action="store_true")
    args=parser.parse_args()
    if args.grids != sorted(set(args.grids)) or min(args.grids)<8:
        parser.error("use increasing distinct grid sizes of at least 8")
    base=ROOT/".build/kinetic-viscosity"
    base.mkdir(parents=True,exist_ok=True)
    identity=dict(toolchain=helpers.toolchain(),source_sha256=hashlib.sha256((HERE/(NAME+".fme")).read_bytes()).hexdigest())
    manifest=base/"normalization.json"
    if args.reuse_normalized:
        if not manifest.exists() or json.loads(manifest.read_text())!=identity:
            raise ValueError("normalization cache does not match source/toolchain")
    else:
        normalize(base)
        manifest.write_text(json.dumps(identity,indent=2)+"\n")
    records=[]
    for size in args.grids:
        directory=build(base,size)
        for chart in CHARTS:
            for scenario in ("uniform","relaxation"):
                records.append(simulate(directory,size,chart,scenario))
            for zeta in ZETAS:
                records.append(simulate(directory,size,chart,"shear",zeta=zeta))
            records.append(simulate(directory,size,chart,"shear",method=0))
            if size==64:
                records.append(simulate(directory,size,chart,"shear",time_scale=0.5))
    orders=verify_convergence(records,args.grids)
    (HERE/"results").mkdir(exist_ok=True)
    report=dict(**identity,runs=records,orders=orders)
    (HERE/"results/verification.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(dict(runs=len(records),orders=orders),indent=2))


if __name__=="__main__":
    main()
