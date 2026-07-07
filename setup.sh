#!/bin/sh
# Build the Formura compiler used by this repo into ./bin/formura.
# Preferred source: the sibling clone ../formura (github.com/egison/formura,
# our fork carrying the GHC 9.6 port and fixes). Fallback: clone the fork
# into vendor/formura and apply the port if the branch is unavailable.
set -eu
cd "$(dirname "$0")"
ROOT=$(pwd)

mkdir -p vendor bin

if [ ! -e vendor/formura ]; then
  if [ -d ../formura ]; then
    ln -s ../../formura vendor/formura
  else
    git clone https://github.com/egison/formura.git vendor/formura
    (cd vendor/formura && git checkout ghc96-port) || {
      cd vendor/formura
      git apply ../../formura-patch/formura-ghc96.patch
      touch .ghc96-patched
      cd "$ROOT"
    }
  fi
fi

(cd vendor/formura && stack install --local-bin-path "$ROOT/bin")
"$ROOT/bin/formura" --version
