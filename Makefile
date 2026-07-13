# Egison -> Formura -> C -> run, end to end.
#
#   make setup        : fetch + patch + build Formura (vendor/, bin/formura)
#   cabal build       : build the Formurae compilers (pre-fec and post-fec)
#   make <example>    : .fme -> pre-fec -> Egison -> FEIR -> post-fec -> Formura -> cc -> check
#   make all          : every example (each check exits nonzero on failure)
#   make compiler-tests : FEIR/pre/Egison/post focused and vertical tests
#   make formurae-tensor-tests : shared Egison tensor/geometry library tests
#
# The Egison interpreter must be the development tree (the installed
# binary ships an older math library); set EGISON_DIR accordingly.

EGISON_DIR ?= $(abspath ../egison)
FORMURA    ?= $(abspath bin/formura)
MPISTUB    := $(abspath mpistub)
FMRGEN     := $(abspath lib/fmrgen.egi)
FETENSOR   := $(abspath lib/formurae-tensor.egi)
FEGEOMETRY := $(abspath lib/formurae-geometry.egi)
FMRDIRECT3 := $(abspath lib/fmr-direct3d.egi)

CC      ?= cc
CFLAGS  ?= -O2 -std=c11

PRE_FEC_RUN  = cabal run -v0 pre-fec --
POST_FEC_RUN = cabal run -v0 post-fec --
EGISON_RUN = cd $(EGISON_DIR) && cabal run -v0 egison --
EGISON_STRICT = $(abspath tools/run_egison_machine.sh) $(EGISON_DIR)
EGISON_NORMALIZE = $(abspath tools/run_formurae_normalization.sh) $(EGISON_DIR)

# ---------------------------------------------------------------- examples
#
# FME_EXAMPLES: written in Formurae (.fme) (dir = base name; the
# recipe compiles .fme -> .egi -> .feir -> .fmr -> C and runs the check driver).
# EGI_EXAMPLES: intentionally remain direct embedded-Egison samples outside
# the Formurae/FEIR compiler scope.

FME_EXAMPLES := acoustic3d diffusion1d diffusion2d divergence2d diffusion3d maxwell3d maxwell3d_yee maxwell_dec kleingordon ks3d \
                burgers3d pearson3d cahnhilliard3d tdgl3d shallowwater \
                euler_sod highorder4 dirichlet_diffusion elastic3d \
                metric_torus metric_sphere hyperbolic polar2d spherical3d
EGI_EXAMPLES := mhd_ot lbm_d3q19

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

# ----------------------------------------------------------------- recipes

define BUILD_AND_CHECK
	cd examples/$(1) && $(FORMURA) $(1).fmr
	cd examples/$(1) && $(CC) $(CFLAGS) -I. -I$(MPISTUB) -o check $(CHECK_$(1)) $(1).c -lm
	cd examples/$(1) && ./check $(RUNARGS_$(1))
endef

define FME_RULE
$(1):
	$$(PRE_FEC_RUN) examples/$(1)/$(1).fme > examples/$(1)/$(1).egi
	$$(EGISON_NORMALIZE) $$(abspath examples/$(1)/$(1).egi) \
	  > examples/$(1)/$(1).feir
	$$(POST_FEC_RUN) examples/$(1)/$(1).feir > examples/$(1)/$(1).fmr
	$$(call BUILD_AND_CHECK,$(1))
endef

define EGI_RULE
$(1):
	$$(EGISON_RUN) -l $$(FMRGEN) -l $$(FMRDIRECT3) $$(abspath examples/$(1)/$(1).egi) \
	  > $$(abspath examples/$(1)/$(1).fmr)
	$$(call BUILD_AND_CHECK,$(1))
endef

$(foreach e,$(FME_EXAMPLES),$(eval $(call FME_RULE,$(e))))
$(foreach e,$(EGI_EXAMPLES),$(eval $(call EGI_RULE,$(e))))

.PHONY: all setup clean compiler-tests formurae-geometry-tests formurae-tensor-tests formurae-operator-tests $(FME_EXAMPLES) $(EGI_EXAMPLES)

all: $(FME_EXAMPLES) $(EGI_EXAMPLES)

compiler-tests:
	sh tests/compiler_suite.sh

formurae-tensor-tests:
	$(EGISON_STRICT) -t -l $(FETENSOR) $(abspath tests/formurae_tensor_lib.egi)

formurae-geometry-tests: formurae-tensor-tests
	$(EGISON_STRICT) -t -l $(FETENSOR) -l $(FEGEOMETRY) $(abspath tests/formurae_geometry_lib.egi)

formurae-operator-tests: formurae-geometry-tests
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_operators_lib.egi)
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_form_operators_lib.egi)
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_opaque_lib.egi)

setup:
	./setup.sh

clean:
	rm -f examples/*/check examples/*/*.o examples/*/run examples/*/viz
	rm -f $(foreach e,$(FME_EXAMPLES) $(EGI_EXAMPLES),examples/$(e)/$(e).c examples/$(e)/$(e).h)
	rm -f examples/pearson3d/pearson_V.pgm examples/mhd_ot/mhd_rho.pgm
