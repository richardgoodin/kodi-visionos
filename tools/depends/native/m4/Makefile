include ../../Makefile.include M4-VERSION ../../download-files.include
PREFIX=$(NATIVEPREFIX)
PLATFORM=$(NATIVEPLATFORM)
DEPS = ../../Makefile.include M4-VERSION Makefile ../../download-files.include

# configuration settings
CONFIGURE=./configure --prefix=$(PREFIX)

# macOS 27 SDK (Xcode 27) declares pipe2()/dup3() for the first time.  With a
# 26.x deployment target they link as weak symbols that resolve to NULL on a
# 26.x host, and gnulib's rpl_pipe2 then jumps to address 0 the first time
# m4 spawns a process (esyscmd) -- "internal error detected ... Segmentation
# fault: 11" from aclocal.  Tell configure they are absent so gnulib keeps
# its pipe()/dup2() fallbacks.
ifeq ($(NATIVE_OS), osx)
  CONFIGURE += ac_cv_func_pipe2=no ac_cv_func_dup3=no
endif

LIBDYLIB=$(PLATFORM)/src/$(LIBNAME)

all: .installed-$(PLATFORM)

.configured-$(PLATFORM): $(DEPS) | $(TARBALLS_LOCATION)/$(ARCHIVE).$(HASH_TYPE)
	-rm -rf $(PLATFORM)/*; mkdir -p $(PLATFORM)
	cd $(PLATFORM); $(ARCHIVE_TOOL) $(ARCHIVE_TOOL_FLAGS) $(TARBALLS_LOCATION)/$(ARCHIVE)
	cd $(PLATFORM); $(CONFIGURE)
	touch $@

$(LIBDYLIB): .configured-$(PLATFORM)
	$(MAKE) -C $(PLATFORM)

.installed-$(PLATFORM): $(LIBDYLIB)
	$(MAKE) -C $(PLATFORM) install
	touch $@

clean:
	$(MAKE) -C $(PLATFORM) clean
	rm -f .installed-$(PLATFORM) .configured-$(PLATFORM)

distclean::
	rm -rf $(PLATFORM) .installed-$(PLATFORM) .configured-$(PLATFORM)
