#!/usr/bin/env python3
"""Focused numerical checks, all using the generated FME solver.

Only compare generated outputs here.  The exact Bessel mode, the error
integrals, the energies, and the shell moments that locate the P and S waves
are computed inside the generated solver (FME/Egison).  This script builds,
runs, and compares numbers.
"""
import csv
import hashlib
import json
import math
import os
import re
import shutil
import struct

from run import HERE, ROOT, NAME, build, run, parameter_lines, spacing

OUT = ROOT / ".build/elastic_shell/verification"
BESSEL = (HERE / "bessel.fme.inc").read_text()
PULSE_INIT = {"  v~i := [| 0, 0, pulse 0 / (r * sin θ) |]~i\n": "  v~i := modeV 0\n",
              "  σ~i~j := [| [| 0, 0, 0 |], [| 0, 0, 0 |], [| 0, 0, 0 |] |]~i~j\n": "  σ~i~j := modeS 0\n"}


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def states(directory, step):
    result = {}
    for path in (directory / "data").glob(f"state-{step:07d}-rank-*.bin"):
        data = path.read_bytes()
        nr, nt, np_, stamp, full = struct.unpack_from("=iiiii", data)
        assert stamp == step and full == 1
        for record in struct.iter_unpack("=iii" + "d" * 11, data[20:]):
            assert record[:3] not in result, "duplicate MPI cell"
            result[record[:3]] = record[3:]
    assert len(result) == nr * nt * np_, "missing MPI cells"
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


def mode_constants():
    """Recompute the constants of bessel.fme.inc: the first root of the mode
    condition (order-3 spherical Bessel functions) at the outer radius 2 and
    the profile at the middle radius."""
    j3 = lambda x: (15 / x ** 3 - 6 / x) * math.sin(x) / x - (15 / x ** 2 - 1) * math.cos(x) / x
    y3 = lambda x: -(15 / x ** 3 - 6 / x) * math.cos(x) / x - (15 / x ** 2 - 1) * math.sin(x) / x
    mode = lambda k, R: j3(k * R) * y3(k) - y3(k * R) * j3(k)
    lo, hi = 0.5, 0.51
    while mode(lo, 2.0) * mode(hi, 2.0) > 0:
        lo, hi = hi, hi + 0.01
    for _ in range(200):
        mid = (lo + hi) / 2
        if mode(lo, 2.0) * mode(mid, 2.0) <= 0:
            hi = mid
        else:
            lo = mid
    kappa = (lo + hi) / 2
    return kappa, mode(kappa, 1.5)


def shared_definitions():
    """The definitions shared by the isotropic and anisotropic models.

    Every definition of the isotropic model appears unchanged in the variant
    except the constitutive function; the variant may add definitions (the
    material direction) and parameters.
    """
    base = (HERE / "elastic_shell.fme").read_text().splitlines()
    variant = (HERE / "elastic_shell_anisotropic.fme").read_text().splitlines()
    defs = lambda lines: {l.split()[1]: l for l in lines if l.startswith("def ")}
    a, b = defs(base), defs(variant)
    assert set(a) <= set(b), sorted(set(a) - set(b))
    changed = sorted(name for name in a if a[name] != b[name])
    assert changed == ["stressRate"], changed
    return {"shared": sorted(name for name in a if name != "stressRate"),
            "changed": changed, "added": sorted(set(b) - set(a))}


def main():
    kappa, amplitude = mode_constants()
    declared = dict(re.findall(r"^param (kappa|amplitude) = (.*)$", BESSEL, flags=re.MULTILINE))
    assert abs(float(declared["kappa"]) - kappa) < 1e-12 and abs(float(declared["amplitude"]) - amplitude) < 1e-12, (declared, kappa, amplitude)
    report = {"source_sha256": hashlib.sha256((HERE / "elastic_shell.fme").read_bytes()).hexdigest(),
              "anisotropic_sha256": hashlib.sha256((HERE / "elastic_shell_anisotropic.fme").read_bytes()).hexdigest(),
              "bessel_sha256": hashlib.sha256(BESSEL.encode()).hexdigest(),
              "mode": {"kappa": kappa, "amplitude": amplitude, "period": 2 * math.pi / kappa},
              "shared_definitions": shared_definitions(),
              "mpi_environment": {key: os.environ[key] for key in
                                  ("HWLOC_SYNTHETIC", "MPIRUN_ARGS") if key in os.environ}}
    have_mpi = shutil.which("mpicc") and shutil.which("mpirun")

    # 1. Temporal blocking and MPI decomposition reproduce the plain build,
    #    with the decomposition cutting the walled axes as well as the
    #    periodic one.  The plain builds run the complete generation pipeline;
    #    the other builds instantiate the cached Formura source (see run.build).
    fresh = {}
    for case in ("spherical", "twisted"):
        grid = (36, 36, 48)
        plain = build(OUT / (case + "-plain"), case, grid, blocking=0, fresh=True)
        fresh[case] = (plain / (NAME + ".fmr")).read_text()
        run(plain, 40, 40, full=True)
        base = states(plain, 40)
        blocked = build(OUT / (case + "-blocked"), case, grid, blocking=4)
        run(blocked, 40, 40, full=True)
        entry = {"blocking_max_error": agreement(base, states(blocked, 40))}
        if not have_mpi:
            entry["mpi"] = "not tested: mpicc/mpirun unavailable"
        else:
            for shape in ((3, 1, 1), (1, 3, 1), (3, 1, 2)):
                directory = build(OUT / (case + "-mpi-%d-%d-%d" % shape), case, grid, mpi=shape, blocking=4)
                run(directory, 40, 40, mpi=shape, full=True)
                entry["mpi_%d_%d_%d_max_error" % shape] = agreement(base, states(directory, 40))
        report[case + "_reproduction"] = entry
    # The two fresh Formura sources differ only in the value of twist, so a
    # normalized source instantiated with other parameter values is the one
    # the complete pipeline would produce.
    a, b = fresh["spherical"].splitlines(), fresh["twisted"].splitlines()
    differing = [(x, y) for x, y in zip(a, b) if x != y]
    assert len(a) == len(b) and differing == [("double :: twist = 0.0", "double :: twist = 0.3")], differing[:3]
    report["parameter_independence"] = {"differing_lines": differing,
                                        "parameters": [name for name, _ in parameter_lines(fresh["spherical"])]}

    # 2. The exact torsional Bessel mode: second-order convergence in both
    #    charts (T = 1 is about half a period).
    accuracy = {}
    for case in ("spherical", "twisted"):
        errors = {}
        for n in (16, 32, 64):
            steps = 20 * n            # T = 1 with dt = 0.05 dr = 0.05 / n
            grid = (n + 1, n + 1, 2 * n)
            mpi = (1, 1, 4) if have_mpi and n >= 64 else (1, 1, 1)
            directory = build(OUT / f"{case}-mode-{n}", case, grid, mpi=mpi, blocking=0,
                              overrides={"T": "1.0"}, substitutions=PULSE_INIT, extra_fme=BESSEL,
                              reductions="err = sum err, ref = sum ref")
            run(directory, steps, steps, mpi=mpi, dump=False)
            last = stats(directory)[-1]
            errors[n] = math.sqrt(last["err"] / last["ref"])
        orders = {f"{a}-{b}": math.log2(errors[a] / errors[b]) for a, b in ((16, 32), (32, 64))}
        assert min(orders.values()) > 1.8, (case, errors, orders)
        accuracy[case] = {"relative_l2_error": errors, "orders": orders}
    report["mode_accuracy"] = accuracy

    # 3. The pulse: energy preservation, P and S speeds from the outer shell
    #    radii (the farthest points where the dimensionless indicators exceed
    #    0.01), and agreement of the two charts.
    pulse = {}
    grid = (49, 49, 96)
    for case in ("spherical", "twisted"):
        mpi = (1, 1, 4) if have_mpi else (1, 1, 1)
        directory = build(OUT / (case + "-pulse"), case, grid, mpi=mpi, blocking=4)
        steps, every = 16 * (grid[0] - 1), grid[0] - 1     # t = 0.8, samples every 0.05
        run(directory, steps, every, mpi=mpi, dump=False)
        rows = stats(directory)
        dt = float(json.loads((directory / "metadata.json").read_text())["parameters"]["dt"].split("*")[0]) * spacing(grid)[0]
        # diagnostics are evaluated on the state entering each step
        samples = [((r["step"] - 1) * dt, r) for r in rows[1:]]
        energies = [r["energy"] for _, r in samples]
        modified = [r["modified"] for _, r in samples]
        # fitting window 0.3 <= t <= 0.7: the shells are separated and the
        # direct fronts are still inside the shell somewhere on their sphere
        fronts_p = [(t, r["pfront"]) for t, r in samples if 0.3 <= t <= 0.7]
        fronts_s = [(t, r["sfront"]) for t, r in samples if 0.3 <= t <= 0.7]
        radii_p = [(t, r["pr"] / r["pw"]) for t, r in samples if 0.3 <= t <= 0.7]
        radii_s = [(t, r["sr"] / r["sw"]) for t, r in samples if 0.3 <= t <= 0.7]
        entry = {"grid": list(grid), "dt": dt, "steps": steps,
                 "energy_band": (min(energies) / energies[0], max(energies) / energies[0]),
                 "modified_energy_relative_drift": max(abs(m - modified[0]) for m in modified) / modified[0],
                 "p_speed": slope(fronts_p), "s_speed": slope(fronts_s),
                 "p_front": fronts_p, "s_front": fronts_s,
                 "p_mean_radius": radii_p, "s_mean_radius": radii_s}
        assert entry["modified_energy_relative_drift"] < 1e-10, entry
        assert 1.5 < entry["p_speed"] < 2.05 and 0.75 < entry["s_speed"] < 1.03, entry
        pulse[case] = entry
    both = [pulse["spherical"], pulse["twisted"]]
    pulse["chart_agreement"] = {
        "energy_relative": max(abs(a["energy_band"][i] - b["energy_band"][i]) for a, b in [both] for i in (0, 1)),
        "p_front_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["p_front"], both[1]["p_front"])),
        "s_front_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["s_front"], both[1]["s_front"])),
        "p_mean_radius_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["p_mean_radius"], both[1]["p_mean_radius"])),
        "s_mean_radius_max_difference": max(abs(a - b) for (_, a), (_, b) in zip(both[0]["s_mean_radius"], both[1]["s_mean_radius"]))}
    # the coarsest physical spacing is along the longitude at the outer wall
    coarsest = 2.0 * spacing(grid)[2]
    assert pulse["chart_agreement"]["p_front_max_difference"] <= 2 * coarsest + 1e-12
    assert pulse["chart_agreement"]["s_front_max_difference"] <= 2 * coarsest + 1e-12
    assert pulse["chart_agreement"]["p_mean_radius_max_difference"] < 0.06
    assert pulse["chart_agreement"]["s_mean_radius_max_difference"] < 0.06
    report["pulse"] = pulse

    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
