#!/usr/bin/env python3
"""Focused numerical checks, all using the generated FME solver.

Only compare generated outputs here. The integrals and the analytic
continuum reference for the accuracy check are computed in FME/Egison.
"""
import csv
import hashlib
import json
import os
import re
import shutil
import struct

from run import HERE, ROOT, build, run

OUT = ROOT / ".build/excitable_torus/verification"


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def fields(directory, step):
    result = {}
    for path in (directory / "data").glob(f"frame-{step:07d}-rank-*.bin"):
        data = path.read_bytes()
        nx, ny, stamp = struct.unpack_from("=iii", data)
        assert stamp == step
        for i, j, u, v in struct.iter_unpack("=iidd", data[12:]):
            assert (i, j) not in result, "duplicate MPI cell"
            result[i, j] = (u, v)
    assert len(result) == nx * ny, "missing MPI cells"
    return result


def agreement(left, right):
    assert left.keys() == right.keys()
    error = max(abs(a-b) for key in left for a, b in zip(left[key], right[key]))
    assert error < 2e-11, error
    return error


def main():
    report = {"source_sha256": hashlib.sha256((HERE / "excitable_torus.fme").read_bytes()).hexdigest(),
              "accuracy_sha256": hashlib.sha256((HERE / "accuracy.fme.inc").read_bytes()).hexdigest(),
              "mpi_environment": {key: os.environ[key] for key in
                                  ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in os.environ}}
    grid = (48, 96)
    for case in ("isotropic", "oblique", "twisted"):
        directory = build(OUT / (case + "-diffusion"), case, grid, blocking=4,
                          overrides={"stimulus": "0", "reaction": "0"})
        run(directory, 800, 80, dump=False)
        rows = stats(directory)
        drift = max(abs(r["mass"]-rows[0]["mass"]) for r in rows)
        assert drift < 2e-9, (case, drift)
        assert all(b["square"] <= a["square"] + 1e-9 for a, b in zip(rows, rows[1:]))
        assert rows[-1]["square"] < rows[0]["square"] - 1
        report[case + "_diffusion"] = {"mass_drift": drift,
                                        "square_initial": rows[0]["square"],
                                        "square_final": rows[-1]["square"]}

    rest = build(OUT / "rest", "twisted", grid, blocking=4, overrides={"stimulus": "-1"})
    run(rest, 800, 800)
    report["rest_max_error"] = agreement(fields(rest, 0), fields(rest, 800))

    plain = build(OUT / "plain", "twisted", grid, blocking=0)
    run(plain, 800, 800)
    blocked = build(OUT / "blocked", "twisted", grid, blocking=4)
    run(blocked, 800, 800)
    base = fields(plain, 800)
    report["blocking_max_error"] = agreement(base, fields(blocked, 800))
    if not shutil.which("mpicc") or not shutil.which("mpirun"):
        report["mpi"] = "not tested: mpicc/mpirun unavailable"
    else:
        for shape in ((2, 1), (1, 2)):
            directory = build(OUT / ("mpi-%d-%d" % shape), "twisted", grid, mpi=shape, blocking=4)
            run(directory, 800, 800, mpi=shape)
            report["mpi_%d_%d_max_error" % shape] = agreement(base, fields(directory, 800))

    extra = (HERE / "accuracy.fme.inc").read_text()
    errors = []
    for n in (32, 64, 128):
        directory = build(OUT / ("accuracy-%d" % n), "twisted", (n, 2*n), blocking=0,
                          overrides={"stimulus": "0", "reaction": "0"}, extra_fme=extra)
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
