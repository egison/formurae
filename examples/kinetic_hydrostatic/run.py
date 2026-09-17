#!/usr/bin/env python3
"""Sequential ordinary-pipeline builds and checks of saved FME diagnostics."""
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
NAME = "kinetic_hydrostatic"
module = importlib.util.spec_from_file_location("kinetic_build_tools", HERE.parent / "kinetic_coordinates/run.py")
helpers = importlib.util.module_from_spec(module)
module.loader.exec_module(helpers)
CHARTS = {"cartesian": (0, 0), "mapped": (0.2, 0.15)}
SCENARIOS = {"rest": 0, "perturbation": 1, "acceleration": 2}
REDUCTIONS = ["elapsed = max elapsed", "mass = sum mass", "momentumX = sum momentumX", "momentumY = sum momentumY",
              "speed = max speed", "densityError = max densityError", "densityMode = sum densityMode",
              "accelerationError = sum accelerationError", "lowest = min lowest", "equilibriumLowest = min equilibriumLowest",
              "collisionResidual = max collisionResidual", "forceResidual = max forceResidual",
              "wallMassFlux = max wallMassFlux", "wallTangentialFlux = max wallTangentialFlux", "minArea = min minArea"]


def normalize(base):
    helpers.call(["cabal", "run", "-v0", "formurae-pre", "--", HERE / (NAME + ".fme")], base, "pre", base / (NAME + ".egi"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    helpers.call([ROOT / "tools/run_formurae_normalization.sh", egison, base / (NAME + ".egi")], base, "egison", base / (NAME + ".feir"))
    helpers.call(["cabal", "run", "-v0", "formurae-post", "--", base / (NAME + ".feir")], base, "post", base / (NAME + ".fmr"))


def build(base, size):
    directory = base / f"grid-{size}"
    directory.mkdir(exist_ok=True)
    generated = (base / (NAME + ".fmr")).read_text()
    for key, name in enumerate(("warpX", "warpY", "balanced", "scenario", "timeScale")):
        generated, count = re.subn(r"^double :: " + name + r" = .*$",
                                  f"double :: {name} = hydrostaticConfig({key})", generated, flags=re.MULTILINE)
        if count != 1:
            raise ValueError(f"missing generated parameter {name}")
    (directory / (NAME + ".fmr")).write_text(generated)
    # N physical cells plus two guard rows; equal physical spacing hx=hy.
    (directory / (NAME + ".yaml")).write_text(
        f"length_per_node: [6.283185307179586, {2*math.pi*(size+2)/size!r}]\n"
        f"grid_per_node: [{size}, {size+2}]\nmpi_shape: [1, 1]\nboundary: [periodic, fixed 0.0]\n"
        + "reduces: [" + ", ".join(REDUCTIONS) + "]\n")
    helpers.call([os.environ.get("FORMURA", str(ROOT / "bin/formura")), NAME + ".fmr"], directory, "formura", cwd=directory)
    helpers.call([os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(ROOT / "mpistub"),
                  "-I" + str(directory), "-include", HERE / "config.h", HERE / "driver.c",
                  directory / (NAME + ".c"), "-lm", "-o", directory / "run"], directory, "cc")
    return directory


def filename(chart, scenario, balanced=1, time_scale=1, duration=1):
    return f"{chart}-{scenario}-balance{balanced}-dt{time_scale}-duration{duration}.csv"


def cases(size):
    result=[("rest",1,1,1),("rest",0,1,1),("perturbation",1,1,1)]
    if size==32:
        result.append(("rest",1,1,4))
    if size==64:
        result.extend([("perturbation",1,0.5,1),("acceleration",1,1,1)])
    return result


def execution_identity(identity):
    return dict(**identity, orchestration_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                driver_sha256=hashlib.sha256((HERE/"driver.c").read_bytes()).hexdigest(),
                config_sha256=hashlib.sha256((HERE/"config.h").read_bytes()).hexdigest())


def simulate(directory, size, chart, scenario, balanced=1, time_scale=1, duration=1):
    print(size, chart, scenario, balanced, time_scale, duration, flush=True)
    steps = int(20*size*duration/time_scale)
    arguments = [steps, *CHARTS[chart], balanced, SCENARIOS[scenario], time_scale]
    result = subprocess.run([str(directory / "run"), *map(str, arguments)], cwd=directory, capture_output=True, text=True, check=True)
    (directory / filename(chart,scenario,balanced,time_scale,duration)).write_text(result.stdout)
    return verify_output(result.stdout,size,chart,scenario,balanced,time_scale,duration)


def verify_output(output, size, chart, scenario, balanced=1, time_scale=1, duration=1):
    steps = int(20*size*duration/time_scale)
    rows = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(io.StringIO(output))]
    assert len(rows)==2*steps+1 and all(math.isfinite(v) for r in rows for v in r.values())
    drift=max(abs(r["mass"]-rows[0]["mass"])/rows[0]["mass"] for r in rows)
    speed=max(r["speed"] for r in rows)
    density=max(r["densityError"] for r in rows)
    assert drift<2e-11, ("mass", drift, rows[-1])
    assert rows[-1]["lowest"]>=-1e-12 and rows[-1]["equilibriumLowest"]>=0
    assert min(r["minArea"] for r in rows)>0
    for key in ("collisionResidual", "forceResidual", "wallMassFlux", "wallTangentialFlux"):
        assert rows[-1][key]<1e-12, (key,rows[-1])
    assert abs(rows[-1]["time"]-2*math.pi*duration)<1e-10
    if scenario=="rest" and balanced:
        assert speed<2e-12 and density<2e-12
    if scenario=="perturbation":
        assert speed>1e-5, "perturbation must generate motion"
        assert abs(rows[-1]["densityMode"]-rows[0]["densityMode"])>abs(rows[0]["densityMode"])*0.1
    if scenario=="acceleration":
        assert max(abs(r["accelerationError"]) for r in rows)<2e-12
        assert rows[-1]["momentumX"]>0.005*rows[-1]["mass"]
    return dict(grid=size,chart=chart,scenario=scenario,balanced=balanced,time_scale=time_scale,duration=duration,
                generated_updates=2*steps,mass_drift=drift,max_speed=speed,max_density_error=density,final=rows[-1],
                history=[r for r in rows if int(r["update"])%(2*max(1,steps//80))==0 or r is rows[-1]],
                csv=filename(chart,scenario,balanced,time_scale,duration))


def verify_refinement(records, grids):
    checks={}
    for chart in CHARTS:
        control=sorted((r for r in records if r["chart"]==chart and not r["balanced"]),key=lambda r:r["grid"])
        if len(control)>1:
            assert control[-1]["max_speed"]<control[0]["max_speed"]
        checks[chart+"-ordinary-rest-speed"]=[r["max_speed"] for r in control]
        perturbation=sorted((r for r in records if r["chart"]==chart and r["scenario"]=="perturbation" and r["time_scale"]==1),key=lambda r:r["grid"])
        if len(perturbation)>2:
            gaps=[abs(a["final"]["densityMode"]-b["final"]["densityMode"]) for a,b in zip(perturbation,perturbation[1:])]
            assert gaps[-1]<gaps[0], (chart,gaps)
            checks[chart+"-perturbation-mode-differences"]=gaps
        if 64 in grids:
            baseline=next(r for r in perturbation if r["grid"]==64)
            half=next(r for r in records if r["chart"]==chart and r["time_scale"]==0.5)
            difference=abs(half["final"]["densityMode"]-baseline["final"]["densityMode"])
            assert difference<1e-7
            checks[chart+"-half-step-mode-difference"]=difference
    return checks


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids",type=int,nargs="+",default=[16,32,64])
    parser.add_argument("--reuse-normalized",action="store_true")
    parser.add_argument("--reuse-results",action="store_true",help="verify existing CSV files without compiling or running")
    args=parser.parse_args()
    if args.grids!=sorted(set(args.grids)) or min(args.grids)<8:
        parser.error("use increasing distinct grid sizes of at least 8")
    base=ROOT/".build/kinetic-hydrostatic"
    base.mkdir(parents=True,exist_ok=True)
    identity=dict(toolchain=helpers.toolchain(),source_sha256=hashlib.sha256((HERE/(NAME+".fme")).read_bytes()).hexdigest())
    manifest=base/"normalization.json"
    if args.reuse_normalized or args.reuse_results:
        if not manifest.exists() or json.loads(manifest.read_text())!=identity:
            raise ValueError("normalization cache does not match source/toolchain")
    else:
        normalize(base)
        manifest.write_text(json.dumps(identity,indent=2)+"\n")
    executed=execution_identity(identity)
    records=[]
    for size in args.grids:
        directory=base/f"grid-{size}" if args.reuse_results else build(base,size)
        if args.reuse_results:
            if json.loads((directory/"identity.json").read_text())!=executed:
                raise ValueError("saved runs do not match source/toolchain")
        for chart in CHARTS:
            for scenario,balanced,time_scale,duration in cases(size):
                if args.reuse_results:
                    output=(directory/filename(chart,scenario,balanced,time_scale,duration)).read_text()
                    records.append(verify_output(output,size,chart,scenario,balanced,time_scale,duration))
                else:
                    records.append(simulate(directory,size,chart,scenario,balanced,time_scale,duration))
        if not args.reuse_results:
            (directory/"identity.json").write_text(json.dumps(executed,indent=2)+"\n")
    checks=verify_refinement(records,args.grids)
    (HERE/"results").mkdir(exist_ok=True)
    report=dict(**executed,runs=records,checks=checks)
    (HERE/"results/verification.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(dict(runs=len(records),checks=checks),indent=2))


if __name__=="__main__":
    main()
