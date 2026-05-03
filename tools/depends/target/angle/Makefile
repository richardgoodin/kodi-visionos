-include ../../Makefile.include
include ANGLE-VERSION
DEPS = Makefile ANGLE-VERSION

ifeq ($(CROSS_COMPILING), yes)
  DEPS += ../../Makefile.include
  PYTHON = $(NATIVEPREFIX)/bin/python3
  CMAKE = $(NATIVEPREFIX)/bin/cmake
  NINJA = $(NATIVEPREFIX)/bin/ninja
else
  ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
  PREFIX ?= $(ROOT_DIR)/angle-install
  ifeq ($(PLATFORM),)
    PLATFORM = native
    CMAKE = cmake
    NINJA = ninja
  endif
endif

# ANGLE is configured with GN (Chromium's meta-build system) and compiled
# with ninja.  Source is obtained via git clone so that hidden files (notably
# .gn, the build-root marker) are preserved — Googlesource .tar.gz archives
# strip dotfiles and break gn gen.
#
# PREREQUISITES (must be installed on the host build machine):
#   gn    (download from https://chrome-infra-packages.appspot.com/dl/gn/gn/mac-arm64/+/latest)
#   ninja (brew install ninja)
#   Xcode with visionOS SDK
#
# BUILD STEPS (performed by this Makefile):
#   1. git clone ANGLE at the pinned commit into $(PLATFORM)/
#   2. gn gen with is_debug=false target_os="xros" target_cpu="arm64"
#   3. ninja angle libEGL libGLESv2
#   4. Install headers and static libraries into PREFIX

ANGLE_GN_ARGS := \
  is_debug=false \
  target_os=\"xros\" \
  target_cpu=\"arm64\" \
  angle_enable_metal=true \
  angle_enable_gl=false \
  angle_use_commit_id=false \
  is_component_build=false

ANGLE_REPO = https://chromium.googlesource.com/angle/angle.git

# GN/ninja places static libraries under out/Release/obj/
LIBDYLIB_EGL  = $(PLATFORM)/out/Release/obj/libEGL.a
LIBDYLIB_GLES = $(PLATFORM)/out/Release/obj/libGLESv2.a

all: .installed-$(PLATFORM)

.cloned-$(PLATFORM): $(DEPS)
	rm -rf $(PLATFORM); \
	git clone --no-checkout $(ANGLE_REPO) $(PLATFORM) && \
	cd $(PLATFORM) && git checkout $(ANGLE_COMMIT)
	touch $@

.configured-$(PLATFORM): .cloned-$(PLATFORM)
	cd $(PLATFORM); gn gen out/Release "--args=$(ANGLE_GN_ARGS)"
	touch $@

$(LIBDYLIB_EGL): .configured-$(PLATFORM)
	cd $(PLATFORM); ninja -C out/Release angle libEGL libGLESv2

.installed-$(PLATFORM): $(LIBDYLIB_EGL)
	# Install headers
	mkdir -p $(PREFIX)/include/EGL $(PREFIX)/include/GLES2 $(PREFIX)/include/GLES3 $(PREFIX)/include/KHR
	cp -R $(PLATFORM)/include/EGL/   $(PREFIX)/include/EGL/
	cp -R $(PLATFORM)/include/GLES2/ $(PREFIX)/include/GLES2/
	cp -R $(PLATFORM)/include/GLES3/ $(PREFIX)/include/GLES3/
	cp -R $(PLATFORM)/include/KHR/   $(PREFIX)/include/KHR/
	# Install static libraries
	mkdir -p $(PREFIX)/lib
	cp $(PLATFORM)/out/Release/obj/libEGL.a   $(PREFIX)/lib/
	cp $(PLATFORM)/out/Release/obj/libGLESv2.a $(PREFIX)/lib/
	touch $@

clean:
	rm -rf $(PLATFORM)
	rm -f .installed-$(PLATFORM) .configured-$(PLATFORM) .cloned-$(PLATFORM)

distclean:
	rm -rf $(PLATFORM) .installed-$(PLATFORM) .configured-$(PLATFORM) .cloned-$(PLATFORM)
