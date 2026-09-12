#!/usr/bin/env python3
"""Focused numerical checks, all using the generated FME solver.

Only compare generated outputs here.  The exact plane-wave solutions, the
error integrals, the energies, and the shell moments that locate the P and S
waves are computed inside the generated solver (FME/Egison).  This script
builds, runs, and compares numbers.
"""
import csv
import hashlib
import json
import math
import os
import re
import shutil
import struct

from run import HERE, ROOT, NAME, build, run, parameter_lines

OUT = ROOT / ".build/elastic_pulse/verification"
PLANE = (HERE / "plane.fme.inc").read_text()
PULSE_INIT = {"  v~i := [| pulse 0, 0, 0 |]~i\n": "  v~i := planeV 0\n",
              "  σ~i~j := [| [| 0, 0, 0 |], [| 0, 0, 0 |], [| 0, 0, 0 |] |]~i~j\n": "  σ~i~j := planeS 0\n"}
LENGTH = 4.0


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def states(directory, step):
    result = {}
    for path in (directory / "data").glob(f"state-{step:07d}-rank-*.bin"):
        data = path.read_bytes()
        nx, ny, nz, stamp, full = struct.unpack_from("=iiiii", data)
        assert stamp == step and full == 1
        for record in struct.iter_unpack("=iii" + "d" * 11, data[20:]):
            assert record[:3] not in result, "duplicate MPI cell"
            result[record[:3]] = record[3:]
    assert len(result) == nx * ny * nz, "missing MPI cells"
    return result


def agreement(left, right):
    assert left.keys() == right.keys()
    error = max(abs(a - b) for key in left for a, b in zip(left[key], right[key]))
    assert error < 2e-11, error
    return error


def slope(points):
    # least-squares slope of (t, r) samples
    n = len(points)
    mt = sum(t for t, _ in points) / n
    mr = sum(r for _, r in points) / n
    return sum((t - mt) * (r - mr) for t, r in points) / sum((t - mt) ** 2 for t, _ in points)


def shared_definitions():
    """The definitions shared by the isotropic and anisotropic models.

    Every definition of the isotropic model appears unchanged in the variant
    except the constitutive function; the variant may add definitions (the
    material direction) and parameters.
    """
    base = (HERE / "elastic_pulse.fme").read_text().splitlines()
    variant = (HERE / "elastic_pulse_anisotropic.fme").read_text().splitlines()
    defs = lambda lines: {l.split()[1]: l for l in lines if l.startswith("def ")}
    a, b = defs(base), defs(variant)
    assert set(a) <= set(b), sorted(set(a) - set(b))
    changed = sorted(name for name in a if a[name] != b[name])
    assert changed == ["stressRate"], changed
    return {"shared": sorted(name for name in a if name != "stressRate"),
            "changed": changed, "added": sorted(set(b) - set(a))}


def main():
    report = {"source_sha256": hashlib.sha256((HERE / "elastic_pulse.fme").read_bytes()).hexdigest(),
              "anisotropic_sha256": hashlib.sha256((HERE / "elastic_pulse_anisotropic.fme").read_bytes()).hexdigest(),
              "plane_sha256": hashlib.sha256(PLANE.encode()).hexdigest(),
              "shared_definitions": shared_definitions(),
              "mpi_environment": {key: os.environ[key] for key in
                                  ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in os.environ}}

    # 1. Temporal blocking and MPI decomposition reproduce the plain build.
    #    The plain builds run the complete generation pipeline; the other
    #    builds instantiate the cached Formura source (see run.build).
    fresh = {}
    for case in ("cartesian", "sheared"):
        grid = (48, 48, 48)
        plain = build(OUT / (case + "-plain"), case, grid, blocking=0, fresh=True)
        fresh[case] = (plain / (NAME + ".fmr")).read_text()
        run(plain, 40, 40, full=True)
        base = states(plain, 40)
        blocked = build(OUT / (case + "-blocked"), case, grid, blocking=4)
        run(blocked, 40, 40, full=True)
        entry = {"blocking_max_error": agreement(base, states(blocked, 40))}
        if not shutil.which("mpicc") or not shutil.which("mpirun"):
            entry["mpi"] = "not tested: mpicc/mpirun unavailable"
        else:
            for shape in ((2, 1, 1), (1, 2, 1)):
                directory = build(OUT / (case + "-mpi-%d-%d-%d" % shape), case, grid, mpi=shape, blocking=4)
                run(directory, 40, 40, mpi=shape, full=True)
                entry["mpi_%d_%d_%d_max_error" % shape] = agreement(base, states(directory, 40))
        report[case + "_reproduction"] = entry
    # The two fresh Formura sources differ only in the value of shear, so a
    # normalized source instantiated with other parameter values is the one
    # the complete pipeline would produce.
    a, b = fresh["cartesian"].splitlines(), fresh["sheared"].splitlines()
    differing = [(x, y) for x, y in zip(a, b) if x != y]
    assert len(a) == len(b) and differing == [("double :: shear = 0.0", "double :: shear = 0.3")], differing[:3]
    report["parameter_independence"] = {"differing_lines": differing,
                                        "parameters": [name for name, _ in parameter_lines(fresh["cartesian"])]}

    # 2. Exact plane P and S waves: second-order convergence in both charts.
    accuracy = {}
    for case in ("cartesian", "sheared"):
        for wave, label in ((1, "P"), (2, "S")):
            errors = {}
            for n in (16, 32, 64):
                steps = 5 * n // 2          # T = 1 with dt = 0.1 dx
                # no temporal blocking here: a 16-cell axis is shorter than the
                # blocked halo (2 * sleeve * interval = 24 cells)
                directory = build(OUT / f"{case}-plane-{label}-{n}", case, (n, n, n), blocking=0,
                                  overrides={"wave": str(wave), "T": "1.0", "dt": repr(1.0 / steps)},
                                  substitutions=PULSE_INIT, extra_fme=PLANE,
                                  reductions="err = sum err, ref = sum ref")
                run(directory, steps, steps, dump=False)
                last = stats(directory)[-1]
                errors[n] = math.sqrt(last["err"] / last["ref"])
            orders = {f"{a}-{b}": math.log2(errors[a] / errors[b]) for a, b in ((16, 32), (32, 64))}
            assert min(orders.values()) > 1.8, (case, label, errors, orders)
            accuracy[f"{case}_{label}"] = {"relative_l2_error": errors, "orders": orders}
    report["plane_wave_accuracy"] = accuracy

    # 3. The pulse: energy preservation, P and S speeds from the outer shell
    #    radii (the farthest points where the dimensionless indicators exceed
    #    0.01), and agreement of the two charts.
    pulse = {}
    for case in ("cartesian", "sheared"):
        n = 64
        directory = build(OUT / (case + "-pulse"), case, (n, n, n), blocking=4)
        steps, every = 128, 8            # t = 0.8 with dt = 0.1 dx = 1/160
        run(directory, steps, every, dump=False)
        rows = stats(directory)
        dt = float(json.loads((directory / "metadata.json").read_text())["parameters"]["dt"].split("*")[0]) * LENGTH / n
        # diagnostics are evaluated on the state entering each step
        samples = [((r["step"] - 1) * dt, r) for r in rows[1:]]
        energies = [r["energy"] for _, r in samples]
        modified = [r["modified"] for _, r in samples]
        # fitting window 0.3 <= t <= 0.7: the shells are separated and the
        # P front is still well inside the box
        fronts_p = [(t, r["pfront"]) for t, r in samples if 0.3 <= t <= 0.7]
        fronts_s = [(t, r["sfront"]) for t, r in samples if 0.3 <= t <= 0.7]
        radii_p = [(t, r["pr"] / r["pw"]) for t, r in samples if 0.3 <= t <= 0.7]
        radii_s = [(t, r["sr"] / r["sw"]) for t, r in samples if 0.3 <= t <= 0.7]
        entry = {"grid": n, "dt": dt, "steps": steps,
                 "energy_band": (min(energies) / energies[0], max(energies) / energies[0]),
                 "modified_energy_relative_drift": max(abs(m - modified[0]) for m in modified) / modified[0],
                 "p_speed": slope(fronts_p), "s_speed": slope(fronts_s),
                 "p_front": fronts_p, "s_front": fronts_s,
                 "p_mean_radius": radii_p, "s_mean_radius": radii_s}
        assert entry["modified_energy_relative_drift"] < 1e-10, entry
        # the outer edges carry the shortest wavelengths of the pulse (four cells
        # per pulse radius here), which centered differences propagate slowly,
        # and a fixed threshold lags behind a decaying front; the slopes on the
        # 128^3 demonstration grid are 1.86/0.96 (runs.json)
        assert 1.5 < entry["p_speed"] < 2.05 and 0.75 < entry["s_speed"] < 1.03, entry
        pulse[case] = entry
    both = [pulse["cartesian"], pulse["sheared"]]
    pulse["chart_agreement"] = {
        "energy_relative": max(abs(a["energy_band"][i] - b["energy_band"][i]) for a, b in [both] for i in (0, 1)),
        "p_front_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["p_front"], both[1]["p_front"])),
        "s_front_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["s_front"], both[1]["s_front"])),
        "p_mean_radius_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["p_mean_radius"], both[1]["p_mean_radius"])),
        "s_mean_radius_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["s_mean_radius"], both[1]["s_mean_radius"]))}
    spacing = LENGTH / 64
    assert pulse["chart_agreement"]["p_front_max_difference"] <= 2 * spacing + 1e-12
    assert pulse["chart_agreement"]["s_front_max_difference"] <= 2 * spacing + 1e-12
    assert pulse["chart_agreement"]["p_mean_radius_max_difference"] < 0.03
    assert pulse["chart_agreement"]["s_mean_radius_max_difference"] < 0.03
    report["pulse"] = pulse

    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
