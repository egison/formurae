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
  if cabal run -v0 -j1 pre-fec -- "$source" \
       > "$WORK/$fixture.out" 2> "$WORK/$fixture.err"; then
    printf 'pre-fec accepted invalid fixture: %s\n' "$source" >&2
    exit 1
  fi
  if [ -s "$WORK/$fixture.out" ]; then
    printf 'pre-fec leaked output for invalid fixture: %s\n' "$source" >&2
    exit 1
  fi
  grep -F "pre-fec: error: $source:$expected" "$WORK/$fixture.err" >/dev/null
  if grep -E 'EffectError|EffectIssue|EmitExpressionError|EmitAtSource' \
       "$WORK/$fixture.err" >/dev/null; then
    printf 'pre-fec exposed an internal diagnostic constructor: %s\n' \
      "$source" >&2
    exit 1
  fi
}

expect_parse_failure() {
  fixture=$1
  expected=$2
  source="tests/fixtures/$fixture.fme"
  if cabal run -v0 -j1 pre-fec -- "$source" \
       > "$WORK/$fixture.out" 2> "$WORK/$fixture.err"; then
    printf 'pre-fec accepted invalid declaration fixture: %s\n' "$source" >&2
    exit 1
  fi
  if [ -s "$WORK/$fixture.out" ]; then
    printf 'pre-fec leaked output for invalid declaration fixture: %s\n' \
      "$source" >&2
    exit 1
  fi
  grep -F "pre-fec: error: $expected" "$WORK/$fixture.err" >/dev/null
}

expect_success() {
  fixture=$1
  source="tests/fixtures/$fixture.fme"
  cabal run -v0 -j1 pre-fec -- "$source" > "$WORK/$fixture.out"
  if [ ! -s "$WORK/$fixture.out" ]; then
    printf 'pre-fec produced no output for valid fixture: %s\n' "$source" >&2
    exit 1
  fi
}

cd "$ROOT"
expect_failure pre_fec_effect_derivative_error \
  '7:13: grid derivative contains nested discrete operation: lb.orthogonal@1'
expect_failure pre_fec_effect_function_alias_error \
  '8:13: grid derivative contains nested discrete operation: lb.orthogonal@1'
expect_failure pre_fec_effect_analytic_derivative_error \
  '7:13: analytic derivative contains discrete operation: lb.orthogonal@1'
expect_failure pre_fec_effect_contract_reducer_error \
  '8:8: contractWith receives discrete operation as a higher-order argument: resample.explicit@1'
expect_failure pre_fec_forward_definition_error \
  '5:15: forward reference to user definition second'
expect_failure pre_fec_unknown_axis_error \
  '6:8: quoted derivative uses unknown coordinate y'
expect_failure pre_fec_single_quoted_derivative_error \
  '6:8: invalid effect expression: a single quoted derivative is redundant; write the coordinate derivative unquoted and reserve backquotes for ordered chains'
expect_failure pre_fec_variable_hodge_laplacian_error \
  '7:8: canonical Δ_H is not supported for variable metric geometry; write its metric-dependent discretization explicitly'
expect_failure pre_fec_variable_hodge_composition_error \
  '8:8: hodge (d (hodge A)) cannot be analytically expanded on variable metric geometry; write canonical δ A so the compiler preserves the weighted discrete adjoint'
expect_failure pre_fec_quoted_tensor_operand_error \
  '7:8: quoted derivative requires a scalar operand, but received ordinary tensor'
expect_failure pre_fec_scalar_delta_tensor_error \
  '6:10: scalar Δ requires a scalar operand, but received ordinary tensor'
expect_failure pre_fec_codiff_tensor_error \
  '6:10: canonical δ requires a scalar or differential form, but received ordinary tensor'
expect_failure pre_fec_shadowed_intrinsic_kind_error \
  '9:8: canonical δ requires a statically known scalar or differential form; untyped definition parameters cannot cross this operator boundary'
expect_failure pre_fec_divg_rank_unknown_error \
  '7:8: canonical δ requires a statically known scalar or differential form; untyped definition parameters cannot cross this operator boundary'
expect_failure pre_fec_canonical_arity_error \
  '6:8: canonical δ is unary, but received 2 operands'
expect_failure pre_fec_canonical_alias_error \
  '6:21: canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand'
expect_failure pre_fec_form_zero_scalar_mix_error \
  '7:8: quoted derivative requires a scalar operand, but received 0-form'
expect_failure pre_fec_scalar_local_kind_mismatch \
  '7:13: local q declares scalar, but its RHS has ordinary tensor kind'
expect_failure pre_fec_form_local_kind_mismatch \
  '7:31: local q declares 1-form, but its RHS has ordinary tensor kind'
expect_failure pre_fec_dot_shadow_kind_error \
  '9:8: canonical δ requires a statically known scalar or differential form; untyped definition parameters cannot cross this operator boundary'
expect_failure pre_fec_update_kind_mismatch \
  '8:8: field u declares scalar, but its RHS has 0-form kind'
expect_failure pre_fec_initializer_kind_mismatch \
  '7:8: field u declares scalar, but its RHS has 0-form kind'
expect_parse_failure pre_fec_metric_kind_mismatch \
  'metric scale expression requires a scalar value, but received ordinary tensor'
expect_parse_failure pre_fec_embedding_canonical_value_error \
  'canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand'
expect_parse_failure pre_fec_dd_kind_mismatch \
  'assert-dd-zero internally applies canonical d and requires a scalar or differential form, but received ordinary tensor'
expect_parse_failure pre_fec_raw_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 5)"
expect_parse_failure pre_fec_char_literal_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 7)"
expect_parse_failure pre_fec_step_internal_bridge_error \
  "reserved normalization capability 'FormuraeInternalGridWholeDerivative' cannot be used in Formurae source (line 8)"
expect_parse_failure pre_fec_metric_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 4)"
expect_parse_failure pre_fec_metric_string_comment_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 4)"
expect_parse_failure pre_fec_embedding_string_comment_opaque_forge_error \
  "reserved normalization capability 'functionSymbol' cannot be used in Formurae source (line 4)"
expect_parse_failure pre_fec_axis_operator_collision \
  "coordinate name 'Δ' is reserved for a surface operator or intrinsic (axes line 3)"
expect_success pre_fec_reserved_string_near_miss
expect_success pre_fec_definition_higher_order_sqrt
expect_success pre_fec_raw_shadowed_canonical
expect_parse_failure pre_fec_definition_param_collision \
  "definition name 'helper' conflicts with param value binding (definition line 6, param line 4)"
expect_parse_failure pre_fec_definition_field_collision \
  "definition name 'helper' conflicts with field value binding (definition line 6, field line 4)"
expect_parse_failure pre_fec_definition_local_collision \
  "definition name 'helper' conflicts with local value binding (definition line 5, local line 7)"
expect_parse_failure pre_fec_definition_let_collision \
  "definition name 'helper' conflicts with let value binding (definition line 5, let line 7)"
expect_parse_failure pre_fec_duplicate_definition \
  "definition name 'helper' is declared more than once (lines 5, 6)"
expect_parse_failure pre_fec_macro_init_error \
  "macro 'half' expands to step statements; it cannot be used in init expression"
expect_parse_failure pre_fec_macro_arity_error \
  "macro 'half' expects 1 argument(s), got 2"
expect_parse_failure pre_fec_macro_duplicate_error \
  "macro 'half' is declared more than once (line 11)"
expect_parse_failure pre_fec_macro_body_error \
  "macro body lines must be 'local <binding>' or 'in <expression>': let z = u (line 8)"
expect_parse_failure pre_fec_definition_metric_collision \
  "definition name 'g' conflicts with generated metric value 'g' (line 6)"
expect_parse_failure pre_fec_axis_value_collision \
  "value name 'r' is reserved for generated Egison code (param, line 4)"
expect_parse_failure pre_fec_definition_axis_parameter_collision \
  "definition parameter 'r' in 'identity' conflicts with a coordinate axis (line 5)"
expect_parse_failure pre_fec_definition_result_head_error \
  "result indices are not allowed in user definition heads; write the metric contraction in an indexed equation or local binding (line 7)"
expect_parse_failure pre_fec_definition_result_lower_head_error \
  "result indices are not allowed in user definition heads; write the metric contraction in an indexed equation or local binding (line 7)"
expect_parse_failure pre_fec_definition_reserved_assert_collision \
  "definition name 'assert' is reserved for generated Egison code (line 5)"
expect_parse_failure pre_fec_definition_reserved_formal_collision \
  "definition parameter 'assert' is reserved for generated Egison code (line 5)"
expect_parse_failure pre_fec_metric_axis_collision \
  "metric name 'r' conflicts with a coordinate axis (axes line 4)"
expect_parse_failure pre_fec_ambient_axis_collision \
  "coordinate name 'dimension' is reserved for the ambient Egison environment (axes line 3)"
expect_parse_failure pre_fec_ambient_formal_collision \
  "definition parameter 'inverseMetric' is reserved for the ambient Egison environment (line 5)"
expect_parse_failure pre_fec_metric_field_collision \
  "metric name 'g' conflicts with field binding"
expect_parse_failure pre_fec_metric_reserved_collision \
  "metric name 'metric' is reserved for the generated Egison environment (line 4)"
expect_parse_failure pre_fec_duplicate_metric_name \
  "metric name may be declared only once (line 5)"
expect_parse_failure pre_fec_ascii_pi_error \
  "ASCII 'pi' is a floating-point Egison value; write Unicode π for the symbolic circle constant in init expression: u"
expect_parse_failure pre_fec_primed_pi_error \
  "symbolic constant π cannot be primed in init expression: u"
expect_parse_failure pre_fec_pi_binding_error \
  "value name 'π' is reserved for generated Egison code (param, line 4)"
expect_parse_failure pre_fec_raw_pi_error \
  "parameter value cannot use π because it bypasses symbolic FEIR; use a numeric backend value (line 4)"
expect_parse_failure pre_fec_raw_initializer_pi_error \
  "raw initializer cannot use π because it bypasses symbolic FEIR; use a numeric backend value or ':=' (line 6)"

printf 'pre-fec static source-diagnostic tests: ok\n'
