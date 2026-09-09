#!/bin/sh
# Attach exact source hashes to a native JSON report; no numerical processing.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
input=${1:?input report required}
output=${2:?output report required}
{
  printf '{"source_sha256":{'
  separator=''
  for path in examples/tensor_demos/oldroyd_couette.fme \
    examples/tensor_demos/generated/oldroyd_couette/model.c \
    runtime/formurae_native.h src/Formurae/Native.hs src/Formurae/Pre/TypeCheck.hs \
    app/formurae/Main.hs app/formurae-native/Main.hs tests/native_couette.c tests/native_runtime.c \
    tools/build_native.sh tools/tensor_demo_couette.sh tools/write_native_report.sh; do
    digest=$(shasum -a 256 "$path")
    printf '%s"%s":"%s"' "$separator" "$path" "${digest%% *}"
    separator=,
  done
  printf '},'
  sed '1s/^{//' "$input"
} > "$output.tmp"
mv "$output.tmp" "$output"
