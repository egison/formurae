#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}

cd "$ROOT"
runghc -ifec/src tools/generate-feir-primitives.hs --check
cabal build -v0 -j1 all

for test in \
  feir_sexpr \
  feir_fingerprint \
  feir_codec \
  feir_validate \
  feir_primitive_manifest \
  feir_primitive_bindings \
  feir_registry_fingerprint \
  tensor_expr_parser \
  pre_canonical_form_surface \
  surface_indexed_lhs \
  pre_parse_profile \
  pre_registry \
  pre_effect \
  pre_type_check \
  pre_provenance \
  pre_raw_egison_fallback \
  pre_emit_egison \
  pre_ambient_metric \
  pre_emit_remaining_primitives \
  pre_geometry_emit \
  post_stencil \
  post_location \
  post_fmr \
  post_normalize \
  post_profile \
  post_geometry \
  post_explicit_stencil \
  post_primitive_contract \
  post_backend_plan \
  post_backend_remaining_primitives \
  post_compile \
  post_compile_wide \
  post_compile_sbp \
  post_compile_grid_whole \
  post_compile_ordered_resample \
  post_compile_explicit_effects \
  post_diagnostic
do
  cabal exec -v0 runghc -- -ifec/src "tests/$test.hs"
done

"$ROOT/tools/run_egison_machine.sh" "$EGISON_DIR" -t \
  -l "$ROOT/lib/formurae-primitives.egi" \
  "$ROOT/tests/formurae_primitive_bindings_lib.egi" >/dev/null

"$ROOT/tools/run_egison_machine.sh" "$EGISON_DIR" -t \
  -l "$ROOT/lib/formurae-tensor.egi" \
  "$ROOT/tests/formurae_tensor_lib.egi" >/dev/null

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
  "$ROOT/tests/formurae_operators_lib.egi" >/dev/null
sh tests/formurae_operator_errors.sh

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
  "$ROOT/tests/formurae_form_operators_lib.egi" >/dev/null

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
  "$ROOT/tests/formurae_form_operators_2d_lib.egi" >/dev/null

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
  "$ROOT/tests/formurae_opaque_lib.egi" >/dev/null

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
  "$ROOT/tests/formurae_remaining_primitives_lib.egi" >/dev/null

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
  "$ROOT/tests/formurae_feir_lib.egi" \
  | cabal exec -v0 runghc -- -ifec/src tests/feir_egison_wire.hs

sh tests/formurae_opaque_errors.sh
sh tests/egison_machine_output.sh "$EGISON_DIR"
sh tests/pre_egison_diagnostic.sh
sh tests/pre_tensor_metadata.sh
sh tests/pre_static_diagnostic_cli.sh
sh tests/pre_user_definitions.sh
sh tests/pre_macro_expansion.sh
sh tests/pre_deferred_local.sh
sh tests/pre_generic_codiff.sh
sh tests/post_diagnostic_cli.sh
sh tests/pre_provenance_e2e.sh
# Includes the typed conservative-local FEIR check in
# tests/pre_conservative_local_feir.hs.
sh tests/pre_fec_pipeline.sh

printf 'Formurae compiler suite: ok\n'
