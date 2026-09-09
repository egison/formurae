#!/bin/sh
# Compile checked tensor stages and a declarative schedule to a standalone C executable.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source=${1:?usage: build_native.sh MODEL.fme OUTPUT_DIRECTORY}
folder=${2:?usage: build_native.sh MODEL.fme OUTPUT_DIRECTORY}
case "$source" in /*) ;; *) source="$PWD/$source";; esac
case "$folder" in /*) ;; *) folder="$PWD/$folder";; esac
cd "$root"
formurae_datadir="$root"
export formurae_datadir
cabal build exe:formurae-native exe:formurae-pre
native=$(cabal list-bin exe:formurae-native)
pre=$(cabal list-bin exe:formurae-pre)
egison=$(tools/prepare_elastic_validation.sh)
mkdir -p "$folder"
fingerprint=$(shasum -a 256 "$pre" "$root"/lib/*.egi "$root"/spec/* "$root/tools/run_formurae_normalization.sh" "$root/tools/run_egison_machine.sh" "$root/tools/prepare_elastic_validation.sh")
"$native" prepare "$source" "$folder" > "$folder/stages.txt"
while IFS= read -r stage; do
  "$pre" "$folder/$stage.fme" > "$folder/$stage.egi"
  signature=$({ printf '%s\n' "$fingerprint"; cat "$folder/$stage.egi"; } | shasum -a 256)
  if [ -s "$folder/$stage.feir" ] && [ -f "$folder/$stage.sha256" ] && [ "$(cat "$folder/$stage.sha256")" = "$signature" ]; then
    printf 'Reusing checked native stage %s\n' "$stage"
  else
    printf 'Normalizing native stage %s\n' "$stage"
    "$root/tools/run_formurae_normalization.sh" "$egison" "$folder/$stage.egi" > "$folder/$stage.feir.tmp"
    mv "$folder/$stage.feir.tmp" "$folder/$stage.feir"
    printf '%s\n' "$signature" > "$folder/$stage.sha256"
  fi
done < "$folder/stages.txt"
"$native" emit "$source" "$folder"
cp "$root/runtime/formurae_native.h" "$folder/formurae_native.h"
${CC:-cc} -O2 -std=c11 "$folder/model.c" -lm -o "$folder/simulate"
printf 'Built %s/simulate\n' "$folder"
