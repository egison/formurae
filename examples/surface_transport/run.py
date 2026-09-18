#!/usr/bin/env python3
"""Sequential ordinary-pipeline builds and checks of FME interface transport."""
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
NAME = "surface_transport"
spec = importlib.util.spec_from_file_location("kinetic_tools", HERE.parent / "kinetic_coordinates/run.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
CHARTS = {"cartesian": (0, 0), "mapped": (0.06, 0.045)}
PARAMETERS = ("warpX", "warpY", "motion", "shape", "method", "timeScale", "duration")
def standard_scale(n):
    # Keep the physical timestep fixed from 128 through 320 while refining space.
    return n/128 if n>=256 else 1


def frame_interval(n):
    return int(n/(2*standard_scale(n)))


REDUCTIONS = "elapsed = max elapsed, waterVolume = sum waterVolume, initialVolumeError = sum initialVolumeError, lowest = min lowest, highest = max highest, mixing = sum mixing, returnedL1 = sum returnedL1, returnedMaximum = max returnedMaximum, stationaryError = max stationaryError, movedArea = sum movedArea, boundCourant = max boundCourant, closure = max closure, boundaryFlow = max boundaryFlow, minArea = min minArea"


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
        source, count = re.subn(r"^double :: " + name + r" = .*$", f"double :: {name} = interfaceConfig({key})", source, flags=re.M)
        assert count == 1
    (directory / f"{NAME}.fmr").write_text(source)
    (directory / f"{NAME}.yaml").write_text(f"length_per_node: [1, 1]\ngrid_per_node: [{n}, {n}]\nmpi_shape: [1, 1]\nboundary: [periodic, periodic]\nreduces: [{REDUCTIONS}]\n")
    helpers.call([os.environ.get("FORMURA", str(ROOT / "bin/formura")), f"{NAME}.fmr"], directory, "formura", cwd=directory)
    shutil.copyfile(HERE / "driver.c", directory / "driver.c")
    cc = [os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I"+str(ROOT / "mpistub"), "-I"+str(directory), "-include", HERE / "config.h"]
    helpers.call([*cc, "-c", directory / f"{NAME}.c", "-o", directory / "solver.o"], directory, "cc-solver")
    helpers.call([*cc, directory / "driver.c", directory / "solver.o", "-lm", "-o", directory / "run"], directory, "cc-driver")
    definitions = [f'-DHDR="{NAME}.h"', "-DDIM=2", "-DFRAME_FIELDS=1", f"-DFRAME_EVERY={frame_interval(n)}", "-DF1=formura_data.fraction[i][j]"]
    helpers.call([*cc, *definitions, "-include", ROOT / "gallery/tools/field_frames.h", "-c", directory / "driver.c", "-o", directory / "record.o"], directory, "cc-recorder")
    helpers.call([cc[0], directory / "record.o", directory / "solver.o", "-lm", "-o", directory / "record"], directory, "cc-link")
    return directory


def simulate(directory, n, chart, case, method=1, time_scale=1, record=False):
    motion, shape, duration = {"rest": (0, 1, 1), "uniform": (2, 0, 4), "wave": (1, 1, 1), "vortex": (2, 2, 4)}[case]
    label = f"{chart}-{case}-m{method}-dt{time_scale}"
    output = directory / label
    output.mkdir(exist_ok=True)
    steps = int(duration*20*n/time_scale)
    interval = int(n/4/time_scale)
    arguments = [steps, interval, *CHARTS[chart], motion, shape, method, time_scale, duration]
    env = dict(os.environ)
    if record:
        raw = output / "raw"
        raw.mkdir(exist_ok=True)
        for p in raw.glob("*.bin"):
            p.unlink()
        env["FORMURAE_FRAME_DIR"] = str(raw)
    print(n, label, flush=True)
    text = subprocess.check_output([str(directory / ("record" if record else "run")), *map(str, arguments)], text=True, cwd=directory, env=env)
    recorder_check = None
    if record and n == 32:
        baseline = subprocess.check_output([str(directory / "run"), *map(str, arguments)], text=True, cwd=directory)
        assert baseline == text, "recorder altered the diagnostic output"
        recorder_check = True
    (output / "diagnostics.csv").write_text(text)
    rows = [{k: float(v) for k, v in row.items()} for row in csv.DictReader(io.StringIO(text))]
    assert rows and all(math.isfinite(v) for row in rows for v in row.values())
    result = dict(grid=n, chart=chart, case=case, method=method, time_scale=time_scale, duration=duration,
                  arguments=arguments, history=rows, final=rows[-1], recorder_check=recorder_check,
                  csv=str((output / "diagnostics.csv").relative_to(directory.parent)), diagnostics_sha256=sha(output / "diagnostics.csv"),
                  volume_drift=max(abs(row["waterVolume"]-rows[0]["waterVolume"])/rows[0]["waterVolume"] for row in rows))
    if record:
        files = sorted(raw.glob("*.bin"))
        updates = np.array([int(p.stem) for p in files])
        np.testing.assert_array_equal(updates, np.arange(0, 2*steps+1, frame_interval(n)))
        values = np.stack([np.fromfile(p, dtype=np.float64).reshape(n, n) for p in files])
        assert np.isfinite(values).all()
        np.savez_compressed(output / "frames.npz", fraction=values, updates=updates, time=updates*.05*time_scale/n/2)
        result["frames_sha256"] = sha(output / "frames.npz")
        for p in files:
            p.unlink()
        raw.rmdir()
    print(json.dumps(dict(volume_drift=result["volume_drift"], final=result["final"])), flush=True)
    return result


def range_tolerance(row):
    # Diagnostic acceptance budget, not a formal floating-point error bound.
    # Retain an initialization margin and allow one machine epsilon per update.
    return max(2e-12, math.ulp(1.0)*row["update"])


def verify(record, accuracy_grid=None):
    final, history = record["final"], record["history"]
    assert record["volume_drift"] < 2e-11
    for row in history:
        tolerance=range_tolerance(row)
        assert row["lowest"] >= -tolerance and row["highest"] <= 1+tolerance, row
    assert 0 <= final["boundCourant"] < 1
    assert final["closure"] < 2e-10 and final["boundaryFlow"] < 2e-12
    assert final["minArea"] > 0
    assert abs(final["elapsed"]-record["duration"]) < 1e-9
    assert abs(history[0]["initialVolumeError"])/history[0]["waterVolume"] < .02
    if record["case"] in ("rest", "uniform"):
        assert final["stationaryError"] < 5e-12
        assert final["returnedL1"] < 5e-12
    else:
        assert max(row["movedArea"] for row in history) > .02
        if record["grid"] == accuracy_grid and record["method"] == 1:
            assert final["returnedL1"] < (.025 if record["case"] == "wave" else .02), final


def compare(records, grids):
    def find(n, chart, case, method=1, dt=None):
        dt=standard_scale(n) if dt is None else dt
        return next(r for r in records if (r["grid"], r["chart"], r["case"], r["method"], r["time_scale"]) == (n, chart, case, method, dt))
    checks = {}
    for case in ("wave", "vortex"):
        for chart in CHARTS:
            errors = [find(n, chart, case)["final"]["returnedL1"] for n in grids]
            for a, b in zip(errors, errors[1:]):
                assert b < .85*a, (case, chart, errors)
            checks[f"{case}-{chart}-return-L1"] = errors
        gaps = []
        for n in grids:
            a, b = find(n, "cartesian", case), find(n, "mapped", case)
            assert len(a["history"]) == len(b["history"])
            gaps.append(max(abs(x["mixing"]-y["mixing"])/a["history"][0]["waterVolume"] for x,y in zip(a["history"], b["history"])))
        if len(grids)>1:
            assert gaps[-1] < gaps[0]/2, (case,gaps)
        if max(grids)>=128:
            assert gaps[-1] < .02, (case,gaps)
        checks[f"{case}-chart-mixing-gaps"] = gaps
    if 64 in grids:
        for chart in CHARTS:
            a,b = find(64,chart,"vortex"),find(64,chart,"vortex",dt=.5)
            gap=max(abs(x["mixing"]-y["mixing"])/a["history"][0]["waterVolume"] for x,y in zip(a["history"],b["history"]))
            assert gap < 1e-4
            checks[chart+"-half-step-mixing-gap"] = gap
    if 128 in grids:
        for chart in CHARTS:
            high,low = find(128,chart,"vortex"),find(128,chart,"vortex",method=0)
            ratios = {k: high["final"][k]/low["final"][k] for k in ("returnedL1","mixing")}
            assert all(v<.8 for v in ratios.values()),ratios
            checks[chart+"-high-to-upwind-ratios"] = ratios
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids",type=int,nargs="+",default=[32,64,128,256,320])
    parser.add_argument("--reuse-normalized",action="store_true")
    parser.add_argument("--reuse-runs",action="store_true",help="reuse recorded runs after checking model, toolchain, arguments and output hashes")
    parser.add_argument("--probe",action="store_true")
    args=parser.parse_args()
    if args.grids!=sorted(set(args.grids)) or any(n<32 or n%4 for n in args.grids):
        parser.error("use distinct increasing multiples of four, at least 32")
    base=ROOT/".build/surface-transport"
    base.mkdir(parents=True,exist_ok=True)
    identity=dict(source_sha256=sha(HERE/f"{NAME}.fme"),toolchain=helpers.toolchain())
    marker=base/"normalization.json"
    if args.reuse_normalized:
        assert json.loads(marker.read_text())==identity
    else:
        normalize(base)
        marker.write_text(json.dumps(identity,indent=2)+"\n")
    cached=[]
    reused=[]
    prior=None
    if args.reuse_runs:
        previous=base/"probe.json"
        cache=json.loads(previous.read_text())
        for key,value in identity.items():
            assert cache[key]==value,f"cached {key} changed"
        for key,path in [("driver_sha256",HERE/"driver.c"),("config_sha256",HERE/"config.h")]:
            assert cache[key]==sha(path),f"cached {key} changed"
        for suffix,value in cache["generated"].items():
            assert value==sha(base/f"{NAME}.{suffix}"),"normalized solver changed"
        prior=dict(report_sha256=sha(previous),orchestration_sha256=cache["orchestration_sha256"])
        shutil.copyfile(previous,base/("previous-"+prior["report_sha256"]+".json"))
        cached=cache["runs"]
    records=[]
    built=set()

    def run_case(n,chart,case,method=1,time_scale=1,record=False):
        motion,shape,duration={"rest":(0,1,1),"uniform":(2,0,4),"wave":(1,1,1),"vortex":(2,2,4)}[case]
        expected=[int(duration*20*n/time_scale),int(n/4/time_scale),*CHARTS[chart],motion,shape,method,time_scale,duration]
        matches=[r for r in cached if (r["grid"],r["chart"],r["case"],r["arguments"])==(n,chart,case,expected)]
        if matches:
            assert len(matches)==1
            saved=matches[0]
            path=base/saved["csv"]
            assert sha(path)==saved["diagnostics_sha256"]
            with path.open() as stream:
                rows=[{k:float(v) for k,v in row.items()} for row in csv.DictReader(stream)]
            assert rows==saved["history"] and rows[-1]==saved["final"]
            assert all(math.isfinite(v) for row in rows for v in row.values())
            if record:
                assert sha(path.with_name("frames.npz"))==saved["frames_sha256"]
                if n==32:
                    assert saved["recorder_check"] is True
            reused.append(saved["csv"])
            print("reuse",n,chart,case,method,time_scale,flush=True)
            return saved
        if n not in built:
            build(base,n)
            built.add(n)
        return simulate(base/f"grid-{n}",n,chart,case,method,time_scale,record)

    for n in args.grids:
        for chart in CHARTS:
            if args.probe or n==64:
                for case in ("rest","uniform"):
                    records.append(run_case(n,chart,case))
            for case in ("wave","vortex"):
                records.append(run_case(n,chart,case,time_scale=standard_scale(n),record=True))
            if not args.probe and n==64:
                records.append(run_case(n,chart,"vortex",time_scale=.5))
            if not args.probe and n==128:
                records.append(run_case(n,chart,"vortex",method=0,record=True))
    report=dict(**identity,driver_sha256=sha(HERE/"driver.c"),config_sha256=sha(HERE/"config.h"),
                orchestration_sha256=sha(Path(__file__)),generated={s:sha(base/f"{NAME}.{s}") for s in ("egi","feir","fmr")},runs=records,
                reuse=dict(prior=prior,diagnostics=reused),accuracy_grid=max(args.grids))
    (base/"probe.json").write_text(json.dumps(report,indent=2)+"\n")
    for record in records:
        verify(record,accuracy_grid=None if args.probe else max(args.grids))
    if not args.probe:
        report["checks"]=compare(records,args.grids)
        report["range_check"]=dict(base_tolerance=2e-12,machine_epsilon=math.ulp(1.0),
            formula="max(base_tolerance, machine_epsilon * update)",
            maximum_tolerance=max(range_tolerance(row) for r in records for row in r["history"]),
            maximum_excess=max(max(0,row["highest"]-1,-row["lowest"]) for r in records for row in r["history"]))
        report["passed"]=True
        (HERE/"results/verification.json").write_text(json.dumps(report,indent=2)+"\n")
        for suffix in ("egi","feir","fmr"):
            shutil.copyfile(base/f"{NAME}.{suffix}",HERE/f"{NAME}.{suffix}")
        print(json.dumps(report["checks"],indent=2))


if __name__=="__main__":
    main()
