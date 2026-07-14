#!/bin/sh

# Run the development Egison interpreter for a machine-readable compiler
# stage. Diagnostics are kept on stderr and stdout is released only after the
# process status and Egison's strict diagnostic text have both been checked.

set -u

if [ "$#" -lt 1 ]; then
  printf 'usage: %s EGISON_DIR [egison arguments ...]\n' "$0" >&2
  exit 2
fi

egison_dir=$1
shift

temporary=${TMPDIR:-/tmp}/formurae-egison-machine.$$
stdout_file=$temporary.stdout
stderr_file=$temporary.stderr
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT HUP INT TERM

strip_origin_markers() {
  sed '/^@@FORMURAE_ACTIVE_ORIGIN:[0-9][0-9]*@@$/d' "$stdout_file"
}

report_source_origin() {
  if ! grep -E '^(Parse error|Parser error|Evaluation error|Error|Assertion failed):' \
      "$stdout_file" "$stderr_file" >/dev/null; then
    return
  fi

  origin_id=$(
    sed -n \
      's/^@@FORMURAE_ACTIVE_ORIGIN:\([0-9][0-9]*\)@@$/\1/p' \
      "$stdout_file" | tail -n 1
  )
  if [ -z "$origin_id" ]; then
    return
  fi

  for source_unit in "$@"; do
    if [ -f "$source_unit" ] &&
       grep -q "^-- FORMURAE-DIAGNOSTIC-BEGIN $origin_id\$" \
         "$source_unit"; then
      awk -v origin="$origin_id" '
        $0 == "-- FORMURAE-DIAGNOSTIC-BEGIN " origin { active = 1; next }
        $0 == "-- FORMURAE-DIAGNOSTIC-END " origin { exit }
        active && /^-- FORMURAE-DIAGNOSTIC / {
          sub(/^-- FORMURAE-DIAGNOSTIC /, "")
          print
        }
      ' "$source_unit" >&2
      return
    fi
  done
}

if (cd "$egison_dir" &&
    cabal run -v0 -j1 egison -- --type-check-strict "$@" \
      >"$stdout_file" 2>"$stderr_file"); then
  status=0
else
  status=$?
fi

if [ "$status" -ne 0 ]; then
  report_source_origin "$@"
  cat "$stderr_file" >&2
  strip_origin_markers >&2
  exit "$status"
fi

if grep -E '^(Type error|Warning|Parse error|Parser error|Evaluation error|Desugar error|Egison error|Error|Assertion failed):' \
    "$stdout_file" "$stderr_file" >/dev/null; then
  report_source_origin "$@"
  cat "$stderr_file" >&2
  strip_origin_markers >&2
  exit 1
fi

cat "$stderr_file" >&2
strip_origin_markers
