#!/usr/bin/env python3
"""Check diagnostics computed by Formurae; optionally run the still-water case."""
import argparse
import csv
import json
import hashlib
import math
from pathlib import Path
from run import ROOT, build, run


def check(directory, require_overhang=False, still=False, require_backwash=False):
    directory = Path(directory)
    with (directory / "stats.csv").open() as file:
        rows = [{key: float(value) for key, value in row.items()}
                for row in csv.DictReader(file)]
    meta = json.loads((directory / "metadata.json").read_text())
    assert rows and rows[-1]["step"] == meta["steps"], "incomplete run"
    assert all(math.isfinite(x) for row in rows for x in row.values()), "nonfinite diagnostic"
    assert [r["step"] for r in rows] == list(range(0, meta["steps"]+1, meta["every"])), "missing report"
    source = directory / "breaking_wave.fme"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == meta["source_sha256"], "source hash mismatch"
    reference = rows[0]["water"]
    relative_drift = max(abs(row["water"]-reference) for row in rows) / reference
    assert relative_drift < 1e-9, f"mass drift: {relative_drift}"
    assert max(row["bad"] for row in rows) == 0, "out-of-bounds state"
    assert max(row["bank"] for row in rows) < 1e-6, "unredistributed mass"
    assert min(row["fraction_min"] for row in rows) >= -.5, "large negative interface mass"
    assert max(row["fraction_max"] for row in rows) <= 1.5, "large interface mass overshoot"
    assert max(row["bank_total"] for row in rows) < 1e-6, "pending mass accumulated"
    backwash = None
    if require_backwash:
        front_peak = max(rows, key=lambda row: row["bulk_front"])
        after = [row for row in rows if row["step"] > front_peak["step"]]
        assert after, "run ended before retreat"
        return_peak = min(after, key=lambda row: row["shore_flux"])
        assert max(row["shore_flux"] for row in rows) > .05, "no onshore flow at the gauge"
        assert return_peak["shore_flux"] < -.05, "no offshore return flow at the gauge"
        # A wet front can remain pinned by a thin layer on the staircase bed.
        # Diagnose offshore transport independently, and report front motion.
        longest_return = (0, 0)
        start = None
        for row in after:
            if row["shore_flux"] < -.01:
                if start is None:
                    start = row["step"]
                if row["step"]-start > longest_return[1]-longest_return[0]:
                    longest_return = (start, row["step"])
            else:
                start = None
        assert longest_return[1]-longest_return[0] >= 600, "return flow lasted less than 600 steps"
        assert max(row["wet_front"] for row in rows) < meta["grid"][0]-8, "run-up reached the right wall"
        backwash = {"peak_runup_step": int(front_peak["step"]),
                    "peak_bulk_front_x": front_peak["bulk_front"],
                    "final_bulk_front_x": rows[-1]["bulk_front"],
                    "furthest_wet_front_x": max(row["wet_front"] for row in rows),
                    "final_wet_front_x": rows[-1]["wet_front"],
                    "peak_onshore_flux": max(row["shore_flux"] for row in rows),
                    "peak_return_step": int(return_peak["step"]),
                    "peak_offshore_flux_after_runup": return_peak["shore_flux"],
                    "sustained_return_interval": [int(t) for t in longest_return],
                    "bulk_front_retreat_cells": front_peak["bulk_front"]-rows[-1]["bulk_front"]}
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
              "max_overhang_cells": max(row["overhang"] for row in rows),
              "max_total_pending_mass": max(row["bank_total"] for row in rows),
              "raw_fraction_range": [min(row["fraction_min"] for row in rows),
                                     max(row["fraction_max"] for row in rows)],
              "source_sha256": meta["source_sha256"], "backwash": backwash}
    print(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", default=ROOT / ".build/breaking_wave/demo")
    parser.add_argument("--require-overhang", action="store_true")
    parser.add_argument("--still-water", action="store_true")
    parser.add_argument("--require-backwash", action="store_true")
    args = parser.parse_args()
    results = [check(args.directory, args.require_overhang, require_backwash=args.require_backwash)]
    if args.still_water:
        directory = ROOT / ".build/breaking_wave/still"
        build(directory, (128, 96), {"depth": 40, "amplitude": 0, "beachSlope": 0, "gaugeX": 80})
        run(directory, 1200, 60)
        results.append(check(directory, still=True))
    (args.directory / "verification.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
