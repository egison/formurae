#!/usr/bin/env python3
"""Check recorded Formurae diagnostics; optionally run still-water/reference cases.

No fields are evolved or physical diagnostics reconstructed in Python. Peak
checks compare the water-column measurements already reduced by Formurae.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
from run import ROOT, build, run


def arrival_peaks(rows, key, excursion):
    """Record a maximum only after both a rise and a fall of at least excursion.

    This amplitude hysteresis rejects small oscillations without presupposing
    the number or timing of waves. An unfinished final crest is not counted.
    """
    low = high = rows[0]
    rising = False
    peaks = []
    for row in rows[1:]:
        if not rising:
            if row[key] < low[key]:
                low = row
            if row[key] - low[key] >= excursion:
                high = row
                rising = True
        else:
            if row[key] > high[key]:
                high = row
            if high[key] - row[key] >= excursion:
                peaks.append({"step": int(high["step"]), "water_column": high[key]})
                low = row
                rising = False
    return peaks


def check(directory, expected_waves=None, excursion=2, still=False):
    directory = Path(directory)
    with (directory / "stats.csv").open() as file:
        rows = [{key: float(value) for key, value in row.items()}
                for row in csv.DictReader(file)]
    meta = json.loads((directory / "metadata.json").read_text())
    assert rows and rows[-1]["step"] == meta["steps"], "incomplete run"
    assert [row["step"] for row in rows] == list(range(0, meta["steps"]+1, meta["every"])), "missing report"
    assert all(math.isfinite(x) for row in rows for x in row.values()), "nonfinite diagnostic"
    source = directory / "wave_train.fme"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == meta["source_sha256"], "source differs from run metadata"
    reference = rows[0]["water"]
    assert reference > 0, "empty tank"
    relative_drift = max(abs(row["water"]-reference) for row in rows) / reference
    assert relative_drift < 1e-9, f"mass drift: {relative_drift}"
    assert max(row["bad"] for row in rows) == 0, "out-of-bounds state"
    # With several collapses, a cell can temporarily have no interface
    # recipient. The model retains that mass in bank and retries later.
    # Permit less than 0.1 cell's reference mass while requiring the final
    # pending mass to have returned to roundoff scale.
    assert max(row["bank"] for row in rows) < .1, "large pending mass in one cell"
    assert rows[-1]["bank"] < 1e-6, "pending mass remains at the end"
    peaks = {key: arrival_peaks(rows, key, excursion)
             for key in ("gauge_offshore", "gauge_surf")}
    if expected_waves is not None:
        for key, values in peaks.items():
            assert len(values) == expected_waves, f"{key}: expected {expected_waves} arrivals, got {values}"
        assert all(a["step"] < b["step"] for a, b in zip(peaks["gauge_offshore"], peaks["gauge_surf"])), "shallow gauge must receive each crest later"
        assert max(row["shore_overhang"] for row in rows) >= 3, "no resolved overhang on the beach"
        assert max(row["runup"] for row in rows) > 0, "water did not reach initially dry beach"
    if still:
        assert max(row["speed"] for row in rows) < .001, "still water developed a large velocity"
        assert max(row["overhang"] for row in rows) == 0, "still water developed an overhang"
        assert all(not values for values in peaks.values()), "still water developed a wave arrival"
    try:
        label = str(directory.resolve().relative_to(ROOT))
    except ValueError:
        label = str(directory)
    result = {"directory": label, "steps": meta["steps"], "grid": meta["grid"],
              "source_sha256": meta["source_sha256"],
              "relative_mass_drift": relative_drift,
              "max_unredistributed_mass_per_cell": max(row["bank"] for row in rows),
              "final_unredistributed_mass_per_cell": rows[-1]["bank"],
              "max_speed": max(row["speed"] for row in rows),
              "density_range": [min(row["rmin"] for row in rows), max(row["rmax"] for row in rows)],
              "max_overhang_cells": max(row["overhang"] for row in rows),
              "max_shore_overhang_cells": max(row["shore_overhang"] for row in rows),
              "max_downward_speed_on_beach": max(row["downward_speed"] for row in rows),
              "furthest_runup_x": max(row["runup"] for row in rows),
              "arrival_excursion": excursion, "arrivals": peaks}
    print(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", default=ROOT / ".build/wave_train/demo")
    parser.add_argument("--expected-waves", type=int, default=3)
    parser.add_argument("--excursion", type=float, default=2)
    parser.add_argument("--reference-cases", action="store_true")
    args = parser.parse_args()
    if args.excursion <= 0:
        parser.error("excursion must be positive")
    results = [check(args.directory, args.expected_waves, args.excursion)]
    if args.reference_cases:
        directory = ROOT / ".build/wave_train/still"
        build(directory, (128, 96), {"depth": 36, "amplitude": 0, "beachSlope": 0,
                                   "gaugeOffshoreX": 40, "gaugeSurfX": 80})
        run(directory, 1200, 60)
        results.append(check(directory, still=True))
        # A smaller one-crest control uses the tested pilot geometry.
        directory = ROOT / ".build/wave_train/single"
        build(directory, (416, 64), {"depth": 24, "amplitude": 17.5, "center": 180,
              "width": 12, "beachStart": 215, "gravity": .0001, "tau": .58,
              "waveSpacing": 70, "waveCount": 1, "gaugeOffshoreX": 205, "gaugeSurfX": 275})
        run(directory, 4200, 20)
        results.append(check(directory, expected_waves=1, excursion=2))
    (args.directory / "verification.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
