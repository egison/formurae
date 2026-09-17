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
SCENARIOS = {"uniform": 0, "smooth": 1, "sharp": 2}
REDUCTIONS = ["elapsed = max elapsed", "error = max error", "lowest = min lowest",
              "highest = max highest", "cfl = max cfl", "closure = max closure",
              "minArea = min minArea"] + [f"m{a} = sum mass_down{a}" for a in range(1, 10)]


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
    if len(rows) != size + 1 or any(not math.isfinite(value) for row in rows for value in row.values()):
        raise AssertionError("missing steps or nonfinite diagnostic")
    drift = max(abs(row[f"m{a}"]-rows[0][f"m{a}"])/rows[0][f"m{a}"]
                for row in rows for a in range(1, 10))
    record = dict(grid=size, chart=chart, scenario=scenario, method="upwind" if method==0 else "centered",
                  population_mass_relative_drift=drift, final=rows[-1],
                  max_cfl=max(r["cfl"] for r in rows),
                  max_closure=max(r["closure"] for r in rows))
    assert drift < 1e-10, record
    assert all(r["minArea"] > 0 for r in rows), record
    assert record["max_cfl"] < 1, record
    assert record["max_closure"] < 1e-10, record
    if method == 0:
        assert rows[-1]["lowest"] >= -1e-12, record
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
                records.append(simulate(directory, size, chart, scenario, 0))
            records.append(simulate(directory, size, chart, "sharp", 1))
    orders = {}
    if len(args.grids) >= 2:
        for chart in CHARTS:
            smooth = [r for r in records if r["chart"]==chart and r["scenario"]=="smooth"]
            orders[chart] = [math.log(a["final"]["error"]/b["final"]["error"])/math.log(b["grid"]/a["grid"])
                             for a, b in zip(smooth, smooth[1:])]
            assert orders[chart][-1] > 0.65, orders
    output = HERE / "results"
    output.mkdir(exist_ok=True)
    (output / "verification.json").write_text(json.dumps(dict(**identity, runs=records, orders=orders), indent=2)+"\n")
    print(json.dumps(dict(runs=len(records), orders=orders), indent=2))


if __name__ == "__main__":
    main()
