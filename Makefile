# Egison -> Formura -> C -> run, end to end.
#
#   make setup        : fetch + patch + build Formura (vendor/, bin/formura)
#   cabal build       : build the Formurae compilers (formurae-pre and formurae-post)
#   make <example>    : .fme -> formurae-pre -> Egison -> FEIR -> formurae-post -> Formura -> cc -> check
#   make all          : every example (each check exits nonzero on failure)
#   make yinyang_diffusion-long : standard Yin-Yang check, then its 3000-step regression
#   make compiler-tests : FEIR/pre/Egison/post focused and vertical tests
#   make formurae-tensor-tests : shared Egison tensor/geometry library tests
#
# Repository tests run the adjacent Egison tree through Cabal so compiler and
# library changes are tested together; set EGISON_DIR to override it.

EGISON_DIR ?= $(abspath ../egison)
FORMURA    ?= $(abspath bin/formura)
MPISTUB    := $(abspath mpistub)
FETENSOR   := $(abspath lib/formurae-tensor.egi)
FEGEOMETRY := $(abspath lib/formurae-geometry.egi)

CC      ?= cc
CFLAGS  ?= -O2 -std=c11

PRE_FEC_RUN  = cabal run -v0 -j1 formurae-pre --
POST_FEC_RUN = cabal run -v0 -j1 formurae-post --
EGISON_STRICT = $(abspath tools/run_egison_machine.sh) $(EGISON_DIR)
EGISON_NORMALIZE = $(abspath tools/run_formurae_normalization.sh) $(EGISON_DIR)

# ---------------------------------------------------------------- examples
#
# FME_EXAMPLES: written in Formurae (.fme) (dir = base name; the
# recipe compiles .fme -> .egi -> .feir -> .fmr -> C and runs the check driver).
FME_EXAMPLES := acoustic3d diffusion1d diffusion2d divergence2d diffusion3d maxwell3d maxwell3d_yee maxwell_dec kleingordon ks3d \
                burgers3d pearson3d cahnhilliard3d tdgl3d shallowwater \
                euler_sod highorder4 dirichlet_diffusion elastic3d \
                sbp_diffusion1d sbp_wave1d sbp_diffusion2d sbp_highorder4 \
                sbp_neumann sbp_wave_open \
                metric_torus metric_sphere hyperbolic polar2d spherical3d yinyang_diffusion mhd_ot lbm_d3q19

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
CHECK_sbp_diffusion1d     := sbp_check.c
CHECK_sbp_wave1d          := sbp_wave_check.c
CHECK_sbp_diffusion2d     := sbp2d_check.c
CHECK_sbp_highorder4      := sbp_hi4_check.c
CHECK_sbp_neumann         := sbp_nmn_check.c
CHECK_sbp_wave_open       := sbp_open_check.c
CHECK_elastic3d           := elastic_check.c
CHECK_metric_torus        := metric_check.c
CHECK_metric_sphere       := sphere_check.c
CHECK_hyperbolic          := hyp_check.c
CHECK_polar2d             := polar_check.c
CHECK_spherical3d         := spherical_check.c
CHECK_maxwell3d_yee       := maxwell_yee_check.c
CHECK_yinyang_diffusion   := yy_check.c
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

$(foreach e,$(FME_EXAMPLES),$(eval $(call FME_RULE,$(e))))

.PHONY: all setup clean compiler-tests formurae-geometry-tests formurae-tensor-tests formurae-operator-tests \
	gallery-assets yinyang_diffusion-long $(FME_EXAMPLES)

all: $(FME_EXAMPLES)

gallery-assets:
	./gallery/gen.sh
	python3 gallery/tools/render.py
	python3 gallery/tools/render_video.py

# Kept out of all: yy_check runs the global x/y/z eigenmodes, so the long
# regression is deliberately opt-in for local/CI endurance testing.
yinyang_diffusion-long: yinyang_diffusion
	cd examples/yinyang_diffusion && ./check 3000

compiler-tests:
	sh tests/compiler_suite.sh

formurae-tensor-tests:
	$(EGISON_STRICT) -t -l $(FETENSOR) $(abspath tests/formurae_tensor_lib.egi)

formurae-geometry-tests: formurae-tensor-tests
	$(EGISON_STRICT) -t -l $(FETENSOR) -l $(FEGEOMETRY) $(abspath tests/formurae_geometry_lib.egi)

formurae-operator-tests: formurae-geometry-tests
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_operators_lib.egi)
	sh tests/formurae_operator_errors.sh
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_form_operators_lib.egi)
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_form_operators_2d_lib.egi)
	$(EGISON_NORMALIZE) -t $(abspath tests/formurae_opaque_lib.egi)

setup:
	./setup.sh

clean:
	rm -f examples/*/check examples/*/*.o examples/*/run examples/*/viz
	rm -f $(foreach e,$(FME_EXAMPLES),examples/$(e)/$(e).c examples/$(e)/$(e).h)
	rm -f examples/pearson3d/pearson_V.pgm examples/mhd_ot/mhd_rho.pgm
