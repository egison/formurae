#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-static-diagnostic.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

expect_failure() {
  fixture=$1
  expected=$2
  source="tests/fixtures/$fixture.fme"
  if cabal run -v0 -j1 formurae-pre -- "$source" \
       > "$WORK/$fixture.out" 2> "$WORK/$fixture.err"; then
    printf 'formurae-pre accepted invalid fixture: %s\n' "$source" >&2
    exit 1
  fi
  if [ -s "$WORK/$fixture.out" ]; then
    printf 'formurae-pre leaked output for invalid fixture: %s\n' "$source" >&2
    exit 1
  fi
  grep -F "formurae-pre: error: $source:$expected" "$WORK/$fixture.err" >/dev/null
  if grep -E 'EffectError|EffectIssue|EmitExpressionError|EmitAtSource' \
       "$WORK/$fixture.err" >/dev/null; then
    printf 'formurae-pre exposed an internal diagnostic constructor: %s\n' \
      "$source" >&2
    exit 1
  fi
}

expect_parse_failure() {
  fixture=$1
  expected=$2
  source="tests/fixtures/$fixture.fme"
  if cabal run -v0 -j1 formurae-pre -- "$source" \
       > "$WORK/$fixture.out" 2> "$WORK/$fixture.err"; then
    printf 'formurae-pre accepted invalid declaration fixture: %s\n' "$source" >&2
    exit 1
  fi
  if [ -s "$WORK/$fixture.out" ]; then
    printf 'formurae-pre leaked output for invalid declaration fixture: %s\n' \
      "$source" >&2
    exit 1
  fi
  grep -F "formurae-pre: error: $expected" "$WORK/$fixture.err" >/dev/null
}

expect_success() {
  fixture=$1
  source="tests/fixtures/$fixture.fme"
  cabal run -v0 -j1 formurae-pre -- "$source" > "$WORK/$fixture.out"
  if [ ! -s "$WORK/$fixture.out" ]; then
    printf 'formurae-pre produced no output for valid fixture: %s\n' "$source" >&2
    exit 1
  fi
}

cd "$ROOT"
# Canonical Δ/δ on declared geometry are prelude macro expansions; the
# derivative-nesting rules now report the grid-whole operations of the
# expanded flux divergence, and def bodies cannot wrap the macros at all.
expect_failure pre_effect_derivative_error \
  '7:8: grid derivative contains nested discrete operation: derivative.grid-whole'
expect_parse_failure pre_effect_function_alias_error \
  "macro 'Δ' expands to step statements; it cannot be used in def weighted"
expect_failure pre_effect_analytic_derivative_error \
  '7:8: analytic derivative contains discrete operation: derivative.grid-whole'
expect_failure pre_effect_contract_reducer_error \
  '8:8: contractWith receives discrete operation as a higher-order argument: resample.explicit'
expect_failure pre_forward_definition_error \
  '5:15: forward reference to user definition second'
expect_failure pre_unknown_axis_error \
  '6:8: quoted derivative uses unknown coordinate y'
expect_failure pre_single_quoted_derivative_error \
  '6:8: invalid effect expression: a single quoted derivative is redundant; write the coordinate derivative unquoted and reserve backquotes for ordered chains'
expect_failure pre_variable_hodge_laplacian_error \
  '7:8: canonical Δ_H is not supported for variable metric geometry; write its metric-dependent discretization explicitly'
expect_failure pre_variable_hodge_composition_error \
  '8:8: hodge (d (hodge A)) cannot be analytically expanded on variable metric geometry; write canonical δ A so the compiler preserves the weighted discrete adjoint'
expect_failure pre_quoted_tensor_operand_error \
  '7:8: quoted derivative requires a scalar operand, but received ordinary tensor'
expect_failure pre_scalar_delta_tensor_error \
  '6:10: scalar Δ requires a scalar operand, but received ordinary tensor'
expect_failure pre_canonical_arity_error \
  '6:8: canonical δ is unary, but received 2 operands'
expect_failure pre_canonical_alias_error \
  '6:21: canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand'
expect_failure pre_scalar_local_kind_mismatch \
  '7:13: local q declares scalar, but its RHS has ordinary tensor kind'
# The static layer distinguishes only scalar and tensor: form degrees are
# validated during normalization from the value's dfOrder, so these sources
# pass formurae-pre.  tests/pre_egison_diagnostic.sh asserts the normalization
# failures of the non-form operands among them.
expect_success pre_codiff_tensor_error
expect_success pre_shadowed_intrinsic_kind_error
expect_success pre_divg_rank_unknown_error
expect_success pre_form_zero_scalar_mix_error
expect_success pre_form_local_kind_mismatch
expect_success pre_dot_shadow_kind_error
expect_success pre_update_kind_mismatch
expect_success pre_initializer_kind_mismatch
expect_parse_failure pre_metric_kind_mismatch \
  'metric scale expression requires a scalar value, but received ordinary tensor'
expect_parse_failure pre_embedding_canonical_value_error \
  "macro 'δ' expands to step statements; it cannot be used in embedding expression"
expect_parse_failure pre_raw_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 5)"
expect_parse_failure pre_char_literal_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 7)"
expect_parse_failure pre_step_internal_bridge_error \
  "reserved normalization capability 'FormuraeInternalGridWholeDerivative' cannot be used in Formurae source (line 8)"
expect_parse_failure pre_metric_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 4)"
expect_parse_failure pre_metric_string_comment_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 4)"
expect_parse_failure pre_embedding_string_comment_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 4)"
expect_parse_failure pre_axis_operator_collision \
  "coordinate name 'Δ' is reserved for a surface operator or intrinsic (axes line 3)"
expect_success pre_reserved_string_near_miss
expect_success pre_definition_higher_order_sqrt
expect_success pre_raw_shadowed_canonical
expect_parse_failure pre_definition_param_collision \
  "definition name 'helper' conflicts with param value binding (definition line 6, param line 4)"
expect_parse_failure pre_definition_field_collision \
  "definition name 'helper' conflicts with field value binding (definition line 6, field line 4)"
expect_parse_failure pre_definition_local_collision \
  "definition name 'helper' conflicts with local value binding (definition line 5, local line 7)"
expect_parse_failure pre_definition_let_collision \
  "definition name 'helper' conflicts with let value binding (definition line 5, let line 7)"
expect_parse_failure pre_duplicate_definition \
  "definition name 'helper' is declared more than once (lines 5, 6)"
expect_parse_failure pre_macro_init_error \
  "macro 'half' expands to step statements; it cannot be used in init expression"
expect_parse_failure pre_macro_arity_error \
  "macro 'half' expects 1 argument(s), got 2"
expect_parse_failure pre_macro_duplicate_error \
  "macro 'half' is declared more than once (line 11)"
expect_parse_failure pre_macro_body_error \
  "macro body lines must be 'local <binding>' or 'in <expression>': let z = u (line 8)"
expect_parse_failure pre_deferred_field_error \
  "deferred tensor kind is only available on local declarations (line 4)"
expect_parse_failure pre_definition_metric_collision \
  "definition name 'g' conflicts with generated metric value 'g' (line 6)"
expect_parse_failure pre_axis_value_collision \
  "value name 'r' is reserved for generated Egison code (param, line 4)"
expect_parse_failure pre_definition_axis_parameter_collision \
  "definition parameter 'r' in 'identity' conflicts with a coordinate axis (line 5)"
expect_parse_failure pre_definition_result_head_error \
  "result indices are not allowed in user definition heads; write the metric contraction in an indexed equation or local binding (line 7)"
expect_parse_failure pre_definition_result_lower_head_error \
  "result indices are not allowed in user definition heads; write the metric contraction in an indexed equation or local binding (line 7)"
expect_parse_failure pre_definition_reserved_assert_collision \
  "definition name 'assert' is reserved for generated Egison code (line 5)"
expect_parse_failure pre_definition_reserved_formal_collision \
  "definition parameter 'assert' is reserved for generated Egison code (line 5)"
expect_parse_failure pre_metric_axis_collision \
  "metric name 'r' conflicts with a coordinate axis (axes line 4)"
expect_parse_failure pre_ambient_axis_collision \
  "coordinate name 'dimension' is reserved for the ambient Egison environment (axes line 3)"
expect_parse_failure pre_ambient_formal_collision \
  "definition parameter 'inverseMetric' is reserved for the ambient Egison environment (line 5)"
expect_parse_failure pre_metric_field_collision \
  "metric name 'g' conflicts with field binding"
expect_parse_failure pre_metric_reserved_collision \
  "metric name 'metric' is reserved for the generated Egison environment (line 4)"
expect_parse_failure pre_duplicate_metric_name \
  "metric name may be declared only once (line 5)"
expect_parse_failure pre_ascii_pi_error \
  "ASCII 'pi' is a floating-point Egison value; write Unicode π for the symbolic circle constant in init expression: u"
expect_parse_failure pre_primed_pi_error \
  "symbolic constant π cannot be primed in init expression: u"
expect_parse_failure pre_pi_binding_error \
  "value name 'π' is reserved for generated Egison code (param, line 4)"
expect_parse_failure pre_raw_pi_error \
  "parameter value cannot use π because it bypasses symbolic FEIR; use a numeric backend value (line 4)"
expect_parse_failure pre_raw_initializer_pi_error \
  "raw initializer cannot use π because it bypasses symbolic FEIR; use a numeric backend value or ':=' (line 6)"
# The boundary is an axis declaration; the per-call sbpd spelling is retired
# with a migration diagnostic, and malformed declarations fail statically.
expect_parse_failure pre_sbpd_retired_error \
  "sbpd_x is retired: declare the boundary (boundary AXIS : sbp) and write the plain derivative (∂_x for sbpd_x, ∂^2_x for sbpd2_x) (line 11)"
expect_parse_failure pre_boundary_unknown_axis_error \
  "boundary declaration names unknown axis 'z' (line 5)"
expect_parse_failure pre_boundary_duplicate_error \
  "duplicate boundary declaration for axis 'x' (line 6)"
expect_parse_failure pre_boundary_ghost_value_error \
  "ghost boundary needs a fill value (line 5): boundary AXIS : ghost VALUE"

printf 'formurae-pre static source-diagnostic tests: ok\n'
