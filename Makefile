# Egison -> Formura -> C -> run, end to end.
#
#   make setup        : fetch + patch + build Formura (vendor/, bin/formura)
#   make diffusion3d  : generate .fmr, run Formura, compile with the MPI stub, run the check
#   make maxwell3d    : ditto for Maxwell
#   make all          : both examples
#
# The Egison interpreter must be the development tree (the installed
# binary ships an older math library); set EGISON_DIR accordingly.

EGISON_DIR ?= $(abspath ../egison)
FORMURA    ?= $(abspath bin/formura)
MPISTUB    := $(abspath mpistub)
FMRGEN     := $(abspath lib/fmrgen.egi)

CC      ?= cc
CFLAGS  ?= -O2 -std=c11

EGISON_RUN = cd $(EGISON_DIR) && cabal run -v0 egison --

.PHONY: all setup diffusion3d maxwell3d maxwell3d-yee clean

all: diffusion3d maxwell3d maxwell3d-yee

setup:
	./setup.sh

diffusion3d:
	$(EGISON_RUN) -l $(FMRGEN) $(abspath examples/diffusion3d/diffusion3d.egi) \
	  > $(abspath examples/diffusion3d/diffusion3d.fmr)
	cd examples/diffusion3d && $(FORMURA) diffusion3d.fmr
	cd examples/diffusion3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check main_check.c diffusion3d.c -lm
	cd examples/diffusion3d && ./check

maxwell3d:
	$(EGISON_RUN) -l $(FMRGEN) $(abspath examples/maxwell3d/maxwell3d.egi) \
	  > $(abspath examples/maxwell3d/maxwell3d.fmr)
	cd examples/maxwell3d && $(FORMURA) maxwell3d.fmr
	cd examples/maxwell3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check maxwell_check.c maxwell3d.c -lm
	cd examples/maxwell3d && ./check

maxwell3d-yee:
	$(EGISON_RUN) -l $(FMRGEN) $(abspath examples/maxwell3d_yee/maxwell3d_yee.egi) \
	  > $(abspath examples/maxwell3d_yee/maxwell3d_yee.fmr)
	cd examples/maxwell3d_yee && $(FORMURA) maxwell3d_yee.fmr
	cd examples/maxwell3d_yee && $(CC) $(CFLAGS) -I$(MPISTUB) -o check maxwell_yee_check.c maxwell3d_yee.c -lm
	cd examples/maxwell3d_yee && ./check

clean:
	rm -f examples/*/check examples/*/*.o examples/*/run
	rm -f examples/diffusion3d/diffusion3d.c examples/diffusion3d/diffusion3d.h
	rm -f examples/maxwell3d/maxwell3d.c examples/maxwell3d/maxwell3d.h
	rm -f examples/maxwell3d_yee/maxwell3d_yee.c examples/maxwell3d_yee/maxwell3d_yee.h
