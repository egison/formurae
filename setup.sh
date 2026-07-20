#!/bin/sh
# Build the Formura compiler used by this repo with Cabal into ./bin/formura.
# Preferred source: the sibling clone ../formura (github.com/egison/formura,
# our fork carrying the GHC 9.6 port and fixes). Fallback: clone the fork at
# the exact revision validated by this repository.
set -eu
cd "$(dirname "$0")"
ROOT=$(pwd)
FORMURA_REV=3bc74b5c6f1a24dfffe869839d75fd44b8aa2eb0

mkdir -p vendor bin

if [ ! -e vendor/formura ]; then
  if [ -d ../formura ]; then
    ln -s ../../formura vendor/formura
  else
    git clone https://github.com/egison/formura.git vendor/formura
    git -C vendor/formura checkout --detach "$FORMURA_REV"
  fi
fi

actual_rev=$(git -C vendor/formura rev-parse HEAD)
if [ "$actual_rev" != "$FORMURA_REV" ]; then
  echo "setup: vendor/formura is at $actual_rev; expected $FORMURA_REV" >&2
  echo "setup: remove vendor/formura or check out the validated revision" >&2
  exit 1
fi

(cd vendor/formura && cabal install exe:formura \
  --installdir="$ROOT/bin" --overwrite-policy=always)
"$ROOT/bin/formura" --version
