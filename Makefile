# BANNERSTART
# - Copyright 2006-2008, Galois, Inc.
# - This software is distributed under a standard, three-clause BSD license.
# - Please see the file LICENSE, distributed with this software, for specific
# - terms and conditions.
# Author: Adam Wick <awick@galois.com>
# BANNEREND
#

include autoconf.mk

RELEASE=1

.PHONY: all
all::

.PHONY: clean
clean::

.PHONY: mrproper
mrproper:: clean

.PHONY: install
install::

###############################################################################
# File Downloading
###############################################################################

$(GHC_FILE):
	$(CURL) -LO $(GHC_LINK)

$(CABAL_FILE):
	$(CURL) -LO $(CABAL_LINK)

mrproper::
	$(RM) -f $(GHC_FILE)
	$(RM) -f $(CABAL_FILE)

###############################################################################
# Platform GHC Preparation
###############################################################################

# We ship cabal, alex, happy, haddock, hscolour with the HaLVM environment,
# since they depend on 'unix' and other libraries halvm-ghc can't build. 
# (User might not have a preexisting Haskell ecosystem installed).
# A cabal sandbox is used to minimise the effect on the user's machine.
BUILDDIR := $(TOPDIR)/build
BUILDBOX := $(BUILDDIR)/sandbox
BUILDENV := PATH=$(TOPDIR)/platform_ghc/bin:$(BUILDBOX)/bin:$(PATH)

$(BUILDDIR):
	mkdir -p $@

clean::
	$(RM) -rf $(BUILDDIR)
	$(RM) -rf $(TOPDIR)/platform_ghc

mrproper::
	$(RM) -rf $(BUILDDIR)

# Prepare an ordinary version of GHC.
# We don't ship this - we just need it to build halvm-ghc etc.
PLATGHC := $(TOPDIR)/platform_ghc/bin/ghc

$(PLATGHC): $(GHC_FILE) | $(BUILDDIR) 
	$(TAR) jxf $(GHC_FILE) -C $(BUILDDIR)
	(cd $(BUILDDIR)/ghc* && ./configure --prefix=$(TOPDIR)/platform_ghc)
	$(MAKE) -C $(BUILDDIR)/ghc*/ install

mrproper::
	$(RM) -rf $(TOPDIR)/platform_ghc
	$(RM) $(HOME)/.ghc/$(ARCH)-linux-7.8.4

PLATCABAL := $(TOPDIR)/platform_ghc${halvmlibdir}/bin/cabal
$(PLATCABAL): $(CABAL_FILE) $(PLATGHC) | $(BUILDDIR) 
	$(TAR) zxf $(CABAL_FILE) -C $(BUILDDIR)
	# XXX Why is this necessary?
	$(RM) -rf ${HOME}/.ghc/${ARCH}-linux-7.8.4
	$(BUILDENV) && cd $(BUILDDIR)/cabal-install-$(CABAL_VERSION) && \
		PREFIX=${halvmlibdir} \
		./bootstrap.sh --no-doc --sandbox $(BUILDBOX)
	$(INSTALL) -D $(BUILDBOX)/bin/cabal $(PLATCABAL)

mrproper::
	$(RM) -rf $(TOPDIR)/platform_ghc

# `cabal update` stores package lists in ~/.cabal by default, even with sandbox.
# We override this with a config file to prevent unwanted build effects.
$(BUILDDIR)/cabal.config: $(PLATCABAL)
	echo "require-sandbox: True" >> $@
	echo "remote-repo: hackage.haskell.org:http://hackage.haskell.org/packages/archive" >> $@
	echo "remote-repo-cache: $(BUILDBOX)/packages" >> $@
	$(BUILDENV) && cd $(BUILDBOX) && \
		$(PLATCABAL) --config-file=$@ sandbox init --sandbox=$(BUILDBOX) && \
		$(PLATCABAL) --config-file=$@ update

# Force Cabal to use our config file
CABAL := $(PLATCABAL) --config-file="$(BUILDDIR)/cabal.config"

# Fetch sources for alex, happy, hscolour, haddock from Hackage.
# This produces targets $(ALEX_SRC) $(HAPPY_SRC) etc
define hackage-fetch
$2_SRC := $$(BUILDDIR)/$1-$3
$$($2_SRC): $$(PLATCABAL) | $$(BUILDDIR)
	$$(BUILDENV) && cd $$(BUILDDIR) && \
		$$(CABAL) fetch $1-$3 && \
		$$(CABAL) unpack $1-$3
endef
$(eval $(call hackage-fetch,alex,ALEX,$(ALEX_VERSION)))
$(eval $(call hackage-fetch,happy,HAPPY,$(HAPPY_VERSION)))
$(eval $(call hackage-fetch,haddock,HADDOCK,$(HADDOCK_VERSION)))
$(eval $(call hackage-fetch,hscolour,HSCOLOUR,$(HSCOLOUR_VERSION)))

# Build regular versions of alex and happy in our sandbox, for building GHC.
# We pass $(BUILDBOX)/bin via $(BUILDENV) while building GHC and libraries.
define hackage-sandbox-build
$1_BIN := $$(BUILDBOX)/bin/$2
$$($1_BIN): $$(PLATCABAL) | $$($1_SRC)
	$$(BUILDENV) && cd $$($1_SRC) && \
		$$(CABAL) sandbox init --sandbox $$(BUILDBOX) && \
                $$(CABAL) install --only-dep && \
                $$(CABAL) configure && \
                $$(CABAL) build && \
                $$(CABAL) copy
endef
$(eval $(call hackage-sandbox-build,ALEX,alex))
$(eval $(call hackage-sandbox-build,HAPPY,happy))
$(eval $(call hackage-sandbox-build,HSCOLOUR,HsColour))
$(eval $(call hackage-sandbox-build,HADDOCK,haddock))

# For each of the tools we distribute with the HaLVM, build static versions
# with the correct prefix burned in. This is only necessary because of
# cabal #462 https://github.com/haskell/cabal/issues/462.
# Without this, the built tools will only work on the builder's machine.
# Targets $(PLATALEX) $(PLATHSCOLOUR) etc will be created.
define hackage-static-build
PLAT$1 = $$(TOPDIR)/platform_ghc$${halvmlibdir}/bin/$2
$$(PLAT$1): $$(PLATCABAL) $$(BUILDDIR)/cabal.config $$($1_BIN)
	$$(BUILDENV) && cd $$($1_SRC) && \
		$$(CABAL) configure --prefix=$$(halvmlibdir) \
			--disable-shared --disable-executable-dynamic && \
		$$(CABAL) build && \
		$$(CABAL) copy --destdir=$$(TOPDIR)/platform_ghc
endef
$(eval $(call hackage-static-build,ALEX,alex))
$(eval $(call hackage-static-build,HAPPY,happy))
$(eval $(call hackage-static-build,HADDOCK,haddock))
$(eval $(call hackage-static-build,HSCOLOUR,HsColour))

# Require static and ordinary builds for each tool.
all:: $(PLATHAPPY) $(PLATHADDOCK) $(PLATHSCOLOUR) $(PLATALEX) 

###############################################################################
# Prepping / supporting the GHC build
################################################################################

# array.cabal is the witness for the presence of all GHC's libraries
$(TOPDIR)/halvm-ghc/libraries/array/array.cabal:
	(cd halvm-ghc && ./sync-all --no-dph -r http://darcs.haskell.org get)
	(cd halvm-ghc && ./sync-all checkout -t origin/ghc-7.8)

# Replace GHC's base with halvm-base.
# When NoIO.hs exists, we know this step has succeeded
$(TOPDIR)/halvm-ghc/libraries/base/GHC/Event/NoIO.hs: \
             $(TOPDIR)/halvm-ghc/libraries/array/array.cabal
	$(RM) -rf $(TOPDIR)/halvm-ghc/libraries/base
	$(GIT) clone $(GIT_LIB_URL)/halvm-base.git -b halvm halvm-ghc/libraries/base

$(TOPDIR)/halvm-ghc/libraries/base/ghc.mk: \
             $(TOPDIR)/halvm-ghc/libraries/base/GHC/Event/NoIO.hs \
			 $(TOPDIR)/halvm-ghc/mk/build.mk
	(cd halvm-ghc && ./boot)

# Link Xen headers into the HaLVM runtime include dir
$(TOPDIR)/halvm-ghc/rts/xen/include/xen:
	$(LN) -sf $(XEN_INCLUDE_DIR)/xen $(TOPDIR)/halvm-ghc/rts/xen/include/xen

# Link our custom build.mk - controls the GHC build, forces Stage1Only etc
$(TOPDIR)/halvm-ghc/mk/build.mk: $(TOPDIR)/src/misc/build.mk
	$(LN) -sf $(TOPDIR)/src/misc/build.mk $@

# Link HALVMCore into GHC's library path, where it will be found and built
# by the GHC build system.
$(TOPDIR)/halvm-ghc/libraries/HALVMCore: \
       $(TOPDIR)/halvm-ghc/libraries/array/array.cabal
	if [ ! -h $@ ]; then \
	  $(LN) -sf $(TOPDIR)/src/HALVMCore $@ ; \
	fi

# Link XenDevice into GHC's library path, where it will be found and built
# by the GHC build system.
$(TOPDIR)/halvm-ghc/libraries/XenDevice: \
       $(TOPDIR)/halvm-ghc/libraries/array/array.cabal
	if [ ! -h $@ ]; then \
	  $(LN) -sf $(TOPDIR)/src/XenDevice $@; \
	fi

# Replace libc headers with minlibc
$(TOPDIR)/halvm-ghc/libraries/base/libc-include: \
       $(TOPDIR)/halvm-ghc/libraries/base/GHC/Event/NoIO.hs
	if [ ! -h $@ ]; then \
	  $(LN) -sf $(TOPDIR)/halvm-ghc/rts/minlibc/include $@ ; \
	fi

GHC_PREPPED = $(TOPDIR)/halvm-ghc/libraries/base/GHC/Event/NoIO.hs \
              $(TOPDIR)/halvm-ghc/rts/xen/include/xen              \
              $(TOPDIR)/halvm-ghc/libraries/base/ghc.mk            \
              $(TOPDIR)/halvm-ghc/libraries/base/libc-include      \
              $(TOPDIR)/halvm-ghc/mk/build.mk                      \
              $(TOPDIR)/halvm-ghc/libraries/HALVMCore              \
              $(TOPDIR)/halvm-ghc/libraries/XenDevice
mrproper::
	$(RM) -f $(TOPDIR)/halvm-ghc/rts/xen/include/xen
	$(RM) -f $(TOPDIR)/halvm-ghc/mk/build.mk
	$(RM) -f $(TOPDIR)/halvm-ghc/libraries/HALVMCore
	$(RM) -f $(TOPDIR)/halvm-ghc/libraries/XenDevice
	$(RM) -f $(TOPDIR)/halvm-ghc/libraries/base/libc-include

###############################################################################
# GMP
################################################################################

ifeq ($(INTEGER_LIBRARY),integer-gmp)

$(TOPDIR)/src/gmp: | $(GHC_PREPPED)
	$(TAR) jxf $(TOPDIR)/halvm-ghc/libraries/integer-gmp/gmp/tarball/*.bz2
	$(MV) gmp-* $(TOPDIR)/src/gmp

$(TOPDIR)/halvm-ghc/libraries/integer-gmp/gmp/gmp.h: $(TOPDIR)/src/gmp/.libs/libgmp.a
	$(LN) -sf $(TOPDIR)/src/gmp/gmp.h $@

$(TOPDIR)/halvm-ghc/libraries/integer-gmp/cbits/gmp.h: $(TOPDIR)/src/gmp/.libs/libgmp.a
	$(LN) -sf $(TOPDIR)/src/gmp/gmp.h $@

$(TOPDIR)/halvm-ghc/libraries/integer-gmp/.patched.config.sub: $(TOPDIR)/src/misc/hsgmp.patch
	(cd halvm-ghc/libraries/integer-gmp && $(PATCH) -p1 < $(TOPDIR)/src/misc/hsgmp.patch)
	$(TOUCH) $@

$(TOPDIR)/src/gmp/Makefile: | $(TOPDIR)/src/gmp
	(cd src/gmp && ABI="$(ABI)" CFLAGS="$(CFLAGS)" \
	    ./configure --disable-shared --enable-static)

$(TOPDIR)/src/gmp/.libs/libgmp.a: $(TOPDIR)/src/gmp/Makefile
	$(MAKE) -C src/gmp

all:: $(TOPDIR)/src/gmp/.libs/libgmp.a

install:: $(TOPDIR)/src/gmp/.libs/libgmp.a
	$(INSTALL) -D $(TOPDIR)/src/gmp/.libs/libgmp.a $(DESTDIR)$(halvmlibdir)/rts-1.0/libgmp.a

clean::
	$(RM) -f $(TOPDIR)/halvm-ghc/libraries/integer-gmp/gmp/gmp.h
	$(RM) -f $(TOPDIR)/halvm-ghc/libraries/integer-gmp/cbits/gmp.h
	(cd $(TOPDIR)/halvm-ghc/libraries/integer-gmp && git reset --hard)

$(TOPDIR)/halvm-ghc/mk/config.mk: $(TOPDIR)/halvm-ghc/libraries/integer-gmp/gmp/gmp.h
$(TOPDIR)/halvm-ghc/mk/config.mk: $(TOPDIR)/halvm-ghc/libraries/integer-gmp/cbits/gmp.h
$(TOPDIR)/halvm-ghc/mk/config.mk: $(TOPDIR)/halvm-ghc/libraries/integer-gmp/.patched.config.sub
endif

clean::
	$(RM) -rf src/gmp

###############################################################################
# LibM
################################################################################

$(TOPDIR)/src/openlibm/libopenlibm.a: $(LIBM_O_FILES)
	$(MAKE) -C $(TOPDIR)/src/openlibm all

all:: $(TOPDIR)/src/openlibm/libopenlibm.a

clean::
	$(MAKE) -C $(TOPDIR)/src/openlibm clean

install:: $(TOPDIR)/src/openlibm/libopenlibm.a
	$(INSTALL) -D $(TOPDIR)/src/openlibm/libopenlibm.a \
	              $(DESTDIR)$(halvmlibdir)/rts-1.0/libopenlibm.a

###############################################################################
# LibIVC
###############################################################################

LIBIVC_C_FILES := $(shell find $(TOPDIR)/src/libIVC -name '*.c')
LIBIVC_HEADERS := $(shell find $(TOPDIR)/src/libIVC -name '*.h')
LIBIVC_O_FILES := $(LIBIVC_C_FILES:.c=.o)

$(LIBIVC_C_FILES:.c=.o): %.o: %.c $(LIBIVC_HEADERS)
	$(CC) -o $@ $(CFLAGS) -I$(TOPDIR)/src/libIVC -c $<

$(TOPDIR)/src/libIVC/libIVC.a: $(LIBIVC_O_FILES)
	$(AR) rcs $@ $(LIBIVC_O_FILES)

all:: $(TOPDIR)/src/libIVC/libIVC.a

clean::
	$(RM) -f $(LIBIVC_O_FILES) $(TOPDIR)/src/libIVC/libIVC.a

install:: $(TOPDIR)/src/libIVC/libIVC.a
	$(INSTALL) -D $(TOPDIR)/src/libIVC/libIVC.a $(DESTDIR)$(libdir)/libIVC.a
	$(INSTALL) -D $(TOPDIR)/src/libIVC/libIVC.h $(DESTDIR)$(incdir)/libIVC.h

###############################################################################
# convert-profile
###############################################################################

$(TOPDIR)/src/profiling/convert-profile: $(TOPDIR)/src/profiling/convert-profile.c
	$(CC) -O2 -o $@ $<

all:: $(TOPDIR)/src/profiling/convert-profile

clean::
	$(RM) -f $(TOPDIR)/src/profiling/convert-profile

install:: $(TOPDIR)/src/profiling/convert-profile
	$(INSTALL) -D $(TOPDIR)/src/profiling/convert-profile $(DESTDIR)$(bindir)/convert-profile

###############################################################################
# MK_REND_DIR
###############################################################################

MKREND_C_FILES := $(shell find $(TOPDIR)/src/mkrenddir -name '*.c')
MKREND_HEADERS := $(shell find $(TOPDIR)/src/mkrenddir -name '*.h')
MKREND_O_FILES := $(MKREND_C_FILES:.c=.o)

$(MKREND_C_FILES:.c=.o): %.o: %.c $(MKREND_HEADERS)
	$(CC) -o $@ $(CFLAGS) -c $<

$(TOPDIR)/src/mkrenddir/mkrenddir: $(MKREND_O_FILES)
	$(CC) -o $@ $^ $(LDFLAGS) -lxenstore

all:: $(TOPDIR)/src/mkrenddir/mkrenddir

clean::
	$(RM) -f $(MKREND_O_FILES) $(TOPDIR)/src/mkrenddir/mkrenddir

install:: $(TOPDIR)/src/mkrenddir/mkrenddir
	$(INSTALL) -D $(TOPDIR)/src/mkrenddir/mkrenddir $(DESTDIR)$(bindir)/mkrenddir

###############################################################################
# Boot loader
###############################################################################

$(TOPDIR)/src/bootloader/start.o: $(TOPDIR)/src/bootloader/start.$(ARCH).S    \
                                  $(wildcard $(TOPDIR)/src/bootloader/*.h)
	$(CC) -o $@ $(ASFLAGS) -I$(XEN_INCLUDE_DIR) -I$(TOPDIR)/src/bootloader -c $<

all:: $(TOPDIR)/src/bootloader/start.o

clean::
	rm -f $(TOPDIR)/src/bootloader/start.o

install::$(TOPDIR)/src/bootloader/start.o
	$(INSTALL) -D $(TOPDIR)/src/bootloader/start.o $(DESTDIR)$(halvmlibdir)/rts-1.0/start.o

###############################################################################
# The HaLVM!
###############################################################################

HALVM_GHC_CONFIGURE_FLAGS  = --target=$(TARGET_ARCH)
HALVM_GHC_CONFIGURE_FLAGS += --with-gcc=$(CC)
HALVM_GHC_CONFIGURE_FLAGS += --with-ld=$(LD)
HALVM_GHC_CONFIGURE_FLAGS += --with-nm=$(NM)
HALVM_GHC_CONFIGURE_FLAGS += --with-ar=$(AR)
HALVM_GHC_CONFIGURE_FLAGS += --with-objdump=$(OBJDUMP)
HALVM_GHC_CONFIGURE_FLAGS += --with-ranlib=$(RANLIB)
HALVM_GHC_CONFIGURE_FLAGS += --with-ghc=$(PLATGHC)
HALVM_GHC_CONFIGURE_FLAGS += --prefix=$(prefix)

$(TOPDIR)/halvm-ghc/mk/config.mk: $(GHC_PREPPED) $(PLATGHC) $(PLATALEX) \
                                  $(PLATHAPPY) $(PLATHADDOCK) $(PLATHAPPY)
	(cd halvm-ghc && \
	    $(BUILDENV) && ./configure $(HALVM_GHC_CONFIGURE_FLAGS))

# The GHC build system picks up everything linked into halvm-ghc/libraries
$(TOPDIR)/halvm-ghc/inplace/bin/ghc-stage1: $(TOPDIR)/halvm-ghc/mk/config.mk
	$(MAKE) -C halvm-ghc ghclibdir=$(halvmlibdir)

$(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts.a: $(TOPDIR)/halvm-ghc/mk/config.mk
	$(MAKE) -C halvm-ghc rts/dist/build/libHSrts.a ghclibdir=$(halvmlibdir)

$(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts_thr.a: $(TOPDIR)/halvm-ghc/mk/config.mk
	$(MAKE) -C halvm-ghc rts/dist/build/libHSrts_thr.a ghclibdir=$(halvmlibdir)

$(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts_p.a: $(TOPDIR)/halvm-ghc/mk/config.mk
	$(MAKE) -C halvm-ghc rts/dist/build/libHSrts_p.a ghclibdir=$(halvmlibdir)

all:: $(TOPDIR)/halvm-ghc/inplace/bin/ghc-stage1

all:: $(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts.a

all:: $(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts_thr.a

all:: $(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts_p.a

clean::
	$(MAKE) -C halvm-ghc clean

install::
	$(MAKE) -C halvm-ghc install ghclibdir=$(halvmlibdir) DESTDIR=$(DESTDIR)
	$(MKDIR) -p $(DESTDIR)$(halvmlibdir)/include/minlibc
	$(CP) -rf halvm-ghc/rts/minlibc/include/* $(DESTDIR)$(halvmlibdir)/include/minlibc
	$(SED) -i -e "s/^extra-ghci-libraries:/extra-ghci-libraries: minlibc/" \
	  $(DESTDIR)$(halvmlibdir)/package.conf.d/base*.conf

MINLIBC_SRCS      = $(wildcard $(TOPDIR)/halvm-ghc/rts/minlibc/*.c)
GHCI_MINLIBC_SRCS = $(filter-out %termios.c,$(MINLIBC_SRCS))
GHCI_MINLIBC_OBJS = $(patsubst $(TOPDIR)/halvm-ghc/rts/minlibc/%.c,           \
                               $(TOPDIR)/halvm-ghc/rts/dist/build/minlibc/%.o,\
                               $(GHCI_MINLIBC_SRCS))
GHCI_OBJS         = $(GHCI_MINLIBC_OBJS) $(TOPDIR)/src/misc/ghci_runtime.o
BASE_CABAL_FILE   = $(TOPDIR)/halvm-ghc/libraries/base/base.cabal
BASE_VERSION      = \
  $(shell grep "^version:" $(BASE_CABAL_FILE) | sed 's/^version:[ ]*//')

$(TOPDIR)/src/misc/ghci_runtime.o: $(TOPDIR)/src/misc/ghci_runtime.c
	$(CC) -c -o $@ $<

$(TOPDIR)/halvm-ghc/libminlibc.a:                                            \
         $(TOPDIR)/halvm-ghc/rts/dist/build/libHSrts.a                       \
		 $(TOPDIR)/src/misc/ghci_runtime.o
	$(AR) cr $@ $(GHCI_OBJS)

all:: $(TOPDIR)/halvm-ghc/libminlibc.a

install::
	$(INSTALL) -D $(TOPDIR)/halvm-ghc/libminlibc.a \
	              $(DESTDIR)$(halvmlibdir)/base-$(BASE_VERSION)/libminlibc.a

install:: $(TOPDIR)/src/scripts/halvm-cabal
	$(INSTALL) -D $(TOPDIR)/src/scripts/halvm-cabal $(DESTDIR)$(bindir)/halvm-cabal

install:: $(TOPDIR)/src/scripts/halvm-config
	$(INSTALL) -D $(TOPDIR)/src/scripts/halvm-cabal $(DESTDIR)$(bindir)/halvm-config

install:: $(TOPDIR)/src/scripts/halvm-ghc
	$(INSTALL) -D $(TOPDIR)/src/scripts/halvm-ghc $(DESTDIR)$(bindir)/halvm-ghc

install:: $(TOPDIR)/src/scripts/halvm-ghc-pkg
	$(INSTALL) -D $(TOPDIR)/src/scripts/halvm-ghc-pkg $(DESTDIR)$(bindir)/halvm-ghc-pkg

install:: $(TOPDIR)/src/scripts/ldkernel
	$(INSTALL) -D $(TOPDIR)/src/scripts/ldkernel $(DESTDIR)$(halvmlibdir)/ldkernel

install:: $(TOPDIR)/src/misc/kernel-$(ARCH).lds
	$(INSTALL) -D $(TOPDIR)/src/misc/kernel-$(ARCH).lds $(DESTDIR)$(halvmlibdir)/kernel.lds

install:: ${PLATGHC}
	$(INSTALL) -D $(shell $(PLATGHC) --print-libdir)/bin/hsc2hs $(DESTDIR)${halvmlibdir}/bin/hsc2hs.bin

# Need to be sure we grab datadirs for alex and happy, /usr/share w.r.t. their prefix
install:: $(PLATALEX) $(PLATCABAL) $(PLATHAPPY) $(PLATHADDOCK) $(PLATHSCOLOUR)
	mkdir -p $(DESTDIR)${halvmlibdir}
	cp -rf $(TOPDIR)/platform_ghc/${prefix}/* $(DESTDIR)${prefix}/

# hsc2hs requires a bunch of libraries to be installed. This is a hack (FIXME)
# to copy over the platform_ghc ones to our destination directory and hope
# nothing gets broken. Long term, finding some way to build a statically-linked
# hsc2hs would be better.
install::
	$(FIND) $(TOPDIR)/platform_ghc -name "*so" -name '*-ghc*' \
	    -exec cp '{}' $(DESTDIR)$(halvmlibdir)/lib/ \;
	$(INSTALL) -D $(TOPDIR)/src/scripts/hsc2hs $(DESTDIR)${halvmlibdir}/bin/hsc2hs

###############################################################################
# Packaging!
###############################################################################

FILELIST := $(filter-out $(TOPDIR)/HaLVM-$(HaLVM_VERSION),\
              $(filter-out $(TOPDIR)/rpmbuild,\
                $(wildcard $(TOPDIR)/* $(TOPDIR)/.git)))

SRC_TARBALL=HaLVM-$(HaLVM_VERSION).tar.gz

$(SRC_TARBALL):
	rm -rf $(TOPDIR)/HaLVM-${HaLVM_VERSION}
	mkdir -p $(TOPDIR)/HaLVM-${HaLVM_VERSION}
	cp -r $(FILELIST) $(TOPDIR)/HaLVM-${HaLVM_VERSION}/
	tar czf $@ HaLVM-${HaLVM_VERSION}/
	rm -rf $(TOPDIR)/HaLVM-${HaLVM_VERSION}

ifeq ($(PACKAGE_TARGET),RPM)
.PHONY: packages
packages: $(SRC_TARBALL)
	mkdir -p rpmbuild/{SOURCES,SPECS}
	cp $(SRC_TARBALL) $(TOPDIR)/rpmbuild/SOURCES/
	cp $(TOPDIR)/src/misc/HaLVM.spec $(TOPDIR)/rpmbuild/SPECS/HaLVM.spec
	mkdir -p packages
	rpmbuild -ba --define "_topdir $(TOPDIR)/rpmbuild" --define "_version $(HaLVM_VERSION)" --define "_release $(RELEASE)" $(TOPDIR)/rpmbuild/SPECS/HaLVM.spec
	rpmbuild -ba --with gmp --define "_topdir $(TOPDIR)/rpmbuild" --define "_version $(HaLVM_VERSION)" --define "_release $(RELEASE)" $(TOPDIR)/rpmbuild/SPECS/HaLVM.spec
	find rpmbuild -name "*.*rpm" -exec cp '{}' $(TOPDIR)/packages/ \;
endif

ifeq ($(PACKAGE_TARGET),deb)
DEB_ORIGSRC_TARBALL=halvm_$(HaLVM_VERSION).orig.tar.gz
DEB_CONFSRC_TARBALL=halvm_$(HaLVM_VERSION)-$(RELEASE).debian.tar.gz
DEB_DESC_FILE=halvm_$(HaLVM_VERSION)-$(RELEASE).dsc

DEBG_ORIGSRC_TARBALL=halvm-gmp_$(HaLVM_VERSION).orig.tar.gz
DEBG_CONFSRC_TARBALL=halvm-gmp_$(HaLVM_VERSION)-$(RELEASE).debian.tar.gz
DEBG_DESC_FILE=halvm-gmp_$(HaLVM_VERSION)-$(RELEASE).dsc

hash=openssl sha -$1 $2 | sed 's/.*= //g'
sha1=$(call hash,sha1,$1)
sha256=$(call hash,sha256,$1)
size=stat -c "%s" $1

.PHONY: packages
packages: $(DEB_ORIGSRC_TARBALL)  $(DEB_CONFSRC_TARBALL)  $(DEB_DESC_FILE) \
          $(DEBG_ORIGSRC_TARBALL) $(DEBG_CONFSRC_TARBALL) $(DEBG_DESC_FILE)
	rm -rf HaLVM-$(HaLVM_VERSION) halvm-$(HaLVM_VERSION)
	tar zxf $(DEB_ORIGSRC_TARBALL)
	mv HaLVM-$(HaLVM_VERSION) halvm-$(HaLVM_VERSION)
	tar zxf $(DEB_CONFSRC_TARBALL) -C halvm-$(HaLVM_VERSION)/
	(cd halvm-$(HaLVM_VERSION) && dpkg-buildpackage -rfakeroot -uc -us)
	tar zxf $(DEBG_ORIGSRC_TARBALL)
	tar zxf $(DEBG_CONFSRC_TARBALL) -C halvm-gmp-$(HaLVM_VERSION)/
	(cd halvm-gmp-$(HaLVM_VERSION) && dpkg-buildpackage -rfakeroot -uc -us)
	mkdir -p packages
	cp *.deb packages/
	cp *.dsc packages/
	cp *.changes packages/

$(DEB_ORIGSRC_TARBALL): $(SRC_TARBALL)
	cp $(SRC_TARBALL) $(DEB_ORIGSRC_TARBALL)

$(DEB_CONFSRC_TARBALL): $(shell find $(TOPDIR)/src/debian)
	rm -rf tmp
	mkdir tmp
	cp -r src/debian tmp/debian
	sed -ie 's/INTEGER_LIBRARY/simple/g' tmp/debian/rules
	sed -ie 's/VERSION/$(HaLVM_VERSION)/g' tmp/debian/changelog
	sed -ie 's/RELEASE/$(RELEASE)/g' tmp/debian/changelog
	tar cz -C tmp -f $@ debian/

$(DEB_DESC_FILE): $(DEB_ORIGSRC_TARBALL) $(DEB_CONFSRC_TARBALL)
	sed -e 's!ORIG_SHA1!'`$(call sha1,$(DEB_ORIGSRC_TARBALL))`'!g'     \
        -e 's!ORIG_SHA256!'`$(call sha256,$(DEB_ORIGSRC_TARBALL))`'!g' \
        -e 's!CONF_SHA256!'`$(call sha256,$(DEB_CONFSRC_TARBALL))`'!g' \
        -e 's!CONF_SHA1!'`$(call sha1,$(DEB_CONFSRC_TARBALL))`'!g' \
        -e 's!ORIG_SIZE!'`$(call size,$(DEB_ORIGSRC_TARBALL))`'!g' \
        -e 's!CONF_SIZE!'`$(call size,$(DEB_CONFSRC_TARBALL))`'!g' \
        -e 's!VERSION!$(HaLVM_VERSION)!g' \
        -e 's!RELEASE!$(RELEASE)!g' \
        src/misc/halvm.dsc > $(DEB_DESC_FILE)

$(DEBG_ORIGSRC_TARBALL): $(DEB_ORIGSRC_TARBALL)
	rm -rf tmp
	mkdir tmp
	tar zx -C tmp -f $(DEB_ORIGSRC_TARBALL)
	mv tmp/HaLVM-$(HaLVM_VERSION) tmp/halvm-gmp-$(HaLVM_VERSION)
	tar cz -C tmp -f $@ halvm-gmp-$(HaLVM_VERSION)
	rm -rf tmp

$(DEBG_CONFSRC_TARBALL): $(shell find $(TOPDIR)/src/debian)
	rm -rf tmp
	mkdir tmp
	cp -r src/debian tmp/debian
	sed -ie 's/halvm/halvm-gmp/g' tmp/debian/changelog
	sed -ie 's/ halvm/ halvm-gmp/g' tmp/debian/control
	sed -ie 's/INTEGER_LIBRARY/gmp/g' tmp/debian/rules
	sed -ie 's/VERSION/$(HaLVM_VERSION)/g' tmp/debian/changelog
	sed -ie 's/RELEASE/$(RELEASE)/g' tmp/debian/changelog
	tar cz -C tmp -f $@ debian/

$(DEBG_DESC_FILE): $(DEBG_ORIGSRC_TARBALL) $(DEBG_CONFSRC_TARBALL)
	sed -e 's!ORIG_SHA1!'`$(call sha1,$(DEB_ORIGSRC_TARBALL))`'!g'     \
        -e 's!ORIG_SHA256!'`$(call sha256,$(DEB_ORIGSRC_TARBALL))`'!g' \
        -e 's!CONF_SHA256!'`$(call sha256,$(DEB_CONFSRC_TARBALL))`'!g' \
        -e 's!CONF_SHA1!'`$(call sha1,$(DEB_CONFSRC_TARBALL))`'!g' \
        -e 's!ORIG_SIZE!'`$(call size,$(DEB_ORIGSRC_TARBALL))`'!g' \
        -e 's!CONF_SIZE!'`$(call size,$(DEB_CONFSRC_TARBALL))`'!g' \
        -e 's!VERSION!$(HaLVM_VERSION)!g' \
        -e 's!RELEASE!$(RELEASE)!g' \
         -e 's! halvm! halvm-gmp!g' \
        src/misc/halvm.dsc > $(DEB_DESC_FILE)

debclean:
	$(RM) -f $(SRC_TARBALL)
	$(RM) -f $(DEB_ORIGSRC_TARBALL) $(DEBG_ORIGSRC_TARBALL)
	$(RM) -f $(DEB_CONFSRC_TARBALL) $(DEBG_CONFSRC_TARBALL)
	$(RM) -f $(DEB_DESC_FILE) $(DEBG_DESC_FILE)
	$(RM) -rf HaLVM-$(HaLVM_VERSION)
	$(RM) -rf halvm-$(HaLVM_VERSION)
	$(RM) -rf halvm-gmp-$(HaLVM_VERSION)
	$(RM) -f *.deb *.changes

clean:: debclean
endif #ifeq deb
