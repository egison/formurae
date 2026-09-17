#!/usr/bin/env python3
"""Compare diagnostics already computed by FME and reduced by Formura.

This script evaluates pass/fail and convergence from recorded numbers. It
does not reconstruct fields or solve any part of the model.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CHARTS = ("cartesian", "stretched", "curved")
SCENARIOS = ("uniform", "transport", "shear")
CHART_PARAMETERS = {"cartesian": (0, 0), "stretched": (0.2, 0), "curved": (0.2, 0.3)}


def read_run(base, scenario, chart, size, source_hash):
    directory = base / f"{scenario}-{chart}-{size}"
    metadata = json.loads((directory / "metadata.json").read_text())
    assert metadata["source_sha256"] == source_hash, "stale model results"
    assert metadata["scenario"] == scenario and metadata["chart"] == chart
    assert metadata["grid"] == [size, size]
    parameters = metadata["parameters"]
    assert (float(parameters["stretch"]), float(parameters["shear"])) == CHART_PARAMETERS[chart]
    assert int(parameters["scenario"]) == SCENARIOS.index(scenario)
    with (directory / "stats.csv").open() as file:
        rows = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(file)]
    assert rows and all(math.isfinite(value) for row in rows for value in row.values())
    assert [row["step"] for row in rows] == list(range(0, metadata["steps"]+1,
                                                      metadata["output_interval"]))
    initial, final = rows[0], rows[-1]
    assert initial["time"] == 0 and final["time"] > 0
    assert all(abs(row["time"] - row["step"]*0.1*2*math.pi/size) < 1e-11 for row in rows)
    assert all(row["bad"] == 0 and 0.5 < row["rmin"] <= row["rmax"] < 1.5 for row in rows)
    mass_drift = max(abs(row["mass"]-initial["mass"]) / abs(initial["mass"]) for row in rows)
    momentum_drift = max(abs(row[key]-initial[key]) for row in rows
                         for key in ("momentum_x", "momentum_y"))
    assert mass_drift < 2e-11, (directory.name, "mass", mass_drift)
    assert momentum_drift < 2e-11, (directory.name, "momentum", momentum_drift)
    if scenario == "uniform":
        assert max(row["error"] for row in rows) < 2e-12, directory.name
    if scenario == "transport":
        assert final["error"] > 0, "transport reference was not evaluated"
    if scenario == "shear":
        assert 0 < final["mode"] < initial["mode"], "shear did not decay"
        assert 0 < final["energy"] < initial["energy"], "energy did not decay"
    return dict(metadata=metadata, records=rows, mass_relative_drift=mass_drift,
                momentum_absolute_drift=momentum_drift)


def verify(base, grids):
    source_hash = hashlib.sha256((HERE / "kinetic_coordinates.fme").read_bytes()).hexdigest()
    runs = {}
    for scenario in SCENARIOS:
        for chart in CHARTS:
            for size in grids:
                key = f"{scenario}-{chart}-{size}"
                runs[key] = read_run(base, scenario, chart, size, source_hash)
    times = [run["records"][-1]["time"] for run in runs.values()]
    assert max(times)-min(times) < 1e-11, "physical duration differs"
    provenance = next(iter(runs.values()))["metadata"]["toolchain"]
    assert all(run["metadata"]["toolchain"] == provenance for run in runs.values()), "mixed toolchains"
    transport = {}
    for chart in CHARTS:
        errors = [runs[f"transport-{chart}-{n}"]["records"][-1]["error"] for n in grids]
        orders = [math.log(a/b)/math.log(n2/n1)
                  for a, b, n1, n2 in zip(errors, errors[1:], grids, grids[1:])]
        assert all(a > b for a, b in zip(errors, errors[1:])), (chart, errors)
        assert orders[-1] > 1.7, (chart, orders)
        transport[chart] = dict(grids=grids, final_max_population_error=errors,
                                observed_orders=orders)
    shear = {}
    for chart in CHARTS[1:]:
        differences = []
        for size in grids:
            reference = runs[f"shear-cartesian-{size}"]["records"][-1]["mode"]
            mapped = runs[f"shear-{chart}-{size}"]["records"][-1]["mode"]
            differences.append(abs(mapped-reference))
        orders = [math.log(a/b)/math.log(n2/n1)
                  for a, b, n1, n2 in zip(differences, differences[1:], grids, grids[1:])]
        assert all(a > b for a, b in zip(differences, differences[1:])), (chart, differences)
        assert orders[-1] > 1.7, (chart, orders)
        shear[chart] = dict(grids=grids, mode_difference_from_cartesian=differences,
                            observed_orders=orders)
    return dict(passed=True, source_sha256=source_hash, physical_duration=times[0],
                max_mass_relative_drift=max(run["mass_relative_drift"] for run in runs.values()),
                max_momentum_absolute_drift=max(run["momentum_absolute_drift"] for run in runs.values()),
                max_uniform_error=max(row["error"] for name, run in runs.items()
                                      if name.startswith("uniform-") for row in run["records"]),
                transport=transport, shear=shear, runs=runs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=ROOT / ".build/kinetic_coordinates")
    parser.add_argument("--grids", nargs="+", type=int, default=[16, 32, 64])
    parser.add_argument("--output", type=Path, default=HERE / "results/verification.json")
    args = parser.parse_args()
    if len(args.grids) < 3 or args.grids != sorted(set(args.grids)):
        parser.error("use at least three increasing grid sizes")
    result = verify(args.directory, args.grids)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "runs"}, indent=2))


if __name__ == "__main__":
    main()
