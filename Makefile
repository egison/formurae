# Egison -> Formura -> C -> run, end to end.
#
#   make setup        : fetch + patch + build Formura (vendor/, bin/formura)
#   cabal build       : build the Formurae compiler (fec)
#   make <example>    : .fe -> fec -> Egison -> Formura -> cc -> check
#   make all          : every example (each check exits nonzero on failure)
#   make fec-tensor-tests : compiler regression tests for indexed tensor exprs
#
# The Egison interpreter must be the development tree (the installed
# binary ships an older math library); set EGISON_DIR accordingly.

EGISON_DIR ?= $(abspath ../egison)
FORMURA    ?= $(abspath bin/formura)
MPISTUB    := $(abspath mpistub)
FMRGEN     := $(abspath lib/fmrgen.egi)
FMRLEGACY3 := $(abspath lib/fmrlegacy3d.egi)

CC      ?= cc
CFLAGS  ?= -O2 -std=c11

FEC_RUN    = cabal run -v0 fec --
EGISON_RUN = cd $(EGISON_DIR) && cabal run -v0 egison --

# ---------------------------------------------------------------- examples
#
# FE_EXAMPLES: written in Formurae (.fe) (dir = base name; the
# recipe compiles .fe -> .egi -> .fmr -> C and runs the check driver).
# EGI_EXAMPLES: still written directly in the embedded Egison form
# (staggered families / indexed families / custom helpers pending
# .fe support).

FE_EXAMPLES  := diffusion1d diffusion2d divergence2d diffusion3d maxwell3d maxwell_dec kleingordon ks3d \
                burgers3d pearson3d cahnhilliard3d tdgl3d shallowwater \
                euler_sod highorder4 dirichlet_diffusion elastic3d \
                metric_torus metric_sphere hyperbolic polar2d spherical3d
EGI_EXAMPLES := maxwell3d_yee mhd_ot lbm_d3q19 acoustic3d

CHECK_diffusion1d         := diffusion1d_check.c
CHECK_diffusion2d         := diffusion2d_check.c
CHECK_divergence2d        := divergence2d_check.c
CHECK_diffusion3d         := main_check.c
CHECK_maxwell3d           := maxwell_check.c
CHECK_maxwell_dec         := dec_check.c
CHECK_kleingordon         := kg_check.c
CHECK_ks3d                := ks_check.c
CHECK_burgers3d           := burgers_check.c
CHECK_pearson3d           := pearson_check.c
CHECK_cahnhilliard3d      := ch_check.c
CHECK_tdgl3d              := tdgl_check.c
CHECK_shallowwater        := sw_check.c
CHECK_euler_sod           := sod_check.c
CHECK_highorder4          := hi4_check.c
CHECK_dirichlet_diffusion := dirichlet_check.c
CHECK_elastic3d           := elastic_check.c
CHECK_metric_torus        := metric_check.c
CHECK_metric_sphere       := sphere_check.c
CHECK_hyperbolic          := hyp_check.c
CHECK_polar2d             := polar_check.c
CHECK_spherical3d         := spherical_check.c
CHECK_maxwell3d_yee       := maxwell_yee_check.c
CHECK_mhd_ot              := mhd_check.c
CHECK_lbm_d3q19           := lbm_check.c
CHECK_acoustic3d          := ac_check.c

RUNARGS_pearson3d := 20000

# legacy dashed target names
ALIASES := maxwell3d-yee:maxwell3d_yee mhd-ot:mhd_ot lbm-d3q19:lbm_d3q19 \
           euler-sod:euler_sod metric-torus:metric_torus \
           metric-sphere:metric_sphere dirichlet-diffusion:dirichlet_diffusion \
           maxwell-dec:maxwell_dec

# ----------------------------------------------------------------- recipes

define BUILD_AND_CHECK
	cd examples/$(1) && $(FORMURA) $(1).fmr
	cd examples/$(1) && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check $(CHECK_$(1)) $(1).c -lm
	cd examples/$(1) && ./check $(RUNARGS_$(1))
endef

define FE_RULE
$(1):
	$$(FEC_RUN) $$(abspath examples/$(1)/$(1).fe) > $$(abspath examples/$(1)/$(1).egi)
	$$(EGISON_RUN) -l $$(FMRGEN) $$(abspath examples/$(1)/$(1).egi) \
	  > $$(abspath examples/$(1)/$(1).fmr)
	$$(call BUILD_AND_CHECK,$(1))
endef

define EGI_RULE
$(1):
	$$(EGISON_RUN) -l $$(FMRGEN) -l $$(FMRLEGACY3) $$(abspath examples/$(1)/$(1).egi) \
	  > $$(abspath examples/$(1)/$(1).fmr)
	$$(call BUILD_AND_CHECK,$(1))
endef

$(foreach e,$(FE_EXAMPLES),$(eval $(call FE_RULE,$(e))))
$(foreach e,$(EGI_EXAMPLES),$(eval $(call EGI_RULE,$(e))))
$(foreach a,$(ALIASES),$(eval $(word 1,$(subst :, ,$(a))): $(word 2,$(subst :, ,$(a)))))

.PHONY: all setup clean fec-tensor-tests $(FE_EXAMPLES) $(EGI_EXAMPLES) \
        $(foreach a,$(ALIASES),$(word 1,$(subst :, ,$(a))))

all: $(FE_EXAMPLES) $(EGI_EXAMPLES)

fec-tensor-tests:
	sh tests/fec_tensor_expr.sh

setup:
	./setup.sh

clean:
	rm -f examples/*/check examples/*/*.o examples/*/run examples/*/viz
	rm -f $(foreach e,$(FE_EXAMPLES) $(EGI_EXAMPLES),examples/$(e)/$(e).c examples/$(e)/$(e).h)
	rm -f examples/pearson3d/pearson_V.pgm examples/mhd_ot/mhd_rho.pgm
