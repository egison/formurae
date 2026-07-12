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
  if cabal run -v0 pre-fec -- "$source" \
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
  if cabal run -v0 pre-fec -- "$source" \
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

cd "$ROOT"
expect_failure pre_fec_effect_derivative_error \
  '6:13: analytic derivative contains discrete operation: lb.orthogonal@1'
expect_failure pre_fec_effect_function_alias_error \
  '7:13: analytic derivative contains discrete operation: lb.orthogonal@1'
expect_failure pre_fec_forward_definition_error \
  '5:15: forward reference to user definition second'
expect_failure pre_fec_unknown_axis_error \
  '6:8: orderedD uses unknown coordinate y'
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
expect_parse_failure pre_fec_definition_metric_collision \
  "definition name 'g' conflicts with generated metric value 'g' (line 6)"
expect_parse_failure pre_fec_axis_value_collision \
  "value name 'r' is reserved for generated Egison code (param, line 4)"
expect_parse_failure pre_fec_definition_axis_parameter_collision \
  "definition parameter 'r' in 'identity' conflicts with a coordinate axis (line 5)"
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

printf 'pre-fec static source-diagnostic tests: ok\n'
