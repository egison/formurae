#!/usr/bin/env python3
"""Focused numerical checks, all using the generated FME solver.

Only compare generated outputs here. The scattered-field integrals and the
electromagnetic energy are computed inside the generated solver.
"""
import csv
import hashlib
import json
import os
import shutil
import struct

from run import HERE, ROOT, build, run

OUT = ROOT / ".build/transformation_optics/verification"


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def fields(directory, step):
    result = {}
    for path in (directory / "data").glob(f"frame-{step:07d}-rank-*.bin"):
        data = path.read_bytes()
        nx, ny, stamp = struct.unpack_from("=iii", data)
        assert stamp == step
        for i, j, e, ev in struct.iter_unpack("=iidd", data[12:]):
            assert (i, j) not in result, "duplicate MPI cell"
            result[i, j] = (e, ev)
    assert len(result) == nx * ny, "missing MPI cells"
    return result


def agreement(left, right):
    assert left.keys() == right.keys()
    error = max(abs(a-b) for key in left for a, b in zip(left[key], right[key]))
    assert error < 1e-10, error
    return error


def scattering(rows):
    # Ratio of the scattered to the incident field energy outside the device
    # at the last output; both sums come from the generated solver.
    last = rows[-1]
    return last["scatter"] / last["incident"]


def main():
    report = {"source_sha256": hashlib.sha256((HERE / "transformation_optics.fme").read_bytes()).hexdigest(),
              "mpi_environment": {key: os.environ[key] for key in
                                  ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in os.environ}}
    steps, every = 1000, 100
    ratios = {}
    for case in ("vacuum", "obstacle", "cloak", "rotator"):
        directory = build(OUT / case, case, (160, 120), blocking=4)
        run(directory, steps, every, dump=False)
        rows = stats(directory)
        # The energy is a step diagnostic, so the initial row is zero.
        energies = [r["energy"] for r in rows[1:]]
        drift = max(abs(e - energies[0]) for e in energies) / energies[0]
        ratios[case] = scattering(rows)
        report[case] = {"scattering_ratio": ratios[case], "energy_relative_drift": drift,
                        "emax_final": rows[-1]["emax"]}
        assert drift < 0.05, (case, drift)
    assert ratios["vacuum"] < 1e-24, ratios["vacuum"]
    assert ratios["obstacle"] > 0.1, ratios["obstacle"]
    assert ratios["rotator"] < 0.1 * ratios["obstacle"], (ratios["rotator"], ratios["obstacle"])
    assert ratios["cloak"] < 0.5 * ratios["obstacle"], (ratios["cloak"], ratios["obstacle"])

    # Without blocking: the blocked build at this size needs 16 dummy layers and
    # 2.5 GB of static arrays, which the macOS loader refuses to map.
    fine = build(OUT / "rotator-fine", "rotator", (320, 240), blocking=0)
    run(fine, 2 * steps, 2 * every, dump=False)
    ratio_fine = scattering(stats(fine))
    report["rotator_fine"] = {"scattering_ratio": ratio_fine}
    assert ratio_fine < ratios["rotator"], (ratio_fine, ratios["rotator"])

    # Same dummy-axis extent in both builds: the blocked one needs 2*sleeve*interval layers.
    plain = build(OUT / "plain", "rotator", (160, 120), blocking=0, layers=16)
    run(plain, 400, 400)
    blocked = build(OUT / "blocked", "rotator", (160, 120), blocking=4, layers=16)
    run(blocked, 400, 400)
    base = fields(plain, 400)
    report["blocking_max_error"] = agreement(base, fields(blocked, 400))
    if not shutil.which("mpicc") or not shutil.which("mpirun"):
        report["mpi"] = "not tested: mpicc/mpirun unavailable"
    else:
        for shape in ((2, 1), (1, 2)):
            directory = build(OUT / ("mpi-%d-%d" % shape), "rotator", (160, 120), mpi=shape, blocking=4, layers=16)
            run(directory, 400, 400, mpi=shape)
            report["mpi_%d_%d_max_error" % shape] = agreement(base, fields(directory, 400))
    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
