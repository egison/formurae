#!/usr/bin/env python3
"""Check diagnostics computed by Formurae; optionally run the still-water case."""
import argparse
import csv
import json
import math
from pathlib import Path
from run import ROOT, build, run


def check(directory, require_overhang=False, still=False):
    directory = Path(directory)
    with (directory / "stats.csv").open() as file:
        rows = [{key: float(value) for key, value in row.items()}
                for row in csv.DictReader(file)]
    meta = json.loads((directory / "metadata.json").read_text())
    assert rows and rows[-1]["step"] == meta["steps"], "incomplete run"
    assert all(math.isfinite(x) for row in rows for x in row.values()), "nonfinite diagnostic"
    reference = rows[0]["water"]
    relative_drift = max(abs(row["water"]-reference) for row in rows) / reference
    assert relative_drift < 1e-9, f"mass drift: {relative_drift}"
    assert max(row["bad"] for row in rows) == 0, "out-of-bounds state"
    assert max(row["bank"] for row in rows) < 1e-6, "unredistributed mass"
    if require_overhang:
        assert max(row["overhang"] for row in rows) >= 3, "no resolved overhang"
    if still:
        assert max(row["speed"] for row in rows) < .001, "still water developed a large velocity"
        assert max(row["overhang"] for row in rows) == 0, "still water developed an overhang"
    try:
        label = str(directory.resolve().relative_to(ROOT))
    except ValueError:
        label = str(directory)
    result = {"directory": label, "steps": meta["steps"],
              "relative_mass_drift": relative_drift,
              "max_unredistributed_mass_per_cell": max(row["bank"] for row in rows),
              "max_speed": max(row["speed"] for row in rows),
              "max_overhang_cells": max(row["overhang"] for row in rows)}
    print(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", default=ROOT / ".build/breaking_wave/demo")
    parser.add_argument("--require-overhang", action="store_true")
    parser.add_argument("--still-water", action="store_true")
    args = parser.parse_args()
    results = [check(args.directory, args.require_overhang)]
    if args.still_water:
        directory = ROOT / ".build/breaking_wave/still"
        build(directory, (128, 96), {"depth": 40, "amplitude": 0, "beachSlope": 0})
        run(directory, 1200, 60)
        results.append(check(directory, still=True))
    (args.directory / "verification.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
