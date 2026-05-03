-include ../../Makefile.include
include ANGLE-VERSION
DEPS = Makefile ANGLE-VERSION ../../download-files.include

ifeq ($(CROSS_COMPILING), yes)
  DEPS += ../../Makefile.include
  PYTHON = $(NATIVEPREFIX)/bin/python3
  CMAKE = $(NATIVEPREFIX)/bin/cmake
  NINJA = $(NATIVEPREFIX)/bin/ninja
else
  ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
  PREFIX ?= $(ROOT_DIR)/angle-install
  BASE_URL ?= https://mirrors.kodi.tv/build-deps/sources
  RETRIEVE_TOOL := curl
  RETRIEVE_TOOL_FLAGS := -LsS --create-dirs --retry 10 --retry-connrefused -o
  ARCHIVE_TOOL := tar
  ARCHIVE_TOOL_FLAGS := --strip-components=1 -xf
  ifeq ($(PLATFORM),)
    PLATFORM = native
    TARBALLS_LOCATION = $(ROOT_DIR)
    HASH_TOOL = sha512sum
    HASH_TOOL_FLAGS = -c --status
    CMAKE = cmake
    NINJA = ninja
  endif
endif

# ANGLE is configured with GN (Chromium build), but for cross-platform
# dependency purposes we build the standalone cmake-angle / gn wrapper.
# The actual gn/ninja invocation is documented below; the Makefile
# delegates to a helper script so the depends infrastructure can track
# the .installed sentinel file cleanly.
#
# PREREQUISITES (must be installed on the host build machine):
#   depot_tools  (adds `gn` and `ninja` to PATH)
#   Python 3
#   Xcode with visionOS SDK
#
# BUILD STEPS (performed by this Makefile):
#   1. Fetch ANGLE source via gclient from the pinned commit
#   2. Run gn gen with is_debug=false target_os="xros" target_cpu="arm64"
#   3. ninja angle libEGL libGLESv2
#   4. Install headers and .a/.dylib files into PREFIX

ANGLE_GN_ARGS := \
  is_debug=false \
  target_os=\"xros\" \
  target_cpu=\"arm64\" \
  angle_enable_metal=true \
  angle_enable_gl=false \
  angle_use_commit_id=false \
  is_component_build=false

LIBDYLIB_EGL  = $(PLATFORM)/out/Release/libEGL.a
LIBDYLIB_GLES = $(PLATFORM)/out/Release/libGLESv2.a

include ../../download-files.include
all: .installed-$(PLATFORM)

.configured-$(PLATFORM): $(DEPS) | $(TARBALLS_LOCATION)/$(ARCHIVE).$(HASH_TYPE)
	rm -rf $(PLATFORM)/*; mkdir -p $(PLATFORM)
	cd $(PLATFORM); $(ARCHIVE_TOOL) $(ARCHIVE_TOOL_FLAGS) $(TARBALLS_LOCATION)/$(ARCHIVE)
	cd $(PLATFORM); gn gen out/Release --args='$(ANGLE_GN_ARGS)'
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
	rm -f .installed-$(PLATFORM) .configured-$(PLATFORM)

distclean:
	rm -rf $(PLATFORM) .installed-$(PLATFORM) .configured-$(PLATFORM)
