#!/bin/sh
# One user-authored .fme controls initialization, parameters and time evolution.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
cabal build exe:formurae exe:formurae-pre exe:formurae-native
cli=$(cabal list-bin exe:formurae)
FORMURAE_PRE=$(cabal list-bin exe:formurae-pre)
FORMURAE_NATIVE=$(cabal list-bin exe:formurae-native)
formurae_datadir=$root
egison_datadir=$(tools/prepare_elastic_validation.sh)
EGISON=$(cd "$egison_datadir" && cabal list-bin exe:egison)
export FORMURAE_PRE FORMURAE_NATIVE formurae_datadir egison_datadir EGISON
mkdir -p .build/native-cli-test
cp tests/fixtures/native_model.fme .build/native-cli-test/model.fme
"$cli" run .build/native-cli-test/model.fme
grep -q '"time":0.25,"value":1.5' .build/native-cli-test/model.native/output/report.json
sed 's/param gain = 2/param gain = 4/' tests/fixtures/native_model.fme > .build/native-cli-test/model.fme
"$cli" run .build/native-cli-test/model.fme
grep -q '"time":0.25,"value":2' .build/native-cli-test/model.native/output/report.json
if .build/native-cli-test/model.native/simulate --dt -1 >/dev/null 2>&1; then
  printf 'invalid time step accepted\n' >&2; exit 1
fi
if .build/native-cli-test/model.native/simulate --steps nope >/dev/null 2>&1; then
  printf 'invalid step count accepted\n' >&2; exit 1
fi
printf 'native CLI: one source file and changed source parameter both execute correctly\n'
