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
cabal run -v0 pre-fec -- "$FIXTURE" > "$WORK/model.egi"

for forbidden in 'def dC ' 'def dC2 ' dYee FMR. fieldEqs; do
  if grep -F "$forbidden" "$WORK/model.egi" >/dev/null; then
    printf 'generated normalization unit contains forbidden backend text: %s\n' "$forbidden" >&2
    exit 1
  fi
done

run_machine "$WORK/model.egi" "$WORK/model.feir"

cabal run -v0 post-fec -- "$WORK/model.feir" > "$WORK/model.fmr"
grep -F 'u[i,j] = 1 + alpha * dr * i' "$WORK/model.fmr" >/dev/null
grep -F 'flux[i,j] = alpha * u[i,j] + u[i,j]**2' "$WORK/model.fmr" >/dev/null
grep -F 'extern function :: exp' "$WORK/model.fmr" >/dev/null
grep -F 'gauss = fun(r) exp(0.0 - r*r)' "$WORK/model.fmr" >/dev/null

sed 's/(registry-id "sha256:[0-9a-f]*/(registry-id "sha256:tampered/' \
  "$WORK/model.feir" > "$WORK/tampered.feir"
if cabal run -v0 post-fec -- "$WORK/tampered.feir" \
     > "$WORK/tampered.fmr" 2> "$WORK/tampered.err"; then
  printf 'post-fec accepted a tampered logical registry fingerprint\n' >&2
  exit 1
fi
grep -F 'registry ID mismatch' "$WORK/tampered.err" >/dev/null

# The public Laplacian remains the short divg(grad) composition.  Egison
# normalizes it to one second-order FieldJet rather than nested stencils.
cabal run -v0 pre-fec -- "$ROOT/examples/diffusion1d/diffusion1d.fme" \
  > "$WORK/derivative.egi"
grep -F 'Formurae.divg FormuraeInternalContext (Formurae.grad FormuraeInternalContext u)' \
  "$WORK/derivative.egi" >/dev/null
run_machine "$WORK/derivative.egi" "$WORK/derivative.feir"
grep -F '(axis-order (axis 1) (count 2))' "$WORK/derivative.feir" >/dev/null
cabal run -v0 post-fec -- "$WORK/derivative.feir" > "$WORK/derivative.fmr"
grep -F 'u[i-1] + u[i+1] + (-2) * u[i]' "$WORK/derivative.fmr" >/dev/null

# Higher-order passage preserves the hidden OperatorContext and the tensor
# metadata of standard operators.  `apply grad u` must therefore reach a
# whole covector target, not an anonymous one-form axis.
cabal run -v0 pre-fec -- "$ROOT/tests/formurae_standard_ops.fme" \
  > "$WORK/standard-ops.egi"
grep -F 'apply (Formurae.grad feOperatorContext) u' \
  "$WORK/standard-ops.egi" >/dev/null
run_machine "$WORK/standard-ops.egi" "$WORK/standard-ops.feir"
grep -F '(shape (2)) (variances (down)) (df-order 0)' \
  "$WORK/standard-ops.feir" >/dev/null
cabal run -v0 post-fec -- "$WORK/standard-ops.feir" \
  > "$WORK/standard-ops.fmr"
grep -F "q_down1'[i,j] = ((-1 / 2) * u[i-1,j] + (1 / 2) * u[i+1,j]) / dx" \
  "$WORK/standard-ops.fmr" >/dev/null
grep -F "q_down2'[i,j] = ((-1 / 2) * u[i,j-1] + (1 / 2) * u[i,j+1]) / dy" \
  "$WORK/standard-ops.fmr" >/dev/null

# The same metadata normalization is structural for rank-two derivatives and
# the metric musical maps; it is not keyed by an operator name in pre/post-fec.
cabal run -v0 pre-fec -- "$ROOT/tests/formurae_native_rank2_ops.fme" \
  > "$WORK/rank2-ops.egi"
run_machine "$WORK/rank2-ops.egi" "$WORK/rank2-ops.feir"
grep -F '(shape (2 2)) (variances (down down)) (df-order 0)' \
  "$WORK/rank2-ops.feir" >/dev/null
cabal run -v0 post-fec -- "$WORK/rank2-ops.feir" \
  > "$WORK/rank2-ops.fmr"
grep -F "H_down1_down2'[i,j] =" "$WORK/rank2-ops.fmr" >/dev/null
grep -F "G_down2_down1'[i,j] =" "$WORK/rank2-ops.fmr" >/dev/null

cabal run -v0 pre-fec -- "$ROOT/tests/formurae_musical_ops.fme" \
  > "$WORK/musical-ops.egi"
run_machine "$WORK/musical-ops.egi" "$WORK/musical-ops.feir"
cabal run -v0 post-fec -- "$WORK/musical-ops.feir" \
  > "$WORK/musical-ops.fmr"
grep -F "A_down1'[i,j] = 4 * X_up1[i,j]" "$WORK/musical-ops.fmr" >/dev/null
grep -F "X_up1'[i,j] = (1 / 4) * A_down1[i,j]" "$WORK/musical-ops.fmr" >/dev/null

# Symbolic predicates remain data through Egison normalization.  The encoder
# canonicalizes boolean collections and emits one Select per tensor component;
# post-fec alone resolves sampling placement.
cabal run -v0 pre-fec -- "$ROOT/tests/fixtures/pre_fec_conditional.fme" \
  > "$WORK/conditional.egi"
grep -F 'Formurae.select (Formurae.predicateOr' "$WORK/conditional.egi" >/dev/null
run_machine "$WORK/conditional.egi" "$WORK/conditional.feir"
grep -F '(select (or (compare ge ' "$WORK/conditional.feir" >/dev/null
grep -F '(select (and (compare ge ' "$WORK/conditional.feir" >/dev/null
cabal run -v0 post-fec -- "$WORK/conditional.feir" \
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
cabal run -v0 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_coordinate_targets.fme" \
  > "$WORK/coordinate-targets.egi"
run_machine "$WORK/coordinate-targets.egi" "$WORK/coordinate-targets.feir"
cabal run -v0 post-fec -- "$WORK/coordinate-targets.feir" \
  > "$WORK/coordinate-targets.fmr"
grep -F 'position[i] = dx * i' "$WORK/coordinate-targets.fmr" >/dev/null
grep -F "u'[i] = position[i] + u[i]" "$WORK/coordinate-targets.fmr" >/dev/null
compile_generated coordinate-targets diffusion1d "$WORK/coordinate-targets.fmr"

cabal run -v0 pre-fec -- "$ROOT/tests/fixtures/pre_fec_invalid_predicate.fme" \
  > "$WORK/invalid-predicate.egi"
if run_machine "$WORK/invalid-predicate.egi" "$WORK/invalid-predicate.feir" \
     2> "$WORK/invalid-predicate.err"; then
  printf 'symbolic Select accepted a non-predicate condition\n' >&2
  exit 1
fi
grep -F 'conditional predicate is not a reserved symbolic predicate' \
  "$WORK/invalid-predicate.err" >/dev/null

cabal run -v0 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_select_placement_mismatch.fme" \
  > "$WORK/select-placement.egi"
run_machine "$WORK/select-placement.egi" "$WORK/select-placement.feir"
if cabal run -v0 post-fec -- "$WORK/select-placement.feir" \
     > "$WORK/select-placement.fmr" 2> "$WORK/select-placement.err"; then
  printf 'post-fec accepted Select branches at incompatible placements\n' >&2
  exit 1
fi
grep -F 'grid placement mismatch' "$WORK/select-placement.err" >/dev/null

# Whole-tensor wedge/sym calls retain explicit covariant metadata.  In
# particular, sym must not turn ordinary rank-two axes into anonymous form
# axes when its local Egison indices leave scope.
cabal run -v0 pre-fec -- "$ROOT/tests/formurae_runtime_tensor_ops.fme" \
  > "$WORK/runtime-tensor-ops.egi"
grep -F "def FormuraeInternalValue3 := wedge A' T" \
  "$WORK/runtime-tensor-ops.egi" >/dev/null
grep -F 'def FormuraeInternalValue4 := sym C' \
  "$WORK/runtime-tensor-ops.egi" >/dev/null
run_machine "$WORK/runtime-tensor-ops.egi" "$WORK/runtime-tensor-ops.feir"
cabal run -v0 post-fec -- "$WORK/runtime-tensor-ops.feir" \
  > "$WORK/runtime-tensor-ops.fmr"
grep -F "C_down1_down2'[i,j] = A_down1'[i,j] * B_down2[i,j]" \
  "$WORK/runtime-tensor-ops.fmr" >/dev/null
grep -F "S_down1_down2'[i,j] = (1 / 2) * C_down1_down2[i,j] + (1 / 2) * C_down2_down1[i,j]" \
  "$WORK/runtime-tensor-ops.fmr" >/dev/null

# Keep the standalone positive geometry fixtures in the production pipeline
# suite as well as the larger example-level numerical checks.
cabal run -v0 pre-fec -- "$ROOT/tests/formurae_metric_tensor_ops.fme" \
  > "$WORK/metric-tensor-ops.egi"
run_machine "$WORK/metric-tensor-ops.egi" "$WORK/metric-tensor-ops.feir"
cabal run -v0 post-fec -- "$WORK/metric-tensor-ops.feir" \
  > "$WORK/metric-tensor-ops.fmr"
grep -F "B_up1'[i,j] = A_down1[i,j]" "$WORK/metric-tensor-ops.fmr" >/dev/null
grep -F "B_up2'[i,j] = A_down2[i,j]" "$WORK/metric-tensor-ops.fmr" >/dev/null

cabal run -v0 pre-fec -- \
  "$ROOT/tests/formurae_musical_variable_metric.fme" \
  > "$WORK/musical-variable.egi"
run_machine "$WORK/musical-variable.egi" "$WORK/musical-variable.feir"
cabal run -v0 post-fec -- "$WORK/musical-variable.feir" \
  > "$WORK/musical-variable.fmr"
grep -F "A_down1'[i,j] = X_up1[i,j] + 2 * dx * X_up1[i,j]" \
  "$WORK/musical-variable.fmr" >/dev/null
grep -F "X_up1'[i,j] = A_down1[i,j] / (1 + 2 * dx" \
  "$WORK/musical-variable.fmr" >/dev/null

cabal run -v0 pre-fec -- \
  "$ROOT/tests/formurae_hodge_variable_metric.fme" \
  > "$WORK/hodge-variable.egi"
run_machine "$WORK/hodge-variable.egi" "$WORK/hodge-variable.feir"
cabal run -v0 post-fec -- "$WORK/hodge-variable.feir" \
  > "$WORK/hodge-variable.fmr"
grep -F "H_1'[i,j] = (-1) * dx * i * A_2[i,j] + (-1) * A_2[i,j]" \
  "$WORK/hodge-variable.fmr" >/dev/null
grep -F "H_2'[i,j] = A_1[i,j] / (1 + dx * ((1 / 2) + i))" \
  "$WORK/hodge-variable.fmr" >/dev/null

# A surface `def (.)` shadows the tensor bridge's default contraction.  The
# generated operator alias is valid Egison syntax, and later user definitions
# resolve it through the same hidden operator context as named functions.
cabal run -v0 pre-fec -- "$ROOT/tests/fixtures/pre_fec_dot_shadow.fme" \
  > "$WORK/dot-shadow.egi"
grep -F 'def (.) := FormuraeInternalDefinition1 feOperatorContext' \
  "$WORK/dot-shadow.egi" >/dev/null
grep -F 'FormuraeInternalDefinition1 FormuraeInternalContext a b' \
  "$WORK/dot-shadow.egi" >/dev/null
run_machine "$WORK/dot-shadow.egi" "$WORK/dot-shadow.feir"
cabal run -v0 post-fec -- "$WORK/dot-shadow.feir" > "$WORK/dot-shadow.fmr"
grep -F "u'[i] = 2 + u[i]" "$WORK/dot-shadow.fmr" >/dev/null

# An occurrence-level radius is an opaque coordinate derivative.  It bypasses
# the model's compact accuracy-2 profile and keeps its exact radius-2 contract.
cabal run -v0 pre-fec -- "$ROOT/tests/fixtures/pre_fec_wide.fme" \
  > "$WORK/wide.egi"
grep -F 'Formurae.coordinateWideDerivative feOperatorContext 1 2 2 u' \
  "$WORK/wide.egi" >/dev/null
run_machine "$WORK/wide.egi" "$WORK/wide.feir"
grep -F '(op-id "derivative.coordinate-wide@1")' "$WORK/wide.feir" >/dev/null
grep -F '(id "radius") (value (natural 2))' "$WORK/wide.feir" >/dev/null
cabal run -v0 post-fec -- "$WORK/wide.feir" > "$WORK/wide.fmr"
grep -F 'u[i-2]' "$WORK/wide.fmr" >/dev/null
grep -F 'u[i+2]' "$WORK/wide.fmr" >/dev/null
grep -F '(-1 / 12)' "$WORK/wide.fmr" >/dev/null

# A grid derivative is intentionally different from analytic differentiation:
# Egison must preserve the complete nonlinear flux as one opaque operand.
cabal run -v0 pre-fec -- "$ROOT/examples/ks3d/ks3d.fme" \
  > "$WORK/grid-whole.egi"
grep -F 'Formurae.gridWholeDerivative feOperatorContext 1 ((u * u) / 2)' \
  "$WORK/grid-whole.egi" >/dev/null
run_machine "$WORK/grid-whole.egi" "$WORK/grid-whole.feir"
cabal exec -- runghc -ifec/src tests/pre_grid_whole_feir.hs \
  < "$WORK/grid-whole.feir"

# Standard tensor operators receive whole tensors directly.  pre-fec does
# not infer a component-to-whole conversion from an operator name.
cabal run -v0 pre-fec -- "$ROOT/examples/maxwell3d/maxwell3d.fme" \
  > "$WORK/maxwell.egi"
grep -F 'E + (dt * Formurae.curl feOperatorContext B)' "$WORK/maxwell.egi" >/dev/null
grep -F "B - (dt * Formurae.curl feOperatorContext E')" "$WORK/maxwell.egi" >/dev/null
run_machine "$WORK/maxwell.egi" "$WORK/maxwell.feir"
grep -F '(shape (3))' "$WORK/maxwell.feir" >/dev/null
cabal run -v0 post-fec -- "$WORK/maxwell.feir" > "$WORK/maxwell.fmr"
grep -F "E_down1'[i,j,k] = E_down1[i,j,k]" "$WORK/maxwell.fmr" >/dev/null

cabal run -v0 pre-fec -- "$ROOT/examples/maxwell3d_yee/maxwell3d_yee.fme" \
  > "$WORK/maxwell-yee.egi"
run_machine "$WORK/maxwell-yee.egi" "$WORK/maxwell-yee.feir"
cabal run -v0 post-fec -- "$WORK/maxwell-yee.feir" > "$WORK/maxwell-yee.fmr"
grep -F '(B_down2[i,j,k] + (-1) * B_down2[i,j,k-1]) / dz' \
  "$WORK/maxwell-yee.fmr" >/dev/null

cabal run -v0 pre-fec -- "$ROOT/examples/diffusion3d/diffusion3d.fme" \
  > "$WORK/indexed-derivative.egi"
grep -F 'Formurae.divg FormuraeInternalContext (Formurae.grad FormuraeInternalContext u)' \
  "$WORK/indexed-derivative.egi" >/dev/null
run_machine "$WORK/indexed-derivative.egi" "$WORK/indexed-derivative.feir"
cabal run -v0 post-fec -- "$WORK/indexed-derivative.feir" \
  > "$WORK/indexed-derivative.fmr"
grep -F '/ dx**2' "$WORK/indexed-derivative.fmr" >/dev/null
grep -F '/ dy**2' "$WORK/indexed-derivative.fmr" >/dev/null
grep -F '/ dz**2' "$WORK/indexed-derivative.fmr" >/dev/null

cabal run -v0 pre-fec -- "$ROOT/examples/elastic3d/elastic3d.fme" \
  > "$WORK/elastic.egi"
grep -F '(Formurae.diff feOperatorContext sigma~i~j)..._j' \
  "$WORK/elastic.egi" >/dev/null
run_machine "$WORK/elastic.egi" "$WORK/elastic.feir"
cabal run -v0 post-fec -- "$WORK/elastic.feir" > "$WORK/elastic.fmr"
grep -F "sigma_up1_up2'[i,j,k] = sigma_up1_up2[i,j,k]" "$WORK/elastic.fmr" >/dev/null

# Formal accuracy belongs to the model profile, not the short mathematical
# definition.  Egison sees only divg(grad u), normalizes it to second jets,
# and post-fec selects the compact five-point second derivative directly.
cabal run -v0 pre-fec -- "$ROOT/examples/highorder4/highorder4.fme" \
  > "$WORK/highorder.egi"
grep -F 'Formurae.divg FormuraeInternalContext (Formurae.grad FormuraeInternalContext u)' \
  "$WORK/highorder.egi" >/dev/null
run_machine "$WORK/highorder.egi" "$WORK/highorder.feir"
grep -F '(order 2)' "$WORK/highorder.feir" >/dev/null
grep -F '(accuracy 4)' "$WORK/highorder.feir" >/dev/null
grep -F '(count 2)' "$WORK/highorder.feir" >/dev/null
if grep -E '\(analytic-call|\(count 1\)|grad|divg' "$WORK/highorder.feir" >/dev/null; then
  printf 'high-order FEIR retained an operator/analytic call or first derivative\n' >&2
  exit 1
fi
cabal run -v0 post-fec -- "$WORK/highorder.feir" > "$WORK/highorder.fmr"
grep -F 'u[i-2,j,k]' "$WORK/highorder.fmr" >/dev/null
grep -F 'u[i+2,j,k]' "$WORK/highorder.fmr" >/dev/null
if grep -E 'i[-+]4|j[-+]4|k[-+]4' "$WORK/highorder.fmr" >/dev/null; then
  printf 'high-order compact stencil unexpectedly contains a radius-4 offset\n' >&2
  exit 1
fi

# Orthogonal Hodge remains pure Egison algebra.  The same unquoted scale
# symbols feed GeometryNF and OperatorContext, while variable codiff stays one
# versioned request and materializes coefficient/flux/result effects in order.
cabal run -v0 pre-fec -- "$ROOT/tests/fixtures/pre_fec_metric_forms.fme" \
  > "$WORK/metric-forms.egi"
grep -F 'FEIR.unquoteAll (feGeometryScale 1)' "$WORK/metric-forms.egi" >/dev/null
grep -F 'Formurae.hodge feOperatorContext A' "$WORK/metric-forms.egi" >/dev/null
grep -F 'Formurae.codiff feOperatorContext A' "$WORK/metric-forms.egi" >/dev/null
if grep -F 'expandAll' "$WORK/metric-forms.egi" >/dev/null; then
  printf 'metric form normalization contains forbidden expandAll\n' >&2
  exit 1
fi
run_machine "$WORK/metric-forms.egi" "$WORK/metric-forms.feir"
grep -F '(op-id "codiff.metric@1")' "$WORK/metric-forms.feir" >/dev/null
if grep -F '(quote ' "$WORK/metric-forms.feir" >/dev/null; then
  printf 'metric form FEIR retained a quote node\n' >&2
  exit 1
fi
cabal run -v0 post-fec -- "$WORK/metric-forms.feir" > "$WORK/metric-forms.fmr"
grep -F "H_1'[i,j] = (-1) * dx * i * A_2[i,j] + (-1) * A_2[i,j]" \
  "$WORK/metric-forms.fmr" >/dev/null
grep -F "H_2'[i,j] = A_1[i,j] / (1 + dx * ((1 / 2) + i))" \
  "$WORK/metric-forms.fmr" >/dev/null
flux_line=$(grep -n 'FormuraeInternalCodiff1BScalarFlux1\[i,j\] =' \
  "$WORK/metric-forms.fmr" | cut -d: -f1)
result_line=$(grep -n 'FormuraeInternalCodiff1BScalarResult\[i,j\] =' \
  "$WORK/metric-forms.fmr" | cut -d: -f1)
consumer_line=$(grep -n "D'\[i,j\] = FormuraeInternalCodiff1BScalarResult" \
  "$WORK/metric-forms.fmr" | cut -d: -f1)
if [ "$flux_line" -ge "$result_line" ] || [ "$result_line" -ge "$consumer_line" ]; then
  printf 'metric codifferential auxiliary schedule is not topological\n' >&2
  exit 1
fi
if grep -E 'codiff\.metric|opaque-discrete' "$WORK/metric-forms.fmr" >/dev/null; then
  printf 'metric form FMR retained an opaque marker\n' >&2
  exit 1
fi

# All remaining manifest primitives cross the same machine boundary.  This
# fixture exercises both dependency directions: materialized tensor -> flux
# divergence and flux divergence -> materialized scalar.
cabal run -v0 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_remaining_primitives.fme" \
  > "$WORK/remaining-primitives.egi"
grep -F 'Formurae.orderedDerivative feOperatorContext [| 1, 2 |] u' \
  "$WORK/remaining-primitives.egi" >/dev/null
grep -F 'Formurae.resampleExplicit feOperatorContext [| 1, 1 |] u' \
  "$WORK/remaining-primitives.egi" >/dev/null
grep -F 'Formurae.fluxConservativeDivergence feOperatorContext (Formurae.materialized feOperatorContext (F + G))' \
  "$WORK/remaining-primitives.egi" >/dev/null
grep -F 'Formurae.materialized feOperatorContext (Formurae.fluxConservativeDivergence feOperatorContext F)' \
  "$WORK/remaining-primitives.egi" >/dev/null
run_machine "$WORK/remaining-primitives.egi" \
  "$WORK/remaining-primitives.feir"
for operation in \
  derivative.ordered@1 \
  resample.explicit@1 \
  flux.conservative-divergence@1 \
  operator.materialized@1; do
  grep -F "(op-id \"$operation\")" "$WORK/remaining-primitives.feir" >/dev/null
done
cabal run -v0 post-fec -- "$WORK/remaining-primitives.feir" \
  > "$WORK/remaining-primitives.fmr"
grep -F "u'[i,j] = FormuraeInternalConservative1Result" \
  "$WORK/remaining-primitives.fmr" >/dev/null
grep -F "v'[i,j] = (1 / 4) * u[i,j]" \
  "$WORK/remaining-primitives.fmr" >/dev/null
materialized_tensor_line=$(grep -n 'FormuraeInternalMaterialized1B1\[i,j\] =' \
  "$WORK/remaining-primitives.fmr" | cut -d: -f1)
parent_flux_line=$(grep -n 'FormuraeInternalConservative1Flux1\[i,j\] =' \
  "$WORK/remaining-primitives.fmr" | cut -d: -f1)
child_flux_result_line=$(grep -n 'FormuraeInternalConservative2Result\[i,j\] =' \
  "$WORK/remaining-primitives.fmr" | cut -d: -f1)
parent_materialized_line=$(grep -n 'FormuraeInternalMaterialized2BScalar\[i,j\] =' \
  "$WORK/remaining-primitives.fmr" | cut -d: -f1)
if [ "$materialized_tensor_line" -ge "$parent_flux_line" ] \
   || [ "$child_flux_result_line" -ge "$parent_materialized_line" ]; then
  printf 'remaining primitive dependency schedule is not topological\n' >&2
  exit 1
fi
if grep -E 'opaque-discrete|derivative\.ordered|resample\.explicit|flux\.conservative|operator\.materialized' \
     "$WORK/remaining-primitives.fmr" >/dev/null; then
  printf 'remaining primitive FMR retained an FEIR marker\n' >&2
  exit 1
fi

# Materialization carries logical tensor metadata in its own payload.  An
# upper vector and a one-form with the same shape must remain distinguishable.
cabal run -v0 pre-fec -- \
  "$ROOT/tests/fixtures/pre_fec_materialized_metadata.fme" \
  > "$WORK/materialized-metadata.egi"
grep -F 'Formurae.materialized FormuraeInternalContext value' \
  "$WORK/materialized-metadata.egi" >/dev/null
grep -F 'def FormuraeInternalValue1 := stored X' \
  "$WORK/materialized-metadata.egi" >/dev/null
grep -F 'def FormuraeInternalValue2 := stored A' \
  "$WORK/materialized-metadata.egi" >/dev/null
run_machine "$WORK/materialized-metadata.egi" \
  "$WORK/materialized-metadata.feir"
cabal exec -v0 runghc -- -ifec/src tests/pre_materialized_metadata_feir.hs \
  < "$WORK/materialized-metadata.feir"
cabal run -v0 post-fec -- "$WORK/materialized-metadata.feir" \
  > "$WORK/materialized-metadata.fmr"
grep -F "X_up1'[i,j] = FormuraeInternalMaterialized1B1[i,j]" \
  "$WORK/materialized-metadata.fmr" >/dev/null
grep -F "A_1'[i,j] = FormuraeInternalMaterialized2B1[i,j]" \
  "$WORK/materialized-metadata.fmr" >/dev/null

cabal run -v0 pre-fec -- "$ROOT/examples/maxwell_dec/maxwell_dec.fme" \
  > "$WORK/maxwell-dec.egi"
grep -F 'Formurae.codiff feOperatorContext B' "$WORK/maxwell-dec.egi" >/dev/null
grep -F 'Formurae.d feOperatorContext E' "$WORK/maxwell-dec.egi" >/dev/null
grep -F 'continuum identity d(d A) = 0 failed' "$WORK/maxwell-dec.egi" >/dev/null
run_machine "$WORK/maxwell-dec.egi" "$WORK/maxwell-dec.feir"
cabal run -v0 post-fec -- "$WORK/maxwell-dec.feir" > "$WORK/maxwell-dec.fmr"
grep -F "B_1_2'[i,j,k] = B_1_2[i,j,k]" "$WORK/maxwell-dec.fmr" >/dev/null
compile_and_check maxwell_dec dec_check.c "$WORK/maxwell-dec.fmr"

while read -r geometry check_source; do
  cabal run -v0 pre-fec -- "$ROOT/examples/$geometry/$geometry.fme" \
    > "$WORK/$geometry.egi"
  grep -F 'Formurae.lbOrthogonal FormuraeInternalContext u' \
    "$WORK/$geometry.egi" >/dev/null
  grep -F 'embedding/metric must be symbolically orthogonal' \
    "$WORK/$geometry.egi" >/dev/null
  if grep -F 'expandAll' "$WORK/$geometry.egi" >/dev/null; then
    printf 'geometry normalization unit contains forbidden expandAll: %s\n' \
      "$geometry" >&2
    exit 1
  fi
  run_machine "$WORK/$geometry.egi" "$WORK/$geometry.feir"
  grep -F '(orthogonality-verified true)' "$WORK/$geometry.feir" >/dev/null
  grep -F '(op-id "lb.orthogonal@1")' "$WORK/$geometry.feir" >/dev/null
  cabal run -v0 post-fec -- "$WORK/$geometry.feir" > "$WORK/$geometry.fmr"
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
