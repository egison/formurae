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
FMRDSL     := $(abspath lib/fmrdsl.egi)
FEC_RUN    = cabal run -v0 fec --

CC      ?= cc
CFLAGS  ?= -O2 -std=c11

EGISON_RUN = cd $(EGISON_DIR) && cabal run -v0 egison --

.PHONY: all setup diffusion3d maxwell3d maxwell3d-yee pearson3d burgers3d cahnhilliard3d tdgl3d mhd-ot elastic3d metric-torus kleingordon shallowwater lbm-d3q19 acoustic3d euler-sod ks3d highorder4 dirichlet-diffusion maxwell-dec clean

all: diffusion3d maxwell3d maxwell3d-yee pearson3d burgers3d cahnhilliard3d tdgl3d mhd-ot elastic3d metric-torus kleingordon shallowwater lbm-d3q19 acoustic3d euler-sod ks3d highorder4 dirichlet-diffusion maxwell-dec

setup:
	./setup.sh

diffusion3d:
	$(FEC_RUN) $(abspath examples/diffusion3d/diffusion3d.fe) > $(abspath examples/diffusion3d/diffusion3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/diffusion3d/diffusion3d.egi) \
	  > $(abspath examples/diffusion3d/diffusion3d.fmr)
	cd examples/diffusion3d && $(FORMURA) diffusion3d.fmr
	cd examples/diffusion3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check main_check.c diffusion3d.c -lm
	cd examples/diffusion3d && ./check

maxwell3d:
	$(FEC_RUN) $(abspath examples/maxwell3d/maxwell3d.fe) > $(abspath examples/maxwell3d/maxwell3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/maxwell3d/maxwell3d.egi) \
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

pearson3d:
	$(FEC_RUN) $(abspath examples/pearson3d/pearson3d.fe) > $(abspath examples/pearson3d/pearson3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/pearson3d/pearson3d.egi) \
	  > $(abspath examples/pearson3d/pearson3d.fmr)
	cd examples/pearson3d && $(FORMURA) pearson3d.fmr
	cd examples/pearson3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check pearson_check.c pearson3d.c -lm
	cd examples/pearson3d && ./check 20000

burgers3d:
	$(FEC_RUN) $(abspath examples/burgers3d/burgers3d.fe) > $(abspath examples/burgers3d/burgers3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/burgers3d/burgers3d.egi) \
	  > $(abspath examples/burgers3d/burgers3d.fmr)
	cd examples/burgers3d && $(FORMURA) burgers3d.fmr
	cd examples/burgers3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check burgers_check.c burgers3d.c -lm
	cd examples/burgers3d && ./check

cahnhilliard3d:
	$(FEC_RUN) $(abspath examples/cahnhilliard3d/cahnhilliard3d.fe) > $(abspath examples/cahnhilliard3d/cahnhilliard3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/cahnhilliard3d/cahnhilliard3d.egi) \
	  > $(abspath examples/cahnhilliard3d/cahnhilliard3d.fmr)
	cd examples/cahnhilliard3d && $(FORMURA) cahnhilliard3d.fmr
	cd examples/cahnhilliard3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check ch_check.c cahnhilliard3d.c -lm
	cd examples/cahnhilliard3d && ./check

tdgl3d:
	$(FEC_RUN) $(abspath examples/tdgl3d/tdgl3d.fe) > $(abspath examples/tdgl3d/tdgl3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/tdgl3d/tdgl3d.egi) \
	  > $(abspath examples/tdgl3d/tdgl3d.fmr)
	cd examples/tdgl3d && $(FORMURA) tdgl3d.fmr
	cd examples/tdgl3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check tdgl_check.c tdgl3d.c -lm
	cd examples/tdgl3d && ./check

mhd-ot:
	$(EGISON_RUN) -l $(FMRGEN) $(abspath examples/mhd_ot/mhd_ot.egi) \
	  > $(abspath examples/mhd_ot/mhd_ot.fmr)
	cd examples/mhd_ot && $(FORMURA) mhd_ot.fmr
	cd examples/mhd_ot && $(CC) $(CFLAGS) -I$(MPISTUB) -o check mhd_check.c mhd_ot.c -lm
	cd examples/mhd_ot && ./check

elastic3d:
	$(FEC_RUN) $(abspath examples/elastic3d/elastic3d.fe) > $(abspath examples/elastic3d/elastic3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/elastic3d/elastic3d.egi) \
	  > $(abspath examples/elastic3d/elastic3d.fmr)
	cd examples/elastic3d && $(FORMURA) elastic3d.fmr
	cd examples/elastic3d && $(CC) $(CFLAGS) -I$(MPISTUB) -o check elastic_check.c elastic3d.c -lm
	cd examples/elastic3d && ./check

metric-torus:
	$(FEC_RUN) $(abspath examples/metric_torus/metric_torus.fe) > $(abspath examples/metric_torus/metric_torus.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/metric_torus/metric_torus.egi) \
	  > $(abspath examples/metric_torus/metric_torus.fmr)
	cd examples/metric_torus && $(FORMURA) metric_torus.fmr
	cd examples/metric_torus && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check metric_check.c metric_torus.c -lm
	cd examples/metric_torus && ./check

kleingordon:
	$(FEC_RUN) $(abspath examples/kleingordon/kleingordon.fe) > $(abspath examples/kleingordon/kleingordon.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/kleingordon/kleingordon.egi) \
	  > $(abspath examples/kleingordon/kleingordon.fmr)
	cd examples/kleingordon && $(FORMURA) kleingordon.fmr
	cd examples/kleingordon && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check kg_check.c kleingordon.c -lm
	cd examples/kleingordon && ./check

shallowwater:
	$(FEC_RUN) $(abspath examples/shallowwater/shallowwater.fe) > $(abspath examples/shallowwater/shallowwater.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/shallowwater/shallowwater.egi) \
	  > $(abspath examples/shallowwater/shallowwater.fmr)
	cd examples/shallowwater && $(FORMURA) shallowwater.fmr
	cd examples/shallowwater && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check sw_check.c shallowwater.c -lm
	cd examples/shallowwater && ./check

lbm-d3q19:
	$(EGISON_RUN) -l $(FMRGEN) $(abspath examples/lbm_d3q19/lbm_d3q19.egi) \
	  > $(abspath examples/lbm_d3q19/lbm_d3q19.fmr)
	cd examples/lbm_d3q19 && $(FORMURA) lbm_d3q19.fmr
	cd examples/lbm_d3q19 && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check lbm_check.c lbm_d3q19.c -lm
	cd examples/lbm_d3q19 && ./check

acoustic3d:
	$(EGISON_RUN) -l $(FMRGEN) $(abspath examples/acoustic3d/acoustic3d.egi) \
	  > $(abspath examples/acoustic3d/acoustic3d.fmr)
	cd examples/acoustic3d && $(FORMURA) acoustic3d.fmr
	cd examples/acoustic3d && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check ac_check.c acoustic3d.c -lm
	cd examples/acoustic3d && ./check

euler-sod:
	$(FEC_RUN) $(abspath examples/euler_sod/euler_sod.fe) > $(abspath examples/euler_sod/euler_sod.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/euler_sod/euler_sod.egi) \
	  > $(abspath examples/euler_sod/euler_sod.fmr)
	cd examples/euler_sod && $(FORMURA) euler_sod.fmr
	cd examples/euler_sod && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check sod_check.c euler_sod.c -lm
	cd examples/euler_sod && ./check

ks3d:
	$(FEC_RUN) $(abspath examples/ks3d/ks3d.fe) > $(abspath examples/ks3d/ks3d.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/ks3d/ks3d.egi) \
	  > $(abspath examples/ks3d/ks3d.fmr)
	cd examples/ks3d && $(FORMURA) ks3d.fmr
	cd examples/ks3d && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check ks_check.c ks3d.c -lm
	cd examples/ks3d && ./check

highorder4:
	$(FEC_RUN) $(abspath examples/highorder4/highorder4.fe) > $(abspath examples/highorder4/highorder4.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/highorder4/highorder4.egi) \
	  > $(abspath examples/highorder4/highorder4.fmr)
	cd examples/highorder4 && $(FORMURA) highorder4.fmr
	cd examples/highorder4 && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check hi4_check.c highorder4.c -lm
	cd examples/highorder4 && ./check

dirichlet-diffusion:
	$(FEC_RUN) $(abspath examples/dirichlet_diffusion/dirichlet_diffusion.fe) > $(abspath examples/dirichlet_diffusion/dirichlet_diffusion.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/dirichlet_diffusion/dirichlet_diffusion.egi) \
	  > $(abspath examples/dirichlet_diffusion/dirichlet_diffusion.fmr)
	cd examples/dirichlet_diffusion && $(FORMURA) dirichlet_diffusion.fmr
	cd examples/dirichlet_diffusion && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check dirichlet_check.c dirichlet_diffusion.c -lm
	cd examples/dirichlet_diffusion && ./check

maxwell-dec:
	$(FEC_RUN) $(abspath examples/maxwell_dec/maxwell_dec.fe) > $(abspath examples/maxwell_dec/maxwell_dec.egi)
	$(EGISON_RUN) -l $(FMRGEN) -l $(FMRDSL) $(abspath examples/maxwell_dec/maxwell_dec.egi) \
	  > $(abspath examples/maxwell_dec/maxwell_dec.fmr)
	cd examples/maxwell_dec && $(FORMURA) maxwell_dec.fmr
	cd examples/maxwell_dec && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check dec_check.c maxwell_dec.c -lm
	cd examples/maxwell_dec && ./check

clean:
	rm -f examples/*/check examples/*/*.o examples/*/run
	rm -f examples/diffusion3d/diffusion3d.c examples/diffusion3d/diffusion3d.h
	rm -f examples/maxwell3d/maxwell3d.c examples/maxwell3d/maxwell3d.h
	rm -f examples/maxwell3d_yee/maxwell3d_yee.c examples/maxwell3d_yee/maxwell3d_yee.h
	rm -f examples/pearson3d/pearson3d.c examples/pearson3d/pearson3d.h
	rm -f examples/pearson3d/pearson_V.pgm
	rm -f examples/mhd_ot/mhd_ot.c examples/mhd_ot/mhd_ot.h
	rm -f examples/tdgl3d/tdgl3d.c examples/tdgl3d/tdgl3d.h
	rm -f examples/cahnhilliard3d/cahnhilliard3d.c examples/cahnhilliard3d/cahnhilliard3d.h
	rm -f examples/burgers3d/burgers3d.c examples/burgers3d/burgers3d.h
	rm -f examples/elastic3d/elastic3d.c examples/elastic3d/elastic3d.h
	rm -f examples/metric_torus/metric_torus.c examples/metric_torus/metric_torus.h
	rm -f examples/kleingordon/kleingordon.c examples/kleingordon/kleingordon.h
	rm -f examples/shallowwater/shallowwater.c examples/shallowwater/shallowwater.h
	rm -f examples/lbm_d3q19/lbm_d3q19.c examples/lbm_d3q19/lbm_d3q19.h
	rm -f examples/acoustic3d/acoustic3d.c examples/acoustic3d/acoustic3d.h
	rm -f examples/euler_sod/euler_sod.c examples/euler_sod/euler_sod.h
	rm -f examples/ks3d/ks3d.c examples/ks3d/ks3d.h
	rm -f examples/highorder4/highorder4.c examples/highorder4/highorder4.h
	rm -f examples/dirichlet_diffusion/dirichlet_diffusion.c examples/dirichlet_diffusion/dirichlet_diffusion.h
	rm -f examples/maxwell_dec/maxwell_dec.c examples/maxwell_dec/maxwell_dec.h
