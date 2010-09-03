# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------


define haddock  # args: $1 = dir,  $2 = distdir

ifneq "$$($1_$2_DO_HADDOCK)" "NO"

ifeq "$$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE)" ""
$$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE = $1/$2/doc/html/$$($1_PACKAGE)/$$($1_PACKAGE).haddock
ALL_HADDOCK_FILES += $$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE)
else
$$(error Already got a haddock file for $$($1_PACKAGE))
endif

haddock: $$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE)

ifeq "$$(HADDOCK_DOCS)" "YES"
$(call all-target,$1_$2_haddock,html_$1)
endif

.PHONY: html_$1
html_$1 : $$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE)

$$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_DEPS = $$(foreach n,$$($1_$2_DEPS),$$($$n_HADDOCK_FILE) $$($$n_dist-install_v_LIB))

ifeq "$$(HSCOLOUR_SRCS)" "YES"
$1_$2_HADDOCK_FLAGS += --source-module=src/%{MODULE/./-}.html --source-entity=src/%{MODULE/./-}.html\#%{NAME}
endif

ifneq "$$(BINDIST)" "YES"
$$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE) : $$(INPLACE_BIN)/haddock$$(exeext) $$(GHC_CABAL_INPLACE) $$($1_$2_HS_SRCS) $$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_DEPS) | $$$$(dir $$$$@)/.
ifeq "$$(HSCOLOUR_SRCS)" "YES"
	"$$(GHC_CABAL_INPLACE)" hscolour $2 $1
endif
	"$$(TOP)/$$(INPLACE_BIN)/haddock" \
	  --odir="$1/$2/doc/html/$$($1_PACKAGE)" \
	  --no-tmp-comp-dir \
	  --dump-interface=$$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE) \
	  --html \
	  --title="$$($1_PACKAGE)-$$($1_$2_VERSION)$$(if $$(strip $$($1_$2_SYNOPSIS)),: $$(strip $$($1_$2_SYNOPSIS)),)" \
	  --prologue="$1/$2/haddock-prologue.txt" \
	  $$(foreach mod,$$($1_$2_HIDDEN_MODULES),--hide=$$(mod)) \
	  $$(foreach pkg,$$($1_$2_DEPS),$$(if $$($$(pkg)_HADDOCK_FILE),--read-interface=../$$(pkg)$$(comma)../$$(pkg)/src/%{MODULE/./-}.html\#%{NAME}$$(comma)$$($$(pkg)_HADDOCK_FILE))) \
	  $$(foreach opt,$$($1_$2_v_ALL_HC_OPTS),--optghc=$$(opt)) \
	  $$($1_$2_HADDOCK_FLAGS) $$($1_$2_HADDOCK_OPTS) \
	  $$($1_$2_HS_SRCS) \
	  $$($1_$2_EXTRA_HADDOCK_SRCS)

# --no-tmp-comp-dir above is important: it saves a few minutes in a
# validate.  This flag lets Haddock use the pre-compiled object files
# for the package rather than rebuilding the modules of the package in
# a temporary directory.  Haddock needs to build the package when it
# uses the Template Haskell or Annotations extensions, for example.

# Make the haddocking depend on the library .a file, to ensure
# that we wait until the library is fully build before we haddock it
$$($$($1_PACKAGE)_HADDOCK_FILE) : $$($1_$2_v_LIB)
endif

endif

endef

