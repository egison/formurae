#!/usr/bin/env python3
"""Sequential normal-pipeline checks of shared D2Q9/material mass transport."""
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
NAME = "kinetic_transport"
spec = importlib.util.spec_from_file_location("kinetic_tools", HERE.parent / "kinetic_coordinates/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
CHARTS = {"cartesian": (0, 0), "mapped": (0.06, 0.045)}
PARAMETERS = ("warpX", "warpY", "scenario", "shape", "method", "timeScale")
CASES = {"rest": (0, 1, 1), "constant": (2, 0, 2), "translation": (1, 2, 1), "coupled": (2, 1, 2)}
BASE = ROOT/".build/kinetic-transport"

def frame_interval(n):
    return n  # completed SSPRK2 states, every 0.025 physical time at timeScale=1


REDUCTIONS = 'elapsed = max elapsed, totalMass = sum totalMass, waterMass = sum waterMass, waterVolume = sum waterVolume, momentumX = sum momentumX, momentumY = sum momentumY, lowest = min lowest, highest = max highest, densityLowest = min densityLowest, densityHighest = max densityHighest, populationLowest = min populationLowest, equilibriumLowest = min equilibriumLowest, collisionResidual = max collisionResidual, consistencyError = max consistencyError, fractionCourant = max fractionCourant, populationCourant = max populationCourant, stationaryError = max stationaryError, translationL1 = sum translationL1, translationMaximum = max translationMaximum, movedAmount = sum movedAmount, mixing = sum mixing, velocityChange = max velocityChange, minArea = min minArea'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(base):
    helpers.call(["cabal", "run", "-v0", "formurae-pre", "--", HERE / f"{NAME}.fme"], base, "pre", base / f"{NAME}.egi")
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    helpers.call([ROOT / "tools/run_formurae_normalization.sh", egison, base / f"{NAME}.egi"], base, "egison", base / f"{NAME}.feir")
    helpers.call(["cabal", "run", "-v0", "formurae-post", "--", base / f"{NAME}.feir"], base, "post", base / f"{NAME}.fmr")


def build(base, n):
    directory = base / f"grid-{n}"
    directory.mkdir(exist_ok=True)
    source = (base / f"{NAME}.fmr").read_text()
    for key, name in enumerate(PARAMETERS):
        source, count = re.subn(r"^double :: " + name + r" = .*$", f"double :: {name} = transportConfig({key})", source, flags=re.M)
        assert count == 1
    (directory / f"{NAME}.fmr").write_text(source)
    (directory / f"{NAME}.yaml").write_text(f"length_per_node: [1, 1]\ngrid_per_node: [{n}, {n}]\nmpi_shape: [1, 1]\nboundary: [periodic, periodic]\nreduces: [{REDUCTIONS}]\n")
    helpers.call([os.environ.get("FORMURA", str(ROOT / "bin/formura")), f"{NAME}.fmr"], directory, "formura", cwd=directory)
    shutil.copyfile(HERE / "driver.c", directory / "driver.c")
    cc = [os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I"+str(ROOT / "mpistub"), "-I"+str(directory), "-include", HERE / "config.h"]
    helpers.call([*cc, "-c", directory / f"{NAME}.c", "-o", directory / "solver.o"], directory, "cc-solver")
    helpers.call([*cc, directory / "driver.c", directory / "solver.o", "-lm", "-o", directory / "run"], directory, "cc-driver")
    definitions = [f'-DHDR="{NAME}.h"', "-DDIM=2", "-DFRAME_FIELDS=4", f"-DFRAME_EVERY={frame_interval(n)}", "-DF1=formura_data.fraction[i][j]", "-DF2=formura_data.density[i][j]", "-DF3=formura_data.velocityX[i][j]", "-DF4=formura_data.velocityY[i][j]"]
    helpers.call([*cc, *definitions, "-include", ROOT / "gallery/tools/field_frames.h", "-c", directory / "driver.c", "-o", directory / "record.o"], directory, "cc-recorder")
    helpers.call([cc[0], directory / "record.o", directory / "solver.o", "-lm", "-o", directory / "record"], directory, "cc-link")
    return directory

def simulate(directory, n, chart, case, method=1, time_scale=1, record=False):
    scenario, shape, duration = CASES[case]
    label = f"{chart}-{case}-m{method}-dt{time_scale}"
    output = directory/label
    output.mkdir(exist_ok=True)
    steps = int(duration*20*n/time_scale)
    arguments = [steps, int(n/time_scale), *CHARTS[chart], scenario, shape, method, time_scale]
    env = dict(os.environ)
    if record:
        raw = output/"raw"
        raw.mkdir(exist_ok=True)
        for path in raw.glob("*.bin"):
            path.unlink()
        env["FORMURAE_FRAME_DIR"] = str(raw)
    print(n, label, flush=True)
    text = subprocess.check_output([str(directory/("record" if record else "run")), *map(str, arguments)], text=True, cwd=directory, env=env)
    recorder_check = None
    if record and n == 16:
        baseline = subprocess.check_output([str(directory/"run"), *map(str, arguments)], text=True, cwd=directory)
        assert baseline == text, "recorder altered diagnostic output"
        recorder_check = True
    (output/"diagnostics.csv").write_text(text)
    rows = [{k: float(v) for k,v in row.items()} for row in csv.DictReader(io.StringIO(text))]
    assert rows and all(math.isfinite(v) for row in rows for v in row.values())
    result = dict(grid=n, chart=chart, case=case, method=method, time_scale=time_scale, duration=duration,
        arguments=arguments, history=rows, final=rows[-1], recorder_check=recorder_check,
        csv=str((output/"diagnostics.csv").relative_to(directory.parent)), diagnostics_sha256=sha(output/"diagnostics.csv"),
        drifts={key:max(abs(row[key]-rows[0][key]) for row in rows) for key in ("totalMass","waterMass","momentumX","momentumY")})
    if record:
        files=sorted(raw.glob("*.bin"))
        updates=np.array([int(p.stem) for p in files])
        np.testing.assert_array_equal(updates,np.arange(0,2*steps+1,frame_interval(n)))
        values=np.stack([np.fromfile(p,dtype=np.float64).reshape(4,n,n) for p in files])
        assert np.isfinite(values).all()
        np.savez_compressed(output/"frames.npz", fields=values, updates=updates, time=updates*.05*time_scale/n/2)
        result["frames_sha256"]=sha(output/"frames.npz")
        for p in files:
            p.unlink()
        raw.rmdir()
    print(json.dumps(dict(drifts=result["drifts"],final=result["final"])),flush=True)
    return result


def verify(record):
    f,rows=record["final"],record["history"]
    assert all(v<2e-11 for v in record["drifts"].values()), record
    assert f["lowest"]>=-2e-12 and f["highest"]<=1+2e-12, f
    assert f["densityLowest"]>0 and f["populationLowest"]>0 and f["equilibriumLowest"]>0
    assert f["minArea"]>0
    assert 0<=f["fractionCourant"]<1 and 0<f["populationCourant"]<1, f
    assert f["collisionResidual"]<2e-12 and f["consistencyError"]<2e-12, f
    assert abs(f["elapsed"]-record["duration"])<1e-10
    if record["case"] in ("rest","constant"):
        assert f["stationaryError"]<5e-12, f
    if record["case"]=="rest":
        assert f["velocityChange"]<5e-12, f
    if record["case"]=="translation":
        assert f["velocityChange"]<5e-12, f
        assert abs(f["densityHighest"]-1)<5e-12 and abs(f["densityLowest"]-1)<5e-12, f
    if record["case"] in ("constant","coupled"):
        assert f["densityHighest"]-f["densityLowest"]>.1, f
        # Initial spatial variation alone must not satisfy this check:
        # at least one density extremum must also evolve beyond its initial range.
        excursion=max(f["densityHighest"]-rows[0]["densityHighest"],
                      rows[0]["densityLowest"]-f["densityLowest"])
        assert excursion>1e-4, f
        assert f["velocityChange"]>.03, f
    if record["case"]=="coupled":
        assert max(row["movedAmount"] for row in rows)>.03, f


def compare(records,grids):
    def find(n,chart,case,method=1,dt=1):
        return next(r for r in records if (r["grid"],r["chart"],r["case"],r["method"],r["time_scale"])==(n,chart,case,method,dt))
    checks={}
    for chart in CHARTS:
        errors=[find(n,chart,"translation")["final"]["translationL1"] for n in grids]
        assert all(b<.7*a for a,b in zip(errors,errors[1:])), errors
        assert errors[-1]<.003, errors
        checks[chart+"-translation-L1"]=errors
        high,low=find(64,chart,"translation"),find(64,chart,"translation",method=0)
        ratio=high["final"]["translationL1"]/low["final"]["translationL1"]
        assert ratio<.4, ratio
        checks[chart+"-high-to-upwind-error"]=ratio
        normal,half=find(32,chart,"coupled"),find(32,chart,"coupled",dt=.5)
        assert len(normal["history"])==len(half["history"])
        gap=max(abs(a["mixing"]-b["mixing"]) for a,b in zip(normal["history"],half["history"]))
        assert gap<1e-4,gap
        checks[chart+"-half-step-mixing-gap"]=gap
    gaps=[]
    for n in grids:
        a,b=find(n,"cartesian","coupled"),find(n,"mapped","coupled")
        assert len(a["history"])==len(b["history"])
        gaps.append(max(abs(x["mixing"]-y["mixing"]) for x,y in zip(a["history"],b["history"])))
    assert gaps[-1]<gaps[0]/2 and gaps[-1]<.01,gaps
    checks["chart-mixing-gaps"]=gaps
    checks["minimum-density-extrema-excursion"]=min(
        max(r["final"]["densityHighest"]-r["history"][0]["densityHighest"],
            r["history"][0]["densityLowest"]-r["final"]["densityLowest"])
        for r in records if r["case"] in ("constant","coupled"))
    return checks


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids",type=int,nargs="+",default=[16,32,64])
    parser.add_argument("--probe",action="store_true")
    parser.add_argument("--reuse-normalized",action="store_true")
    parser.add_argument("--reuse-runs",action="store_true")
    args=parser.parse_args()
    if args.grids!=sorted(set(args.grids)) or any(n<16 or n%4 for n in args.grids):
        parser.error("use increasing distinct multiples of four, at least 16")
    if not args.probe and args.grids!=[16,32,64]:
        parser.error("the published verification matrix uses grids 16 32 64")
    BASE.mkdir(parents=True,exist_ok=True)
    identity=dict(source_sha256=sha(HERE/f"{NAME}.fme"),toolchain=helpers.toolchain())
    marker=BASE/"normalization.json"
    if args.reuse_normalized:
        assert json.loads(marker.read_text())==identity
    else:
        normalize(BASE)
        marker.write_text(json.dumps(identity,indent=2)+"\n")
    cached=[]
    reused=[]
    if args.reuse_runs:
        cache=json.loads((BASE/"probe.json").read_text())
        for key,value in identity.items():
            assert cache[key]==value,f"cached {key} changed"
        for key,file in [("driver_sha256","driver.c"),("config_sha256","config.h")]:
            assert cache[key]==sha(HERE/file)
        for suffix,value in cache["generated"].items():
            assert value==sha(BASE/f"{NAME}.{suffix}")
        cached=cache["runs"]
    built=set()
    records=[]
    def run_case(n,chart,case,method=1,time_scale=1,record=False):
        scenario,shape,duration=CASES[case]
        expected=[int(duration*20*n/time_scale),int(n/time_scale),*CHARTS[chart],scenario,shape,method,time_scale]
        matches=[r for r in cached if (r["grid"],r["chart"],r["case"],r["arguments"])==(n,chart,case,expected)]
        if matches:
            assert len(matches)==1
            saved=matches[0]; path=BASE/saved["csv"]
            assert sha(path)==saved["diagnostics_sha256"]
            with path.open() as stream:
                rows=[{k:float(v) for k,v in row.items()} for row in csv.DictReader(stream)]
            assert rows==saved["history"] and rows[-1]==saved["final"]
            if record:
                assert sha(path.with_name("frames.npz"))==saved["frames_sha256"]
                if n==16:
                    assert saved["recorder_check"] is True
            reused.append(saved["csv"])
            print("reuse",n,chart,case,method,time_scale,flush=True)
            return saved
        if n not in built:
            build(BASE,n)
            built.add(n)
        return simulate(BASE/f"grid-{n}",n,chart,case,method,time_scale,record)
    for n in args.grids:
        for chart in CHARTS:
            if args.probe or n==32:
                for case in ("rest","constant"):
                    records.append(run_case(n,chart,case))
            for case in ("translation","coupled"):
                records.append(run_case(n,chart,case,record=True))
            if not args.probe and n==32:
                records.append(run_case(n,chart,"coupled",time_scale=.5))
            if not args.probe and n==64:
                records.append(run_case(n,chart,"translation",method=0))
    report=dict(**identity,driver_sha256=sha(HERE/"driver.c"),config_sha256=sha(HERE/"config.h"),
        orchestration_sha256=sha(Path(__file__)),generated={s:sha(BASE/f"{NAME}.{s}") for s in ("egi","feir","fmr")},
        runs=records,reused=reused)
    (BASE/"probe.json").write_text(json.dumps(report,indent=2)+"\n")
    for record in records:
        verify(record)
    if not args.probe:
        report["checks"]=compare(records,args.grids)
        report["passed"]=True
        (HERE/"results/verification.json").write_text(json.dumps(report,indent=2)+"\n")
        for suffix in ("egi","feir","fmr"):
            shutil.copyfile(BASE/f"{NAME}.{suffix}",HERE/f"{NAME}.{suffix}")
    print("PASS",len(records),"cases",flush=True)


if __name__=="__main__":
    main()
