#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
FORMURA=${FORMURA:-"$ROOT/bin/formura"}
CC=${CC:-cc}
FIXTURE="$ROOT/tests/fixtures/pre_fec_algebraic.fme"
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-fec.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

run_machine() {
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" "$1" > "$2"
}

compile_and_check() {
  name=$1
  check_source=$2
  fmr=$3
  directory="$WORK/c-$name"
  mkdir "$directory"
  cp "$fmr" "$directory/$name.fmr"
  cp "$ROOT/examples/$name/$name.yaml" "$directory/$name.yaml"
  cp "$ROOT/examples/$name/$check_source" "$directory/$check_source"
  (cd "$directory" && "$FORMURA" "$name.fmr")
  "$CC" -O2 -std=c11 -I"$directory" -I"$ROOT/mpistub" \
    -o "$directory/check" "$directory/$check_source" "$directory/$name.c" -lm
  "$directory/check"
}

compile_generated() {
  name=$1
  yaml_example=$2
  fmr=$3
  directory="$WORK/c-$name"
  mkdir "$directory"
  cp "$fmr" "$directory/$name.fmr"
  cp "$ROOT/examples/$yaml_example/$yaml_example.yaml" \
    "$directory/$name.yaml"
  (cd "$directory" && "$FORMURA" "$name.fmr")
  "$CC" -O2 -std=c11 -I"$directory" -I"$ROOT/mpistub" \
    -c "$directory/$name.c" -o "$directory/$name.o"
}

cd "$ROOT"
cabal run -v0 -j1 pre-fec -- "$FIXTURE" > "$WORK/model.egi"

for forbidden in 'def dC ' 'def dC2 ' dYee FMR. fieldEqs; do
  if grep -F "$forbidden" "$WORK/model.egi" >/dev/null; then
    printf 'generated normalization unit contains forbidden backend text: %s\n' "$forbidden" >&2
    exit 1
  fi
done

run_machine "$WORK/model.egi" "$WORK/model.feir"

cabal run -v0 -j1 post-fec -- "$WORK/model.feir" > "$WORK/model.fmr"
grep -F 'u[i,j] = 1 + alpha * dr * i' "$WORK/model.fmr" >/dev/null
grep -F 'flux[i,j] = alpha * u[i,j] + u[i,j]**2' "$WORK/model.fmr" >/dev/null
grep -F 'extern function :: exp' "$WORK/model.fmr" >/dev/null
grep -F 'gauss = fun(r) exp(0.0 - r*r)' "$WORK/model.fmr" >/dev/null

sed 's/(registry-id "sha256:[0-9a-f]*/(registry-id "sha256:tampered/' \
  "$WORK/model.feir" > "$WORK/tampered.feir"
if cabal run -v0 -j1 post-fec -- "$WORK/tampered.feir" \
     > "$WORK/tampered.fmr" 2> "$WORK/tampered.err"; then
  printf 'post-fec accepted a tampered logical registry fingerprint\n' >&2
  exit 1
fi
grep -F 'registry ID mismatch' "$WORK/tampered.err" >/dev/null

# Canonical scalar Delta expands through the pure Cartesian scalar-Laplacian
# definition and normalizes to one second-order FieldJet, not nested stencils.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_scalar_delta_1d.fme" \
  > "$WORK/derivative.egi"
grep -F 'def FormuraeInternalScalarDelta u := Formurae.scalarLaplacian' \
  "$WORK/derivative.egi" >/dev/null
grep -F 'FormuraeInternalScalarDelta u' \
  "$WORK/derivative.egi" >/dev/null
run_machine "$WORK/derivative.egi" "$WORK/derivative.feir"
grep -F '(axis-order (axis 1) (count 2))' "$WORK/derivative.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/derivative.feir" > "$WORK/derivative.fmr"
grep -F 'u[i-1] + u[i+1] + (-2) * u[i]' "$WORK/derivative.fmr" >/dev/null

# Indexed Unicode delta is hygienically bound to Egison's Kronecker tensor;
# an ordinary user function named ASCII `delta` cannot capture it.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_kronecker_delta_hygiene.fme" \
  > "$WORK/kronecker.egi"
grep -F 'FormuraeInternalKroneckerDelta~i_j . X~j' \
  "$WORK/kronecker.egi" >/dev/null
run_machine "$WORK/kronecker.egi" "$WORK/kronecker.feir"
cabal run -v0 -j1 post-fec -- "$WORK/kronecker.feir" \
  > "$WORK/kronecker.fmr"
grep -F "X_down1'[i,j] = X_down1[i,j]" "$WORK/kronecker.fmr" >/dev/null
grep -F "X_down2'[i,j] = X_down2[i,j]" "$WORK/kronecker.fmr" >/dev/null

# A pure user operator may use Egison's full let/lambda/match expression
# syntax across multiple indented lines.  pre-fec preserves the layout needed
# by match clauses, while Egison remains responsible for normalization.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_raw_operator.fme" \
  > "$WORK/raw-operator.egi"
grep -F 'let lap := FormuraeInternalLap' "$WORK/raw-operator.egi" >/dev/null
grep -F 'let apply := \f x -> f x' "$WORK/raw-operator.egi" >/dev/null
grep -F '      metric := \value -> value' \
  "$WORK/raw-operator.egi" >/dev/null
grep -F '      choose := match 1 as integer with' \
  "$WORK/raw-operator.egi" >/dev/null
run_machine "$WORK/raw-operator.egi" "$WORK/raw-operator.feir"
cabal run -v0 -j1 post-fec -- "$WORK/raw-operator.feir" \
  > "$WORK/raw-operator.fmr"
grep -F "u'[i] = 1 + u[i]" "$WORK/raw-operator.fmr" >/dev/null
grep -F "q'[i] = (q[i-1] + q[i+1] + (-2) * q[i]) / dx**2" \
  "$WORK/raw-operator.fmr" >/dev/null

# Higher-order passage preserves the ambient operator closure and the tensor
# metadata of standard operators.  `apply grad u` must therefore reach a
# whole covector target, not an anonymous one-form axis.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/formurae_standard_ops.fme" \
  > "$WORK/standard-ops.egi"
grep -F 'apply FormuraeInternalGrad u' \
  "$WORK/standard-ops.egi" >/dev/null
run_machine "$WORK/standard-ops.egi" "$WORK/standard-ops.feir"
grep -F '(shape (2)) (variances (down)) (df-order 0)' \
  "$WORK/standard-ops.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/standard-ops.feir" \
  > "$WORK/standard-ops.fmr"
grep -F "q_down1'[i,j] = ((-1 / 2) * u[i-1,j] + (1 / 2) * u[i+1,j]) / dx" \
  "$WORK/standard-ops.fmr" >/dev/null
grep -F "q_down2'[i,j] = ((-1 / 2) * u[i,j-1] + (1 / 2) * u[i,j+1]) / dy" \
  "$WORK/standard-ops.fmr" >/dev/null

# Rank-two derivative operators retain their declared ordinary-tensor
# metadata.  Metric musical maps below are written as explicit contractions
# on indexed equation targets rather than hidden behind named helpers.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/formurae_native_rank2_ops.fme" \
  > "$WORK/rank2-ops.egi"
run_machine "$WORK/rank2-ops.egi" "$WORK/rank2-ops.feir"
grep -F '(shape (2 2)) (variances (down down)) (df-order 0)' \
  "$WORK/rank2-ops.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/rank2-ops.feir" \
  > "$WORK/rank2-ops.fmr"
grep -F "H_down1_down2'[i,j] =" "$WORK/rank2-ops.fmr" >/dev/null
grep -F "G_down2_down1'[i,j] =" "$WORK/rank2-ops.fmr" >/dev/null

cabal run -v0 -j1 pre-fec -- "$ROOT/tests/formurae_musical_ops.fme" \
  > "$WORK/musical-ops.egi"
run_machine "$WORK/musical-ops.egi" "$WORK/musical-ops.feir"
cabal run -v0 -j1 post-fec -- "$WORK/musical-ops.feir" \
  > "$WORK/musical-ops.fmr"
grep -F "A_down1'[i,j] = 4 * X_up1[i,j]" "$WORK/musical-ops.fmr" >/dev/null
grep -F "X_up1'[i,j] = (1 / 4) * A_down1[i,j]" "$WORK/musical-ops.fmr" >/dev/null

# Symbolic predicates remain data through Egison normalization.  The encoder
# canonicalizes boolean collections and emits one Select per tensor component;
# post-fec alone resolves sampling placement.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_conditional.fme" \
  > "$WORK/conditional.egi"
grep -F 'Formurae.select (Formurae.predicateOr' "$WORK/conditional.egi" >/dev/null
run_machine "$WORK/conditional.egi" "$WORK/conditional.feir"
grep -F '(select (or (compare ge ' "$WORK/conditional.feir" >/dev/null
grep -F '(select (and (compare ge ' "$WORK/conditional.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/conditional.feir" \
  > "$WORK/conditional.fmr"
grep -F 'u[i,j] = if dx * i < threshold then 1 else 0' \
  "$WORK/conditional.fmr" >/dev/null
grep -F "v'[i,j] = if ((dx * i < threshold) == 0) + (u[i,j] >= 0) > 0 then u[i,j] else threshold" \
  "$WORK/conditional.fmr" >/dev/null
grep -F "q_down1'[i,j] = if (dx * i < threshold) * (u[i,j] >= 0)" \
  "$WORK/conditional.fmr" >/dev/null
if grep -F 'max(' "$WORK/conditional.fmr" >/dev/null; then
  printf 'predicate Or lowering introduced an undeclared max helper\n' >&2
  exit 1
fi
compile_generated conditional diffusion2d "$WORK/conditional.fmr"

# Both update fields and materialized step-local fields bind Formura's grid
# coordinate variables from their indexed assignment targets.  A bare target
# would leave the `i` in dx*i undefined during Formura code generation.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_coordinate_targets.fme" \
  > "$WORK/coordinate-targets.egi"
run_machine "$WORK/coordinate-targets.egi" "$WORK/coordinate-targets.feir"
cabal run -v0 -j1 post-fec -- "$WORK/coordinate-targets.feir" \
  > "$WORK/coordinate-targets.fmr"
grep -F 'position[i] = dx * i' "$WORK/coordinate-targets.fmr" >/dev/null
grep -F "u'[i] = position[i] + u[i]" "$WORK/coordinate-targets.fmr" >/dev/null
compile_generated coordinate-targets diffusion1d "$WORK/coordinate-targets.fmr"

# Indexed, rank-two, and form locals reuse the same logical descriptor and
# component projection as user fields.  Their Materialize actions remain in
# source order, and every canonical component becomes one step binding.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_tensor_locals.fme" \
  > "$WORK/tensor-locals.egi"
grep -F 'def FormuraeInternalValue1_i : Tensor MathValue := Q_i' \
  "$WORK/tensor-locals.egi" >/dev/null
grep -F 'FormuraeInternalEncodeTensor [2,2] ["up","down"] 0' \
  "$WORK/tensor-locals.egi" >/dev/null
grep -F 'FormuraeInternalEncodeTensor [2,2] ["down","down"] 2' \
  "$WORK/tensor-locals.egi" >/dev/null
grep -F 'Formurae.requireSymmetricRank2' \
  "$WORK/tensor-locals.egi" >/dev/null
grep -F 'Formurae.requireAntisymmetricRank2' \
  "$WORK/tensor-locals.egi" >/dev/null
run_machine "$WORK/tensor-locals.egi" "$WORK/tensor-locals.feir"
grep -F '(source-name "q") (policy primal)' \
  "$WORK/tensor-locals.feir" >/dev/null
grep -F '(source-name "stress") (policy dual)' \
  "$WORK/tensor-locals.feir" >/dev/null
grep -F '(source-name "omega") (policy primal)' \
  "$WORK/tensor-locals.feir" >/dev/null
grep -F '(source-name "symbuf") (policy primal)' \
  "$WORK/tensor-locals.feir" >/dev/null
grep -F '(source-name "antibuf") (policy dual)' \
  "$WORK/tensor-locals.feir" >/dev/null
grep -F '(layout symmetric)' "$WORK/tensor-locals.feir" >/dev/null
grep -F '(layout antisymmetric)' "$WORK/tensor-locals.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/tensor-locals.feir" \
  > "$WORK/tensor-locals.fmr"
grep -F 'q_down1[i,j] = Q_down1[i,j]' "$WORK/tensor-locals.fmr" >/dev/null
grep -F 'stress_up2_down1[i,j] = T_up2_down1[i,j]' \
  "$WORK/tensor-locals.fmr" >/dev/null
grep -F 'omega_1_2[i,j] =' "$WORK/tensor-locals.fmr" >/dev/null
grep -F "B_1_2'[i,j] = omega_1_2[i,j]" \
  "$WORK/tensor-locals.fmr" >/dev/null
grep -F 'symbuf_down1_down2[i,j] = S_down1_down2[i,j]' \
  "$WORK/tensor-locals.fmr" >/dev/null
grep -F 'antibuf_down1_down2[i,j] = W_down1_down2[i,j]' \
  "$WORK/tensor-locals.fmr" >/dev/null
grep -F "S_down1_down2'[i,j] = symbuf_down1_down2[i,j]" \
  "$WORK/tensor-locals.fmr" >/dev/null
grep -F "W_down1_down2'[i,j] = antibuf_down1_down2[i,j]" \
  "$WORK/tensor-locals.fmr" >/dev/null
producer_line=$(grep -n 'omega_1_2\[i,j\] =' "$WORK/tensor-locals.fmr" \
  | cut -d: -f1)
consumer_line=$(grep -n "B_1_2'\[i,j\] = omega_1_2" \
  "$WORK/tensor-locals.fmr" | cut -d: -f1)
sym_producer_line=$(grep -n 'symbuf_down1_down2\[i,j\] =' \
  "$WORK/tensor-locals.fmr" | cut -d: -f1)
sym_consumer_line=$(grep -n "S_down1_down2'\[i,j\] = symbuf_down1_down2" \
  "$WORK/tensor-locals.fmr" | cut -d: -f1)
anti_producer_line=$(grep -n 'antibuf_down1_down2\[i,j\] =' \
  "$WORK/tensor-locals.fmr" | cut -d: -f1)
anti_consumer_line=$(grep -n "W_down1_down2'\[i,j\] = antibuf_down1_down2" \
  "$WORK/tensor-locals.fmr" | cut -d: -f1)
if [ "$producer_line" -ge "$consumer_line" ] \
   || [ "$sym_producer_line" -ge "$sym_consumer_line" ] \
   || [ "$anti_producer_line" -ge "$anti_consumer_line" ]; then
  printf 'typed tensor/form local was not materialized before its consumer\n' >&2
  exit 1
fi

# Symmetric and antisymmetric layouts constrain the complete normalized
# rank-two value, not only the independent storage projection.  Reject a full
# tensor with inconsistent mirrored components at both local materialization
# and user-field update boundaries.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_symmetric_local_mismatch.fme" \
  > "$WORK/symmetric-local-mismatch.egi"
grep -F 'Formurae.requireSymmetricRank2' \
  "$WORK/symmetric-local-mismatch.egi" >/dev/null
if run_machine "$WORK/symmetric-local-mismatch.egi" \
     "$WORK/symmetric-local-mismatch.feir" \
     2> "$WORK/symmetric-local-mismatch.err"; then
  printf 'Egison accepted a nonsymmetric local materialization\n' >&2
  exit 1
fi
grep -F 'Assertion failed: "normalized symmetric tensor layout mismatch"' \
  "$WORK/symmetric-local-mismatch.err" >/dev/null

cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_antisymmetric_update_mismatch.fme" \
  > "$WORK/antisymmetric-update-mismatch.egi"
grep -F 'Formurae.requireAntisymmetricRank2' \
  "$WORK/antisymmetric-update-mismatch.egi" >/dev/null
if run_machine "$WORK/antisymmetric-update-mismatch.egi" \
     "$WORK/antisymmetric-update-mismatch.feir" \
     2> "$WORK/antisymmetric-update-mismatch.err"; then
  printf 'Egison accepted a non-antisymmetric field update\n' >&2
  exit 1
fi
grep -F 'Assertion failed: "normalized antisymmetric tensor layout mismatch"' \
  "$WORK/antisymmetric-update-mismatch.err" >/dev/null

# A named Primal rank-one local is the conservative storage boundary.  Its
# quoted component derivatives materialize once at their natural faces, and
# ordinary divg differentiates those stored samples back to the cell update;
# neither of the old opaque conservation/materialization primitives is used.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_conservative_local.fme" \
  > "$WORK/conservative-local.egi"
grep -F 'def FormuraeInternalValue1_i : Tensor MathValue :=' \
  "$WORK/conservative-local.egi" >/dev/null
grep -F 'FormuraeInternalGridWholeDerivative 1 u' \
  "$WORK/conservative-local.egi" >/dev/null
grep -F 'FormuraeInternalGridWholeDerivative 2 u' \
  "$WORK/conservative-local.egi" >/dev/null
if grep -E 'FormuraeInternalFluxConservativeDivergence|FormuraeInternalMaterialized' \
     "$WORK/conservative-local.egi" >/dev/null; then
  printf 'conservative local emitted an old surface primitive bridge\n' >&2
  exit 1
fi
run_machine "$WORK/conservative-local.egi" "$WORK/conservative-local.feir"
cabal exec -v0 runghc -- -ifec/src tests/pre_conservative_local_feir.hs \
  < "$WORK/conservative-local.feir"
if grep -E 'flux\.conservative-divergence@1|operator\.materialized@1' \
     "$WORK/conservative-local.feir" >/dev/null; then
  printf 'conservative local FEIR retained an old opaque primitive\n' >&2
  exit 1
fi
cabal run -v0 -j1 post-fec -- "$WORK/conservative-local.feir" \
  > "$WORK/conservative-local.fmr"
grep -F 'q_down1[i,j] = (-1) * kappa * (u[i+1,j] + (-1) * u[i,j]) / dx' \
  "$WORK/conservative-local.fmr" >/dev/null
grep -F 'q_down2[i,j] = (-1) * kappa * (u[i,j+1] + (-1) * u[i,j]) / dy' \
  "$WORK/conservative-local.fmr" >/dev/null
grep -F "u'[i,j] = u[i,j] + (-1) * dt * (q_down1[i,j] + (-1) * q_down1[i-1,j]) / dx + (-1) * dt * (q_down2[i,j] + (-1) * q_down2[i,j-1]) / dy" \
  "$WORK/conservative-local.fmr" >/dev/null
qx_line=$(grep -n 'q_down1\[i,j\] =' "$WORK/conservative-local.fmr" \
  | cut -d: -f1)
qy_line=$(grep -n 'q_down2\[i,j\] =' "$WORK/conservative-local.fmr" \
  | cut -d: -f1)
update_line=$(grep -n "u'\[i,j\] =" "$WORK/conservative-local.fmr" \
  | cut -d: -f1)
if [ "$qx_line" -ge "$update_line" ] || [ "$qy_line" -ge "$update_line" ]; then
  printf 'conservative face flux was not materialized before the update\n' >&2
  exit 1
fi
if grep -E 'flux\.conservative|operator\.materialized|opaque-discrete' \
     "$WORK/conservative-local.fmr" >/dev/null; then
  printf 'conservative local FMR retained an old primitive/request marker\n' >&2
  exit 1
fi

# The action stream is intentionally source ordered.  A local cannot read a
# later local, even though all logical field declarations exist in the FEIR
# registry by the time Egison normalizes the model.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_local_forward_reference.fme" \
  > "$WORK/local-forward.egi"
run_machine "$WORK/local-forward.egi" "$WORK/local-forward.feir"
if cabal run -v0 -j1 post-fec -- "$WORK/local-forward.feir" \
     > "$WORK/local-forward.fmr" 2> "$WORK/local-forward.err"; then
  printf 'post-fec accepted a forward reference to a step-local field\n' >&2
  exit 1
fi
grep -F 'is not available here' "$WORK/local-forward.err" >/dev/null

# A local policy annotation is a checked storage contract, not an implicit
# resample request.  A collocated vector cannot be assigned to Primal faces.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_local_placement_mismatch.fme" \
  > "$WORK/local-placement.egi"
run_machine "$WORK/local-placement.egi" "$WORK/local-placement.feir"
if cabal run -v0 -j1 post-fec -- "$WORK/local-placement.feir" \
     > "$WORK/local-placement.fmr" 2> "$WORK/local-placement.err"; then
  printf 'post-fec implicitly resampled a local materialization\n' >&2
  exit 1
fi
grep -F 'grid placement mismatch' "$WORK/local-placement.err" >/dev/null

cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_invalid_predicate.fme" \
  > "$WORK/invalid-predicate.egi"
if run_machine "$WORK/invalid-predicate.egi" "$WORK/invalid-predicate.feir" \
     2> "$WORK/invalid-predicate.err"; then
  printf 'symbolic Select accepted a non-predicate condition\n' >&2
  exit 1
fi
grep -F 'conditional predicate is not a reserved symbolic predicate' \
  "$WORK/invalid-predicate.err" >/dev/null

cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_select_placement_mismatch.fme" \
  > "$WORK/select-placement.egi"
run_machine "$WORK/select-placement.egi" "$WORK/select-placement.feir"
if cabal run -v0 -j1 post-fec -- "$WORK/select-placement.feir" \
     > "$WORK/select-placement.fmr" 2> "$WORK/select-placement.err"; then
  printf 'post-fec accepted Select branches at incompatible placements\n' >&2
  exit 1
fi
grep -F 'grid placement mismatch' "$WORK/select-placement.err" >/dev/null

# Egison's shared whole-tensor wedge/sym calls retain explicit covariant
# metadata.  In particular, sym must not turn ordinary rank-two axes into
# anonymous form axes when its local indices leave scope.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/formurae_runtime_tensor_ops.fme" \
  > "$WORK/runtime-tensor-ops.egi"
grep -F "def FormuraeInternalValue3 := wedge A' T" \
  "$WORK/runtime-tensor-ops.egi" >/dev/null
grep -F 'def FormuraeInternalValue4 := sym C' \
  "$WORK/runtime-tensor-ops.egi" >/dev/null
run_machine "$WORK/runtime-tensor-ops.egi" "$WORK/runtime-tensor-ops.feir"
cabal run -v0 -j1 post-fec -- "$WORK/runtime-tensor-ops.feir" \
  > "$WORK/runtime-tensor-ops.fmr"
grep -F "C_down1_down2'[i,j] = A_down1'[i,j] * B_down2[i,j]" \
  "$WORK/runtime-tensor-ops.fmr" >/dev/null
grep -F "S_down1_down2'[i,j] = (1 / 2) * C_down1_down2[i,j] + (1 / 2) * C_down2_down1[i,j]" \
  "$WORK/runtime-tensor-ops.fmr" >/dev/null

# Keep the standalone positive geometry fixtures in the production pipeline
# suite as well as the larger example-level numerical checks.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/formurae_metric_tensor_ops.fme" \
  > "$WORK/metric-tensor-ops.egi"
grep -E 'def FormuraeInternalValue[0-9]+~i : Tensor MathValue := withSymbols \[j\] \(g~i~j \. A_j\)' \
  "$WORK/metric-tensor-ops.egi" >/dev/null
grep -E 'FormuraeInternalValue[0-9]+~formuraeTensorIndex1' \
  "$WORK/metric-tensor-ops.egi" >/dev/null
run_machine "$WORK/metric-tensor-ops.egi" "$WORK/metric-tensor-ops.feir"
cabal run -v0 -j1 post-fec -- "$WORK/metric-tensor-ops.feir" \
  > "$WORK/metric-tensor-ops.fmr"
grep -F "B_up1'[i,j] = A_down1[i,j]" "$WORK/metric-tensor-ops.fmr" >/dev/null
grep -F "B_up2'[i,j] = (1 / 4) * A_down2[i,j]" \
  "$WORK/metric-tensor-ops.fmr" >/dev/null
grep -F "G_down1_down1'[i,j] = 1" \
  "$WORK/metric-tensor-ops.fmr" >/dev/null
grep -F "G_down2_down2'[i,j] = 4" \
  "$WORK/metric-tensor-ops.fmr" >/dev/null
grep -F "H_up1_up1'[i,j] = 1" \
  "$WORK/metric-tensor-ops.fmr" >/dev/null
grep -F "H_up2_up2'[i,j] = (1 / 4)" \
  "$WORK/metric-tensor-ops.fmr" >/dev/null

cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/formurae_musical_variable_metric.fme" \
  > "$WORK/musical-variable.egi"
run_machine "$WORK/musical-variable.egi" "$WORK/musical-variable.feir"
cabal run -v0 -j1 post-fec -- "$WORK/musical-variable.feir" \
  > "$WORK/musical-variable.fmr"
grep -F "A_down1'[i,j] = X_up1[i,j] + 2 * dx * X_up1[i,j]" \
  "$WORK/musical-variable.fmr" >/dev/null
grep -F "X_up1'[i,j] = A_down1[i,j] / (1 + 2 * dx" \
  "$WORK/musical-variable.fmr" >/dev/null

cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/formurae_hodge_variable_metric.fme" \
  > "$WORK/hodge-variable.egi"
run_machine "$WORK/hodge-variable.egi" "$WORK/hodge-variable.feir"
cabal run -v0 -j1 post-fec -- "$WORK/hodge-variable.feir" \
  > "$WORK/hodge-variable.fmr"
grep -F "H_1'[i,j] = (-1) * dx * i * A_2[i,j] + (-1) * A_2[i,j]" \
  "$WORK/hodge-variable.fmr" >/dev/null
grep -F "H_2'[i,j] = A_1[i,j] / (1 + dx * ((1 / 2) + i))" \
  "$WORK/hodge-variable.fmr" >/dev/null

# A surface `def (.)` shadows the tensor bridge's default contraction.  The
# generated operator alias is valid Egison syntax, and later user definitions
# resolve it directly as an ordinary context-free user function.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_dot_shadow.fme" \
  > "$WORK/dot-shadow.egi"
grep -F 'def (.) := FormuraeInternalDefinition1' \
  "$WORK/dot-shadow.egi" >/dev/null
grep -F 'FormuraeInternalDefinition1 a b' \
  "$WORK/dot-shadow.egi" >/dev/null
run_machine "$WORK/dot-shadow.egi" "$WORK/dot-shadow.feir"
cabal run -v0 -j1 post-fec -- "$WORK/dot-shadow.feir" > "$WORK/dot-shadow.fmr"
grep -F "u'[i] = 2 + u[i]" "$WORK/dot-shadow.fmr" >/dev/null

# An occurrence-level radius is an opaque coordinate derivative.  It bypasses
# the model's compact accuracy-2 profile and keeps its exact radius-2 contract.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_wide.fme" \
  > "$WORK/wide.egi"
grep -F 'FormuraeInternalCoordinateWideDerivative 1 2 2 u' \
  "$WORK/wide.egi" >/dev/null
run_machine "$WORK/wide.egi" "$WORK/wide.feir"
grep -F '(op-id "derivative.coordinate-wide@1")' "$WORK/wide.feir" >/dev/null
grep -F '(id "radius") (value (natural 2))' "$WORK/wide.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/wide.feir" > "$WORK/wide.fmr"
grep -F 'u[i-2]' "$WORK/wide.fmr" >/dev/null
grep -F 'u[i+2]' "$WORK/wide.fmr" >/dev/null
grep -F '(-1 / 12)' "$WORK/wide.fmr" >/dev/null

# A grid derivative is intentionally different from analytic differentiation:
# Egison must preserve the complete nonlinear flux as one opaque operand.
cabal run -v0 -j1 pre-fec -- "$ROOT/examples/ks3d/ks3d.fme" \
  > "$WORK/grid-whole.egi"
grep -F 'FormuraeInternalGridWholeDerivative 1 ((u * u) / 2)' \
  "$WORK/grid-whole.egi" >/dev/null
run_machine "$WORK/grid-whole.egi" "$WORK/grid-whole.feir"
cabal exec -- runghc -ifec/src tests/pre_grid_whole_feir.hs \
  < "$WORK/grid-whole.feir"

# A short user-defined tensor operator receives whole tensors directly and
# returns an anonymous covariant axis.  The mixed expression explicitly
# applies the equation target's lower index at each call site; pre-fec does
# not infer result variance from the operator name or body.
cabal run -v0 -j1 pre-fec -- "$ROOT/examples/maxwell3d/maxwell3d.fme" \
  > "$WORK/maxwell.egi"
grep -F 'epsilon_i~j~k . contractWith (+) (FormuraeInternalDiff X_k)..._j' \
  "$WORK/maxwell.egi" >/dev/null
grep -F '(curl B)..._i' "$WORK/maxwell.egi" >/dev/null
grep -F "(curl E')..._i" "$WORK/maxwell.egi" >/dev/null
if grep -F 'Formurae.attachExplicitVariances' "$WORK/maxwell.egi" >/dev/null; then
  printf 'user curl result was unexpectedly assigned explicit variance\n' >&2
  exit 1
fi
run_machine "$WORK/maxwell.egi" "$WORK/maxwell.feir"
grep -F '(shape (3))' "$WORK/maxwell.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/maxwell.feir" > "$WORK/maxwell.fmr"
grep -F "E_down1'[i,j,k] = E_down1[i,j,k]" "$WORK/maxwell.fmr" >/dev/null

cabal run -v0 -j1 pre-fec -- "$ROOT/examples/maxwell3d_yee/maxwell3d_yee.fme" \
  > "$WORK/maxwell-yee.egi"
run_machine "$WORK/maxwell-yee.egi" "$WORK/maxwell-yee.feir"
cabal run -v0 -j1 post-fec -- "$WORK/maxwell-yee.feir" > "$WORK/maxwell-yee.fmr"
grep -F '(B_down2[i,j,k] + (-1) * B_down2[i,j,k-1]) / dz' \
  "$WORK/maxwell-yee.fmr" >/dev/null

cabal run -v0 -j1 pre-fec -- "$ROOT/examples/diffusion3d/diffusion3d.fme" \
  > "$WORK/indexed-derivative.egi"
grep -F 'def FormuraeInternalScalarDelta u := Formurae.scalarLaplacian' \
  "$WORK/indexed-derivative.egi" >/dev/null
grep -F 'FormuraeInternalScalarDelta u' \
  "$WORK/indexed-derivative.egi" >/dev/null
run_machine "$WORK/indexed-derivative.egi" "$WORK/indexed-derivative.feir"
cabal run -v0 -j1 post-fec -- "$WORK/indexed-derivative.feir" \
  > "$WORK/indexed-derivative.fmr"
grep -F '/ dx**2' "$WORK/indexed-derivative.fmr" >/dev/null
grep -F '/ dy**2' "$WORK/indexed-derivative.fmr" >/dev/null
grep -F '/ dz**2' "$WORK/indexed-derivative.fmr" >/dev/null

cabal run -v0 -j1 pre-fec -- "$ROOT/examples/elastic3d/elastic3d.fme" \
  > "$WORK/elastic.egi"
grep -F '(FormuraeInternalDiff sigma~i~j)..._j' \
  "$WORK/elastic.egi" >/dev/null
run_machine "$WORK/elastic.egi" "$WORK/elastic.feir"
cabal run -v0 -j1 post-fec -- "$WORK/elastic.feir" > "$WORK/elastic.fmr"
grep -F "sigma_up1_up2'[i,j,k] = sigma_up1_up2[i,j,k]" "$WORK/elastic.fmr" >/dev/null

# Formal accuracy belongs to the model profile, not the canonical mathematical
# surface.  Egison expands scalar Delta to pure Cartesian algebra, normalizes
# it to second jets, and post-fec selects the compact five-point derivative.
cabal run -v0 -j1 pre-fec -- "$ROOT/examples/highorder4/highorder4.fme" \
  > "$WORK/highorder.egi"
grep -F 'def FormuraeInternalScalarDelta u := Formurae.scalarLaplacian' \
  "$WORK/highorder.egi" >/dev/null
grep -F 'FormuraeInternalScalarDelta u' \
  "$WORK/highorder.egi" >/dev/null
run_machine "$WORK/highorder.egi" "$WORK/highorder.feir"
grep -F '(order 2)' "$WORK/highorder.feir" >/dev/null
grep -F '(accuracy 4)' "$WORK/highorder.feir" >/dev/null
grep -F '(count 2)' "$WORK/highorder.feir" >/dev/null
if grep -E '\(analytic-call|\(count 1\)|grad|divg' "$WORK/highorder.feir" >/dev/null; then
  printf 'high-order FEIR retained an operator/analytic call or first derivative\n' >&2
  exit 1
fi
cabal run -v0 -j1 post-fec -- "$WORK/highorder.feir" > "$WORK/highorder.fmr"
grep -F 'u[i-2,j,k]' "$WORK/highorder.fmr" >/dev/null
grep -F 'u[i+2,j,k]' "$WORK/highorder.fmr" >/dev/null
if grep -E 'i[-+]4|j[-+]4|k[-+]4' "$WORK/highorder.fmr" >/dev/null; then
  printf 'high-order compact stencil unexpectedly contains a radius-4 offset\n' >&2
  exit 1
fi

# Orthogonal Hodge remains pure Egison algebra.  The same unquoted scale
# symbols feed GeometryNF and the ambient operator definitions, while variable codiff stays one
# versioned request and materializes coefficient/flux/result effects in order.
cabal run -v0 -j1 pre-fec -- "$ROOT/tests/fixtures/pre_fec_metric_forms.fme" \
  > "$WORK/metric-forms.egi"
grep -F 'FEIR.unquoteAll (feGeometryScale 1)' "$WORK/metric-forms.egi" >/dev/null
grep -F 'FormuraeInternalHodge A' "$WORK/metric-forms.egi" >/dev/null
# Canonical δ on declared geometry expands through the prelude macro: the
# weighted flux is a lifted deferred local and the adjoint divergence
# closes the form, with no scheduled codiff.metric request left behind.
grep -F 'FormuraeInternalDFluxWeights A' "$WORK/metric-forms.egi" >/dev/null
grep -F 'FormuraeInternalDFluxDiv codiffFlux' "$WORK/metric-forms.egi" >/dev/null
if grep -F 'expandAll' "$WORK/metric-forms.egi" >/dev/null; then
  printf 'metric form normalization contains forbidden expandAll\n' >&2
  exit 1
fi
run_machine "$WORK/metric-forms.egi" "$WORK/metric-forms.feir"
if grep -F '(op-id "codiff.metric@1")' "$WORK/metric-forms.feir" >/dev/null; then
  printf 'metric form FEIR still schedules the retired codiff.metric request\n' >&2
  exit 1
fi
if grep -F '(quote ' "$WORK/metric-forms.feir" >/dev/null; then
  printf 'metric form FEIR retained a quote node\n' >&2
  exit 1
fi
cabal run -v0 -j1 post-fec -- "$WORK/metric-forms.feir" > "$WORK/metric-forms.fmr"
grep -F "H_1'[i,j] = (-1) * dx * i * A_2[i,j] + (-1) * A_2[i,j]" \
  "$WORK/metric-forms.fmr" >/dev/null
grep -F "H_2'[i,j] = A_1[i,j] / (1 + dx * ((1 / 2) + i))" \
  "$WORK/metric-forms.fmr" >/dev/null
coeff_line=$(grep -n 'codiffCoeff_1\[i,j\] =' \
  "$WORK/metric-forms.fmr" | cut -d: -f1)
flux_line=$(grep -n 'codiffFlux_1\[i,j\] = ' \
  "$WORK/metric-forms.fmr" | cut -d: -f1)
consumer_line=$(grep -n "D'\[i,j\] = " "$WORK/metric-forms.fmr" | cut -d: -f1)
if [ "$coeff_line" -ge "$flux_line" ] || [ "$flux_line" -ge "$consumer_line" ]; then
  printf 'macro codifferential schedule is not topological\n' >&2
  exit 1
fi
if grep -E 'codiff\.metric|opaque-discrete' "$WORK/metric-forms.fmr" >/dev/null; then
  printf 'metric form FMR retained an opaque marker\n' >&2
  exit 1
fi

# The ambient volume/metric bindings are user-facing: under a quoted
# embedding they must be unquoted before user step expressions reach the
# FEIR scalar encoder.  The hand-written conservative torus Laplacian reads
# `volume` at both the flux faces and the cell update.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_embedded_volume.fme" \
  > "$WORK/embedded-volume.egi"
grep -F 'def volume := FEIR.unquoteAll feGeometryVolume' \
  "$WORK/embedded-volume.egi" >/dev/null
run_machine "$WORK/embedded-volume.egi" "$WORK/embedded-volume.feir"
if grep -F '(quote ' "$WORK/embedded-volume.feir" >/dev/null; then
  printf 'embedded volume FEIR retained a quote node\n' >&2
  exit 1
fi
cabal run -v0 -j1 post-fec -- "$WORK/embedded-volume.feir" \
  > "$WORK/embedded-volume.fmr"
grep -F 'q_down1[i,j,k] = 2 * (u[i+1,j,k] + (-1) * u[i,j,k]) / dtheta + (u[i+1,j,k] + (-1) * u[i,j,k]) / dtheta * cos(dtheta * ((1 / 2) + i))' \
  "$WORK/embedded-volume.fmr" >/dev/null
grep -F 'q_down2[i,j,k] = (u[i,j+1,k] + (-1) * u[i,j,k]) / dphi / (2 + cos(dtheta * i))' \
  "$WORK/embedded-volume.fmr" >/dev/null
grep -F "u'[i,j,k] = (2 * u[i,j,k] + dt * (q_down1[i,j,k] + (-1) * q_down1[i-1,j,k]) / dtheta + dt * (q_down2[i,j,k] + (-1) * q_down2[i,j-1,k]) / dphi + dt * (q_down3[i,j,k] + (-1) * q_down3[i,j,k-1]) / dz + u[i,j,k] * cos(dtheta * i)) / (2 + cos(dtheta * i))" \
  "$WORK/embedded-volume.fmr" >/dev/null
compile_generated embedded-volume metric_torus "$WORK/embedded-volume.fmr"

cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_embedded_ambient_metric.fme" \
  > "$WORK/embedded-ambient-metric.egi"
grep -F 'def metric_i_j := FEIR.unquoteAll feGeometryMetric_i_j' \
  "$WORK/embedded-ambient-metric.egi" >/dev/null
grep -F 'def inverseMetric~i~j := FEIR.unquoteAll feGeometryInverseMetric~i~j' \
  "$WORK/embedded-ambient-metric.egi" >/dev/null
run_machine "$WORK/embedded-ambient-metric.egi" \
  "$WORK/embedded-ambient-metric.feir"
if grep -F '(quote ' "$WORK/embedded-ambient-metric.feir" >/dev/null; then
  printf 'embedded ambient metric FEIR retained a quote node\n' >&2
  exit 1
fi
cabal run -v0 -j1 post-fec -- "$WORK/embedded-ambient-metric.feir" \
  > "$WORK/embedded-ambient-metric.fmr"
grep -F "B_up2'[i,j,k] = A_down2[i,j,k] / (4 + 4 * cos(dtheta * i) + cos(dtheta * i)**2)" \
  "$WORK/embedded-ambient-metric.fmr" >/dev/null
grep -F "A_down2'[i,j,k] = 4 * B_up2[i,j,k] + 4 * B_up2[i,j,k] * cos(dtheta * i) + B_up2[i,j,k] * cos(dtheta * i)**2" \
  "$WORK/embedded-ambient-metric.fmr" >/dev/null

# The cutover surface keeps an ordered nested quoted derivative, explicit
# resampling, and typed local storage.  The removed conservative-divergence
# and expression-materialization bridges are not involved.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_remaining_primitives.fme" \
  > "$WORK/surface-cutover.egi"
grep -F 'FormuraeInternalOrderedDerivative [| 1, 2 |] u' \
  "$WORK/surface-cutover.egi" >/dev/null
grep -F 'FormuraeInternalResampleExplicit [| 1, 1 |] u' \
  "$WORK/surface-cutover.egi" >/dev/null
grep -F 'def FormuraeInternalValue1_i : Tensor MathValue := F_i + G_i' \
  "$WORK/surface-cutover.egi" >/dev/null
if grep -E 'FormuraeInternalFluxConservativeDivergence|FormuraeInternalMaterialized' \
     "$WORK/surface-cutover.egi" >/dev/null; then
  printf 'cutover surface emitted a removed primitive bridge\n' >&2
  exit 1
fi
run_machine "$WORK/surface-cutover.egi" "$WORK/surface-cutover.feir"
for operation in \
  derivative.ordered@1 \
  resample.explicit@1; do
  grep -F "(op-id \"$operation\")" "$WORK/surface-cutover.feir" >/dev/null
done
if grep -E 'flux\.conservative-divergence@1|operator\.materialized@1' \
     "$WORK/surface-cutover.feir" >/dev/null; then
  printf 'cutover surface FEIR retained a removed opaque primitive\n' >&2
  exit 1
fi
cabal run -v0 -j1 post-fec -- "$WORK/surface-cutover.feir" \
  > "$WORK/surface-cutover.fmr"
grep -F "u'[i,j] = ((-1 / 4) * u[i-1,j+1] + (-1 / 4) * u[i+1,j-1] + (1 / 4) * u[i-1,j-1] + (1 / 4) * u[i+1,j+1]) / (dx * dy)" \
  "$WORK/surface-cutover.fmr" >/dev/null
grep -F "v'[i,j] = (1 / 4) * u[i,j]" \
  "$WORK/surface-cutover.fmr" >/dev/null
grep -F 'H_down1[i,j] = F_down1[i,j] + G_down1[i,j]' \
  "$WORK/surface-cutover.fmr" >/dev/null
grep -F "F_down1'[i,j] = H_down1[i,j]" \
  "$WORK/surface-cutover.fmr" >/dev/null
local_line=$(grep -n 'H_down1\[i,j\] =' "$WORK/surface-cutover.fmr" \
  | cut -d: -f1)
consumer_line=$(grep -n "F_down1'\[i,j\] = H_down1" \
  "$WORK/surface-cutover.fmr" | cut -d: -f1)
if [ "$local_line" -ge "$consumer_line" ]; then
  printf 'typed local was not stored before its consumer\n' >&2
  exit 1
fi
if grep -E 'opaque-discrete|derivative\.ordered|resample\.explicit|flux\.conservative|operator\.materialized' \
     "$WORK/surface-cutover.fmr" >/dev/null; then
  printf 'cutover surface FMR retained an FEIR marker\n' >&2
  exit 1
fi

# On declared geometry, canonical Delta and the spelled-out 0 - delta(d u)
# both expand through the prelude macros.  They are no longer one shared
# opaque request: Delta uses the all-discrete exterior derivative while
# delta(d u) discretizes the analytic gradient through the profile, and
# each call lifts its own hygienically named coefficient and flux locals.
cabal run -v0 -j1 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_variable_scalar_delta_equivalence.fme" \
  > "$WORK/scalar-delta-equivalence.egi"
if grep -F 'FormuraeInternalScalarDelta' \
     "$WORK/scalar-delta-equivalence.egi" >/dev/null; then
  printf 'declared-geometry Delta still used the retired scalar bridge\n' >&2
  exit 1
fi
run_machine "$WORK/scalar-delta-equivalence.egi" \
  "$WORK/scalar-delta-equivalence.feir"
if grep -F '(op-id "lb.orthogonal@1")' \
     "$WORK/scalar-delta-equivalence.feir" >/dev/null; then
  printf 'declared-geometry Delta still scheduled lb.orthogonal\n' >&2
  exit 1
fi
grep -F '(accuracy 4)' "$WORK/scalar-delta-equivalence.feir" >/dev/null
cabal run -v0 -j1 post-fec -- "$WORK/scalar-delta-equivalence.feir" \
  > "$WORK/scalar-delta-equivalence.fmr"
for lifted in deltaCoeff_1 deltaFlux_1 codiffCoeff_1 codiffFlux_1; do
  count=$(grep -c "^  $lifted\[i\] =" "$WORK/scalar-delta-equivalence.fmr")
  if [ "$count" -ne 1 ]; then
    printf 'expected one %s local in the macro expansion, got %s\n' \
      "$lifted" "$count" >&2
    exit 1
  fi
done
grep -F "direct'[i] = " "$WORK/scalar-delta-equivalence.fmr" >/dev/null
grep -F "exact'[i] = " "$WORK/scalar-delta-equivalence.fmr" >/dev/null
if grep -E 'u\[i[-+]2\]' "$WORK/scalar-delta-equivalence.fmr" >/dev/null; then
  printf 'variable-metric scalar Laplacian inherited a wide profile stencil\n' >&2
  exit 1
fi

cabal run -v0 -j1 pre-fec -- "$ROOT/examples/maxwell_dec/maxwell_dec.fme" \
  > "$WORK/maxwell-dec.egi"
grep -F 'FormuraeInternalCodiff B' "$WORK/maxwell-dec.egi" >/dev/null
grep -F 'FormuraeInternalD E' "$WORK/maxwell-dec.egi" >/dev/null
run_machine "$WORK/maxwell-dec.egi" "$WORK/maxwell-dec.feir"
cabal run -v0 -j1 post-fec -- "$WORK/maxwell-dec.feir" > "$WORK/maxwell-dec.fmr"
grep -F "B_1_2'[i,j,k] = B_1_2[i,j,k]" "$WORK/maxwell-dec.fmr" >/dev/null
compile_and_check maxwell_dec dec_check.c "$WORK/maxwell-dec.fmr"

while read -r geometry check_source; do
  cabal run -v0 -j1 pre-fec -- "$ROOT/examples/$geometry/$geometry.fme" \
    > "$WORK/$geometry.egi"
  # Canonical Delta expands through the prelude macros: the flux weights
  # and adjoint divergence replace the retired lb.orthogonal request.
  grep -F 'def FormuraeInternalDFluxWeights A := Formurae.dFluxWeightsWith' \
    "$WORK/$geometry.egi" >/dev/null
  grep -F 'def FormuraeInternalDFluxDiv w := Formurae.dFluxDivWith' \
    "$WORK/$geometry.egi" >/dev/null
  if grep -F 'Formurae.lbOrthogonal' "$WORK/$geometry.egi" >/dev/null; then
    printf 'geometry unit still uses the retired lb bridge: %s\n' \
      "$geometry" >&2
    exit 1
  fi
  grep -F 'embedding/metric must be symbolically orthogonal' \
    "$WORK/$geometry.egi" >/dev/null
  if grep -F 'expandAll' "$WORK/$geometry.egi" >/dev/null; then
    printf 'geometry normalization unit contains forbidden expandAll: %s\n' \
      "$geometry" >&2
    exit 1
  fi
  run_machine "$WORK/$geometry.egi" "$WORK/$geometry.feir"
  grep -F '(orthogonality-verified true)' "$WORK/$geometry.feir" >/dev/null
  if grep -F '(op-id "lb.orthogonal@1")' "$WORK/$geometry.feir" >/dev/null; then
    printf 'geometry FEIR still schedules lb.orthogonal: %s\n' "$geometry" >&2
    exit 1
  fi
  cabal run -v0 -j1 post-fec -- "$WORK/$geometry.feir" > "$WORK/$geometry.fmr"
  if grep -E 'field-jet|opaque|lb\.orthogonal' "$WORK/$geometry.fmr" >/dev/null; then
    printf 'geometry FMR retained an FEIR/request marker: %s\n' "$geometry" >&2
    exit 1
  fi
  compile_and_check "$geometry" "$check_source" "$WORK/$geometry.fmr"
done <<'EOF'
hyperbolic hyp_check.c
metric_torus metric_check.c
metric_sphere sphere_check.c
polar2d polar_check.c
spherical3d spherical_check.c
EOF

printf 'pre-fec algebraic and derivative pipeline tests: ok\n'
