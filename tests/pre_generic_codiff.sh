#!/bin/sh

# One macro body defines the weighted discrete codifferential for every
# form degree:
#
#   macro δc A = local w : tensor @ primal = dFlux A
#                in dFluxDiv w
#
# The deferred local materializes the weighted flux at whatever degree the
# operand has, and the two library parts carry the degree genericity.  Two
# gates pin its equivalence with the schemes the compiler already trusts:
#
#   * On the staggered metric torus, Δ written as -δc(dExterior u) must
#     regenerate the hand-written conservative flux form byte-for-byte
#     (the lifted local's name is the only allowed difference).
#   * On the flat Yee lattice, δc B must match the canonical δ B of the
#     maxwell_dec example after substituting the identity flux local and
#     normalizing -(a - b) to (b - a), which the opaque grid-derivative
#     boundary keeps as distinct spellings of the same exact value.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-generic-codiff.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"

compile_pipeline() {
  source=$1
  stem=$2
  cabal run -v0 -j1 formurae-pre -- "$source" > "$WORK/$stem.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/$stem.egi" > "$WORK/$stem.feir"
  cabal run -v0 -j1 formurae-post -- "$WORK/$stem.feir" > "$WORK/$stem.fmr"
}

compile_pipeline tests/fixtures/pre_macro_torus.fme hand-torus
compile_pipeline tests/fixtures/pre_macro_codiff_torus.fme generic-torus
sed 's/w_\([123]\)/q_up\1/g' "$WORK/generic-torus.fmr" \
  > "$WORK/generic-torus-renamed.fmr"
if ! cmp -s "$WORK/hand-torus.fmr" "$WORK/generic-torus-renamed.fmr"; then
  printf 'generic codiff macro diverged from the hand-written torus scheme\n' >&2
  diff "$WORK/hand-torus.fmr" "$WORK/generic-torus-renamed.fmr" >&2 || true
  exit 1
fi

compile_pipeline examples/maxwell_dec/maxwell_dec.fme builtin-maxwell
compile_pipeline tests/fixtures/pre_macro_codiff_maxwell.fme generic-maxwell
python3 - "$WORK" <<'EOF'
import re
import sys

work = sys.argv[1]

def canonical(path, drop_identity_locals):
    lines = []
    for line in open(path):
        line = line.replace("w_1_2", "B_1_2").replace("w_1_3", "B_1_3") \
                   .replace("w_2_3", "B_2_3")
        if drop_identity_locals and re.fullmatch(
            r"\s*(B_\d_\d)\[i,j,k\] = \1\[i,j,k\]\n", line):
            continue
        # -(a - b) and (b - a) are the same exact value; the opaque grid
        # derivative keeps them as distinct spellings.
        line = re.sub(
            r"\(-1\) \* dt \* \((B_\d_\d\[[^]]*\]) \+ \(-1\) \* (B_\d_\d\[[^]]*\])\)",
            r"dt * (\2 + (-1) * \1)",
            line)
        lines.append(line)
    return lines

builtin = canonical(f"{work}/builtin-maxwell.fmr", False)
generic = canonical(f"{work}/generic-maxwell.fmr", True)
if builtin != generic:
    import difflib
    sys.stderr.write("generic codiff macro diverged from canonical δ on maxwell_dec\n")
    sys.stderr.writelines(difflib.unified_diff(builtin, generic))
    sys.exit(1)
EOF

printf 'generic codiff macro tests: ok\n'
