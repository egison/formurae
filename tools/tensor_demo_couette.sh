#!/bin/sh
# Build, validate and simulate the model without a Python interpreter.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mode=${1:-simulate}
case "$mode" in build|check|simulate) ;; *) printf 'usage: %s [build|check|simulate]\n' "$0" >&2; exit 2;; esac
build=.build/native-couette
generated=examples/tensor_demos/generated/oldroyd_couette
results=examples/tensor_demos/results
tools/build_native.sh examples/tensor_demos/oldroyd_couette.fme "$build"
mkdir -p "$generated" "$results" .build/tensor-demos
cp "$build/model.c" "$build/formurae_native.h" "$build/stages.txt" "$generated/"
while IFS= read -r stage; do
  for ext in fme egi feir fmr; do cp "$build/$stage.$ext" "$generated/"; done
done < "$build/stages.txt"
if [ "$mode" = check ]; then
  ${CC:-cc} -O2 -std=c11 -fsanitize=undefined tests/native_runtime.c -lm -o "$build/check-runtime"
  "$build/check-runtime"
  ${CC:-cc} -O2 -std=c11 -fsanitize=undefined -I"$build" tests/native_couette.c -lm -o "$build/validate"
  "$build/validate" > "$build/validation.json"
  if "$build/simulate" --dt 1 --steps 1 --every 1 --output "$build/rejected-step" > "$build/rejected-step.log" 2>&1; then
    printf 'the model accepted an unstable transport step\n' >&2; exit 1
  fi
  grep -q 'required courant < 1' "$build/rejected-step.log"
  tools/write_native_report.sh "$build/validation.json" "$results/couette-validation.json"
elif [ "$mode" = simulate ]; then
  "$build/simulate" --output .build/tensor-demos/couette
  tools/write_native_report.sh .build/tensor-demos/couette/report.json "$results/couette.json"
fi
