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
NAME = "kinetic_fv"
# Share configuration-independent build/log/provenance utilities only.
module = importlib.util.spec_from_file_location("kinetic_build_tools", HERE.parent / "kinetic_coordinates/run.py")
helpers = importlib.util.module_from_spec(module)
module.loader.exec_module(helpers)
CHARTS = {"cartesian": (0, 0), "mapped": (0.2, 0.15)}
METHODS = {0: "upwind", 1: "centered", 2: "muscl", 3: "upwind-rk2"}
SCENARIOS = {"uniform": 0, "smooth": 1, "sharp": 2}
REDUCTIONS = ["elapsed = max elapsed", "error = max error", "lowest = min lowest",
              "highest = max highest", "cfl = max cfl", "closure = max closure",
              "minArea = min minArea", "errorL1 = sum errorL1", "mixing = sum mixing"] + [f"m{a} = sum mass_down{a}" for a in range(1, 10)]


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
    for key, name in enumerate(("warpX", "warpY", "scenario", "method")):
        generated, count = re.subn(r"^double :: " + name + r" = .*$",
                                  f"double :: {name} = fvConfig({key})", generated, flags=re.MULTILINE)
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


def simulate(directory, size, chart, scenario, method):
    print(size, chart, scenario, method, flush=True)
    result = subprocess.run([str(directory / "run"), str(size),
                             *map(str, CHARTS[chart]), str(SCENARIOS[scenario]), str(method)],
                            cwd=directory, capture_output=True, text=True, check=True)
    rows = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(io.StringIO(result.stdout))]
    if len(rows) != (2*size if method >= 2 else size) + 1 or any(not math.isfinite(value) for row in rows for value in row.values()):
        raise AssertionError("missing steps or nonfinite diagnostic")
    drift = max(abs(row[f"m{a}"]-rows[0][f"m{a}"])/rows[0][f"m{a}"]
                for row in rows for a in range(1, 10))
    record = dict(grid=size, chart=chart, scenario=scenario, method=METHODS[method], generated_updates=len(rows)-1,
                  population_mass_relative_drift=drift, final=rows[-1],
                  max_cfl=max(r["cfl"] for r in rows),
                  max_closure=max(r["closure"] for r in rows))
    assert drift < 1e-10, record
    assert all(r["minArea"] > 0 for r in rows), record
    assert record["max_cfl"] < (0.5 if method==2 else 1), record
    assert abs(rows[-1]["time"]-0.2*math.pi) < 1e-12, record
    assert record["max_closure"] < 1e-10, record
    if method != 1:
        assert rows[-1]["lowest"] >= rows[0]["lowest"]-1e-12, record
        assert rows[-1]["highest"] <= rows[0]["highest"]+1e-12, record
        assert rows[-1]["highest"] <= (1.2 if scenario=="smooth" else 1)+1e-12, record
    else:
        assert rows[-1]["lowest"] < -1e-3, record
    if scenario == "uniform":
        assert rows[-1]["error"] < 1e-12, record
    (directory / f"{chart}-{scenario}-{method}.csv").write_text(result.stdout)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids", type=int, nargs="+", default=[16, 32, 64])
    parser.add_argument("--reuse-normalized", action="store_true")
    args = parser.parse_args()
    if args.grids != sorted(set(args.grids)) or min(args.grids) < 8:
        parser.error("use increasing distinct grid sizes of at least 8")
    base = ROOT / ".build/kinetic-fv"
    base.mkdir(parents=True, exist_ok=True)
    identity = dict(toolchain=helpers.toolchain(),
                    source_sha256=hashlib.sha256((HERE / (NAME + ".fme")).read_bytes()).hexdigest())
    manifest = base / "normalization.json"
    if args.reuse_normalized:
        if not manifest.exists() or json.loads(manifest.read_text()) != identity:
            raise ValueError("normalization cache does not match source/toolchain")
    else:
        normalize(base)
        manifest.write_text(json.dumps(identity, indent=2)+"\n")
    records = []
    for size in args.grids:
        directory = build(base, size)
        for chart in CHARTS:
            for scenario in SCENARIOS:
                for method in (0, 2):
                    records.append(simulate(directory, size, chart, scenario, method))
            records.append(simulate(directory, size, chart, "smooth", 3))
            records.append(simulate(directory, size, chart, "sharp", 1))
    orders = {}
    improvements = {}
    if len(args.grids) >= 2:
        for method in ("upwind", "muscl", "upwind-rk2"):
            orders[method] = {}
            for chart in CHARTS:
                smooth = [r for r in records if r["chart"]==chart and r["scenario"]=="smooth" and r["method"]==method]
                orders[method][chart] = {
                    norm: [math.log(a["final"][norm]/b["final"][norm])/math.log(b["grid"]/a["grid"])
                           for a, b in zip(smooth, smooth[1:])] for norm in ("error", "errorL1")}
                # MC limiting can lower the maximum-norm order near extrema;
                # require near-second-order mean error and improved peak error.
                if method=="muscl":
                    assert orders[method][chart]["error"][-1] > 1.3, orders
                    assert orders[method][chart]["errorL1"][-1] > 1.7, orders
                else:
                    assert orders[method][chart]["error"][-1] > 0.65, orders
        for chart in CHARTS:
            finest = {r["method"]: r for r in records if r["grid"]==args.grids[-1]
                      and r["chart"]==chart and r["scenario"]=="smooth"}
            improvements[chart] = {method: finest[method]["final"]["error"]/finest["muscl"]["final"]["error"]
                                   for method in ("upwind", "upwind-rk2")}
            assert improvements[chart]["upwind-rk2"] > 3, improvements
            sharp = {r["method"]: r for r in records if r["grid"]==args.grids[-1]
                     and r["chart"]==chart and r["scenario"]=="sharp"}
            assert 0 <= sharp["muscl"]["final"]["mixing"] < sharp["upwind"]["final"]["mixing"], sharp
    output = HERE / "results"
    output.mkdir(exist_ok=True)
    (output / "verification.json").write_text(json.dumps(dict(**identity, runs=records, orders=orders, improvements=improvements), indent=2)+"\n")
    print(json.dumps(dict(runs=len(records), orders=orders, improvements=improvements), indent=2))


if __name__ == "__main__":
    main()
