#!/bin/sh
# Fetch Formura 2.3.2, apply the GHC 9.6 port patch, and build it.
# The binary is installed to ./bin/formura (used by the Makefile).
set -eu
cd "$(dirname "$0")"

mkdir -p vendor bin

if [ ! -d vendor/formura ]; then
  git clone https://github.com/formura/formura.git vendor/formura
fi

cd vendor/formura
if [ ! -f .ghc96-patched ]; then
  git apply ../../formura-patch/formura-ghc96.patch
  touch .ghc96-patched
fi

stack install --local-bin-path ../../bin
../../bin/formura --version
