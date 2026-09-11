#!/usr/bin/env python3
"""Focused numerical checks, all using the generated FME solver.

Only compare generated outputs here. The energy, the order parameter, the
defect windings and the analytic reference of the accuracy check are all
computed in FME/Egison.
"""
import csv
import hashlib
import json
import os
import re
import shutil
import struct

from run import HERE, ROOT, build, run

OUT = ROOT / ".build/nematic_torus/verification"


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def fields(directory, step):
    result = {}
    for path in (directory / "data").glob(f"frame-{step:07d}-rank-*.bin"):
        data = path.read_bytes()
        nx, ny, stamp = struct.unpack_from("=iii", data)
        assert stamp == step
        for i, j, *values in struct.iter_unpack("=iiddddd", data[12:]):
            assert (i, j) not in result, "duplicate MPI cell"
            result[i, j] = tuple(values)
    assert len(result) == nx * ny, "missing MPI cells"
    return result


def agreement(left, right):
    assert left.keys() == right.keys()
    error = max(abs(a-b) for key in left for a, b in zip(left[key], right[key]))
    assert error < 1e-10, error
    return error


def main():
    report = {"source_sha256": hashlib.sha256((HERE / "nematic_torus.fme").read_bytes()).hexdigest(),
              "accuracy_sha256": hashlib.sha256((HERE / "accuracy.fme.inc").read_bytes()).hexdigest(),
              "mpi_environment": {key: os.environ[key] for key in
                                  ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in os.environ}}
    grid = (48, 96)
    steps, every = 2000, 200
    # 1. Gradient flow: the free energy never increases; Q stays symmetric and
    #    traceless; the defect charges cancel on the torus.
    for case in ("random", "favored", "disfavored"):
        directory = build(OUT / case, case, grid, blocking=4)
        run(directory, steps, every, dump=False)
        rows = stats(directory)
        energies = [r["energy"] for r in rows[1:]]
        assert all(b <= a + 1e-9 * abs(a) for a, b in zip(energies, energies[1:])), case
        assert max(r["asym"] for r in rows) == 0.0, case
        assert max(r["trace"] for r in rows) < 1e-12, case
        assert all(r["plus"] == r["minus"] for r in rows), case
        report[case] = {"energy_initial": energies[0], "energy_final": energies[-1],
                        "trace_max": max(r["trace"] for r in rows),
                        "defects_initial": rows[1]["plus"], "defects_final": rows[-1]["plus"]}
    # 2. Reproducibility of the generated code under time blocking and MPI.
    plain = build(OUT / "plain", "random", grid, blocking=0)
    run(plain, 400, 400)
    blocked = build(OUT / "blocked", "random", grid, blocking=4)
    run(blocked, 400, 400)
    base = fields(plain, 400)
    report["blocking_max_error"] = agreement(base, fields(blocked, 400))
    if not shutil.which("mpicc") or not shutil.which("mpirun"):
        report["mpi"] = "not tested: mpicc/mpirun unavailable"
    else:
        for shape in ((2, 1), (1, 2)):
            directory = build(OUT / ("mpi-%d-%d" % shape), "random", grid, mpi=shape, blocking=4)
            run(directory, 400, 400, mpi=shape)
            report["mpi_%d_%d_max_error" % shape] = agreement(base, fields(directory, 400))
    # 3. Spatial accuracy of the discrete covariant Laplacian against the
    #    analytic one that Egison differentiates from the same definitions.
    extra = (HERE / "accuracy.fme.inc").read_text()
    errors = []
    for n in (32, 64, 128):
        directory = build(OUT / ("accuracy-%d" % n), "random", (n, 2*n), blocking=0,
                          overrides={"a": "0.0", "c": "0.0", "dt": "0.0001"}, extra_fme=extra)
        run(directory, 1, 1, dump=False)
        match = re.search(r"accuracy step=1 error=(\S+) reference=(\S+)",
                          (directory / "run.log").read_text())
        assert match, "missing generated accuracy diagnostic"
        error, reference = map(float, match.groups())
        assert 0 < error < reference
        errors.append(error / reference)
    assert errors[0] / errors[1] > 12 and errors[1] / errors[2] > 12, errors
    report["spatial_convergence"] = {"grids": [[n, 2*n] for n in (32, 64, 128)],
                                      "relative_squared_errors": errors,
                                      "squared_error_ratios": [errors[0]/errors[1], errors[1]/errors[2]]}
    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
