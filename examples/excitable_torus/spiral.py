#!/usr/bin/env python3
"""Spiral-wave drift on tori of different thickness, against the curvature
drift law of Dierckx, Brisard, Verschelde and Panfilov (2013).

The same isotropic excitable model runs on three tori (large radius R = 12,
small radius r = 6, 8, 10).  The initial ribbon curls into a pair of
counter-rotating spirals near theta = +-pi/2.  Their tips are phase
singularities of (u - u*, v - v*); the generated solver counts them as
plaquette windings and accumulates sin/cos of their positions, so the mean tip
angle comes from the reductions.  The drift law says that, in an isotropic
medium, the tip drifts along the gradient of the Ricci scalar R = 2K with a
speed proportional to |dR/dtheta| (the proportionality constant depends on the
reaction kinetics only, so it is shared by the three tori).  R and dR/dtheta
are differentiated symbolically by Egison from the same metric and saved with
each run.  This script only builds, runs, reads the outputs and fits.
"""
import argparse
import json
import math
from pathlib import Path
import re
import struct

from run import HERE, ROOT, build, run

REDUCES = ("tipPlus = sum tipPlus, tipMinus = sum tipMinus, plusCos = sum plusCos, "
           "plusSin = sum plusSin, minusCos = sum minusCos, minusSin = sum minusSin, "
           "ricciCheck = absmax ricciCheck")


def trajectory(directory):
    rows = []
    for match in re.finditer(r"spiral step=(\d+) plus=(\S+) minus=(\S+) plusCos=(\S+) plusSin=(\S+) minusCos=(\S+) minusSin=(\S+) ricciCheck=(\S+)",
                             (directory / "run.log").read_text()):
        step, plus, minus, pc, ps, mc, ms, check = (float(x) for x in match.groups())
        rows.append({"step": int(step), "plus": plus, "minus": minus,
                     "theta_plus": math.atan2(ps, pc) if plus else None,
                     "theta_minus": math.atan2(ms, mc) if minus else None,
                     "ricci_check": check})
    return rows


def slope_at(directory, theta):
    """dR/dtheta on the grid row nearest to theta, from the saved field."""
    path = next((directory / "data").glob("frame-0000000-rank-*.bin"))
    data = path.read_bytes()
    nx, ny, _ = struct.unpack_from("=iii", data)
    row = int(round(theta / (2 * math.pi) * nx)) % nx
    for i, j, u, v, w, ricci, slope in struct.iter_unpack("=iiddddd", data[12:]):
        if i == row and j == 0:
            return slope, ricci
    raise ValueError("missing grid row")


def solve(matrix, rhs):
    """Gaussian elimination with partial pivoting (small dense systems)."""
    n = len(rhs)
    a = [row[:] + [b] for row, b in zip(matrix, rhs)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(a[r][col]))
        a[col], a[pivot] = a[pivot], a[col]
        for r in range(n):
            if r != col and a[col][col] != 0:
                f = a[r][col] / a[col][col]
                a[r] = [x - f * y for x, y in zip(a[r], a[col])]
    return [a[i][n] / a[i][i] for i in range(n)]


def least_squares(columns, values):
    normal = [[sum(x * y for x, y in zip(c1, c2)) for c2 in columns] for c1 in columns]
    rhs = [sum(x * y for x, y in zip(c, values)) for c in columns]
    coefficients = solve(normal, rhs)
    residual = [v - sum(k * c[i] for k, c in zip(coefficients, columns)) for i, v in enumerate(values)]
    return coefficients, math.sqrt(sum(r * r for r in residual) / len(values))


def unwrap(points):
    unwrapped, previous, offset = [], points[0][1], 0.0
    for _, theta in points:
        while theta + offset - previous > math.pi:
            offset -= 2 * math.pi
        while theta + offset - previous < -math.pi:
            offset += 2 * math.pi
        previous = theta + offset
        unwrapped.append(previous)
    return unwrapped


def fit_drift(rows, dt, start, key="theta_plus", harmonics=2):
    """Drift of a spiral tip after time `start`.

    The tip of a rotating spiral circles its core, so the unwrapped angle is
    fitted by a line plus a periodic part, theta(t) = a + v t + sum_k (A_k cos
    k w t + B_k sin k w t), with the rotation frequency w chosen on a grid to
    minimise the residual.  The slope v is the drift; the mean angle over the
    window and the fitted period are returned with it.
    """
    points = [(r["step"] * dt, r[key]) for r in rows if r[key] is not None and r["step"] * dt >= start]
    if len(points) < 8:
        return None
    times = [t for t, _ in points]
    angles = unwrap(points)
    best = None
    span = times[-1] - times[0]
    for period in [span / n for n in range(2, len(points) // 3)]:
        w = 2 * math.pi / period
        columns = [[1.0] * len(times), times]
        for k in range(1, harmonics + 1):
            columns.append([math.cos(k * w * t) for t in times])
            columns.append([math.sin(k * w * t) for t in times])
        coefficients, rms = least_squares(columns, angles)
        if best is None or rms < best["residual_rms"]:
            best = {"drift": coefficients[1], "period": period, "residual_rms": rms}
    best["mean_angle"] = math.atan2(sum(math.sin(a) for a in angles), sum(math.cos(a) for a in angles))
    best["window"] = [times[0], times[-1]]
    return best


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/excitable_torus/spiral")
    parser.add_argument("--time", type=float, default=600.0)
    parser.add_argument("--start", type=float, default=100.0, help="fit the drift after the pair has formed")
    parser.add_argument("--reuse", action="store_true", help="only refit runs that already exist in --output")
    parser.add_argument("--figure", action="store_true", help="draw results/spiral.png (needs matplotlib)")
    args = parser.parse_args()
    extra = (HERE / "spiral.fme.inc").read_text()
    report = {"cases": []}
    for r in (6.0, 8.0, 10.0):
        grid = (96, 192)
        hmin = min(r * 2 * math.pi / grid[0], (12.0 - r) * 2 * math.pi / grid[1])
        dt = min(0.005, 0.15 * hmin * hmin / 0.625)
        # 240 output rows; the driver needs the step count to be a multiple of the interval.
        steps = max(240, int(round(args.time / dt / 240)) * 240)
        every = steps // 240
        directory = args.output / f"r{r:g}"
        if not (args.reuse and (directory / "run.log").exists()):
            directory = build(directory, "isotropic", grid, blocking=0,
                              overrides={"r": str(r), "dt": str(dt)}, extra_fme=extra,
                              reductions=REDUCES, flag="SPIRAL")
            run(directory, steps, every)
        rows = trajectory(directory)
        # The Ricci scalar that Egison derived from the metric must agree with
        # the closed form 2 cos(theta) / (r (R + r cos(theta))) of the torus.
        assert max(x["ricci_check"] for x in rows) < 1e-12, rows[0]["ricci_check"]
        plus = fit_drift(rows, dt, args.start, "theta_plus")
        minus = fit_drift(rows, dt, args.start, "theta_minus")
        # The two tips are mirror images in theta, so their drifts have opposite signs.
        drift = None if plus is None or minus is None else (plus["drift"] - minus["drift"]) / 2
        theta = plus["mean_angle"] if plus else math.pi / 2
        slope, ricci = slope_at(directory, theta)
        report["cases"].append({"r": r, "dt": dt, "steps": steps, "grid": list(grid),
                                "tips_final": [rows[-1]["plus"], rows[-1]["minus"]],
                                "theta_plus_mean": theta, "drift_dtheta_dt": drift,
                                "fit_plus": plus, "fit_minus": minus,
                                "ricci_scalar_at_tip": ricci, "ricci_slope_at_tip": slope,
                                "ricci_closed_form_max_difference": max(x["ricci_check"] for x in rows),
                                "trajectory": [{"t": x["step"] * dt, "theta_plus": x["theta_plus"], "theta_minus": x["theta_minus"],
                                                "plus": x["plus"], "minus": x["minus"]} for x in rows]})
    valid = [c for c in report["cases"] if c["drift_dtheta_dt"] is not None]
    for c in valid:
        # Physical units: the tip speed along the tube is r dtheta/dt and the
        # gradient of R along the tube is (1/r) dR/dtheta, so the drift law
        # speed = -q1 * gradient gives q1 = -r^2 (dtheta/dt) / (dR/dtheta).
        c["drift_speed"] = c["r"] * c["drift_dtheta_dt"]
        c["ricci_gradient"] = c["ricci_slope_at_tip"] / c["r"]
        c["fitted_q1"] = -c["drift_speed"] / c["ricci_gradient"]
    if len(valid) >= 2:
        # The drift law predicts one q1 for all tori.
        q1 = [c["fitted_q1"] for c in valid]
        report["fitted_q1_per_case"] = q1
        report["q1_spread"] = (max(q1) - min(q1)) / max(abs(x) for x in q1)
    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "spiral.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "cases"}, indent=2))
    if args.figure:
        figure(report, destination / "spiral.png")
    for c in report["cases"]:
        print("r=%g: tips %s, mean theta_plus=%.3f, drift=%s rad/time (+tip %s, -tip %s; period %s, residual %s), dR/dtheta=%.4g, q1=%s" % (
            c["r"], c["tips_final"], c["theta_plus_mean"], c["drift_dtheta_dt"],
            c["fit_plus"] and "%.2e" % c["fit_plus"]["drift"], c["fit_minus"] and "%.2e" % c["fit_minus"]["drift"],
            c["fit_plus"] and "%.1f" % c["fit_plus"]["period"], c["fit_plus"] and "%.3f" % c["fit_plus"]["residual_rms"],
            c["ricci_slope_at_tip"], c.get("fitted_q1")))


def figure(report, path):
    """Display only: the tip angles of the three tori and the drift fits."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "savefig.facecolor": "#fafafa", "figure.facecolor": "#fafafa"})
    fig, axes = plt.subplots(1, len(report["cases"]), figsize=(4.6 * len(report["cases"]), 3.4), layout="constrained", sharey=True)
    for ax, c in zip(axes, report["cases"]):
        for key, color, label in (("theta_plus", "#c0392b", "+1 tip"), ("theta_minus", "#2471a3", "−1 tip")):
            points = [(x["t"], x[key]) for x in c["trajectory"] if x[key] is not None and x["t"] >= c["fit_plus"]["window"][0]]
            ax.plot([t for t, _ in points], unwrap(points), ".", ms=2.5, color=color, label=label)
        for fit, color in ((c["fit_plus"], "#c0392b"), (c["fit_minus"], "#2471a3")):
            t0, t1 = fit["window"]
            mean = fit["mean_angle"]
            ax.plot([t0, t1], [mean - fit["drift"] * (t1 - t0) / 2, mean + fit["drift"] * (t1 - t0) / 2], "-", lw=2, color=color, alpha=0.8)
        ax.set_title("r = %g:  dθ/dt = %.1e,  dR/dθ = %.1e" % (c["r"], c["drift_dtheta_dt"], c["ricci_slope_at_tip"]), fontsize=9)
        ax.set_xlabel("time")
        ax.axhline(0, color="#999", lw=0.5)
    axes[0].set_ylabel("tip angle θ around the tube (rad)")
    axes[0].legend(loc="lower left", fontsize=8)
    fig.suptitle("Spiral tips on tori of small radius r = 6, 8, 10 (R = 12); lines: fitted drift", fontsize=11, fontweight="bold")
    fig.savefig(path, dpi=140)


if __name__ == "__main__":
    main()
