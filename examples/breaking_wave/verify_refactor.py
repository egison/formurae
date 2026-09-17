#!/usr/bin/env python3
"""Compare generated equations and saved outputs before/after the refactor.

This reads existing runs; it does not evolve or reconstruct physical fields.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


# These values are read only before stage 3 changes f, mass and kind.
# Re-evaluating their defining locals therefore gives the stage-0 values.
RECOMPUTED = {"savedRho": "rho", "savedU_down1": "u_down1",
              "savedU_down2": "u_down2", "savedEps": "eps"}


def assignments(path):
    result = {}
    section = None
    for line in path.read_text().splitlines():
        if line.startswith("begin function"):
            section = "init" if "= init()" in line else "step"
        match = re.fullmatch(r"  ([A-Za-z][A-Za-z0-9_]*'?)\[i,j\] = (.*)", line)
        if match:
            key = (section, match[1])
            assert key not in result, f"duplicate assignment: {key}"
            result[key] = match[2]
    assert result, f"no generated assignments: {path}"
    return result


def metadata(directory):
    meta = json.loads((directory / "metadata.json").read_text())
    source = (directory / "breaking_wave.fme").read_bytes()
    assert hashlib.sha256(source).hexdigest() == meta["source_sha256"]
    return meta


def compare(baseline, candidate):
    before, after = metadata(baseline), metadata(candidate)
    for key in ("grid", "parameters", "steps", "every"):
        assert before[key] == after[key], f"different run setting: {key}"
    assert (baseline / "breaking_wave.yaml").read_bytes() == (candidate / "breaking_wave.yaml").read_bytes()

    old = assignments(baseline / "breaking_wave.fmr")
    new = assignments(candidate / "breaking_wave.fmr")
    removed = {(phase, name + suffix) for name in RECOMPUTED
               for phase, suffix in (("init", ""), ("step", "'"))}
    assert old.keys() - new.keys() == removed, "unexpected removed equations"
    assert not new.keys() - old.keys(), "unexpected added equations"
    for key, expression in new.items():
        expected = old[key]
        for saved, local in RECOMPUTED.items():
            expected = re.sub(r"\b" + saved + r"(?=\[)", local, expected)
        assert expected == expression, f"changed generated expression: {key}"

    assert (baseline / "stats.csv").read_bytes() == (candidate / "stats.csv").read_bytes(), "different diagnostics"
    names = [f"frame-{step:07d}.bin"
             for step in range(0, after["steps"] + 1, after["every"])]
    for directory in (baseline, candidate):
        assert sorted(p.name for p in (directory / "data").glob("frame-*.bin")) == names
    for name in names:
        assert (baseline / "data" / name).read_bytes() == (candidate / "data" / name).read_bytes(), f"different frame: {name}"

    return {"baseline_source_sha256": before["source_sha256"],
            "refactored_source_sha256": after["source_sha256"],
            "grid": after["grid"], "steps": after["steps"], "every": after["every"],
            "removed_state_components": list(RECOMPUTED),
            "retained_generated_assignments": len(new),
            "equations_equal_after_recomputed_aliases": True,
            "diagnostics_byte_identical": True,
            "saved_frames_byte_identical": True, "compared_frames": len(names),
            "frame_fields": ["fraction", "speed", "wall", "bank", "kind", "mass",
                             "density", "velocityX", "velocityY"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.baseline, args.candidate)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
