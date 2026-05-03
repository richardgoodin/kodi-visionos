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
# with ninja.  Source is obtained via gclient so that hidden files (notably
# .gn, the build-root marker) and required sub-repos (build/, buildtools/)
# are present — a bare git clone is insufficient.
#
# PREREQUISITES (must be installed on the host build machine):
#   depot_tools  (cloned from https://chromium.googlesource.com/chromium/tools/depot_tools.git)
#   gn           (download from https://chrome-infra-packages.appspot.com/dl/gn/gn/mac-arm64/+/latest)
#   ninja        (brew install ninja)
#   Xcode with visionOS SDK
#
# depot_tools must be in PATH when invoking make.
#
# BUILD STEPS (performed by this Makefile):
#   1. Write a .gclient spec and run gclient sync --no-history --nohooks
#      to fetch ANGLE and its required sub-repos (build/, buildtools/, ...)
#   2. Write args.gn:
#      - target_os="ios"  (chromium/6611 BUILDCONFIG.gn predates "xros")
#      - ios_sdk_name="xros" so xcrun selects the visionOS SDK
#      - clang_use_chrome_lld=false + use_custom_libcxx=false to use
#        Xcode's system clang (gclient --nohooks skips clang download)
#   3. gn gen out/Release
#   4. ninja angle libEGL libGLESv2
#   5. Install headers and static libraries into PREFIX

ANGLE_REPO = https://chromium.googlesource.com/angle/angle.git

# gclient places the checkout in a subdirectory named 'angle'
ANGLE_SRC = $(PLATFORM)/angle

# GN/ninja produces frameworks under out/Release/
LIBDYLIB_EGL  = $(ANGLE_SRC)/out/Release/libEGL.framework/libEGL
LIBDYLIB_GLES = $(ANGLE_SRC)/out/Release/libGLESv2.framework/libGLESv2

all: .installed-$(PLATFORM)

.cloned-$(PLATFORM): $(DEPS)
	rm -rf $(PLATFORM); mkdir -p $(PLATFORM)
	echo "solutions = [{'name': 'angle', 'url': '$(ANGLE_REPO)@$(ANGLE_COMMIT)', 'deps_file': 'DEPS', 'managed': False, 'custom_deps': {}}]" \
	  > $(PLATFORM)/.gclient
	cd $(PLATFORM) && gclient sync --no-history --shallow
	touch $@

.configured-$(PLATFORM): .cloned-$(PLATFORM)
	mkdir -p $(ANGLE_SRC)/out/Release
	# Write args.gn directly to avoid shell quoting issues with gn --args.
	# - ios_sdk_name="xros": lets ios_sdk.gni run "xcrun --sdk xros" so
	#   all ios_sdk_* variables (including ios_platform_build) are populated.
	# - clang_use_chrome_lld=false + use_custom_libcxx=false: use Xcode's
	#   system clang; gclient --nohooks skips the Chromium clang download.
	printf '%s\n' \
	  'is_debug = false' \
	  'target_os = "ios"' \
	  'target_cpu = "arm64"' \
	  'target_platform = "iphoneos"' \
	  'target_environment = "device"' \
	  'ios_sdk_name = "xros"' \
	  'angle_enable_metal = true' \
	  'angle_enable_gl = false' \
	  'angle_use_commit_id = false' \
	  'is_component_build = false' \
	  'clang_use_chrome_lld = false' \
	  'use_custom_libcxx = false' \
	  'treat_warnings_as_errors = false' \
	  > $(ANGLE_SRC)/out/Release/args.gn
	cd $(ANGLE_SRC) && gn gen out/Release
	touch $@

$(LIBDYLIB_EGL): .configured-$(PLATFORM)
	cd $(ANGLE_SRC) && ninja -C out/Release angle libEGL libGLESv2

.installed-$(PLATFORM): $(LIBDYLIB_EGL)
	# Install headers
	mkdir -p $(PREFIX)/include/EGL $(PREFIX)/include/GLES2 $(PREFIX)/include/GLES3 $(PREFIX)/include/KHR
	cp -R $(ANGLE_SRC)/include/EGL/   $(PREFIX)/include/EGL/
	cp -R $(ANGLE_SRC)/include/GLES2/ $(PREFIX)/include/GLES2/
	cp -R $(ANGLE_SRC)/include/GLES3/ $(PREFIX)/include/GLES3/
	cp -R $(ANGLE_SRC)/include/KHR/   $(PREFIX)/include/KHR/
	# Install frameworks (ANGLE on Apple platforms produces .framework bundles)
	mkdir -p $(PREFIX)/Frameworks
	cp -R $(ANGLE_SRC)/out/Release/libEGL.framework    $(PREFIX)/Frameworks/
	cp -R $(ANGLE_SRC)/out/Release/libGLESv2.framework $(PREFIX)/Frameworks/
	touch $@

clean:
	rm -rf $(PLATFORM)
	rm -f .installed-$(PLATFORM) .configured-$(PLATFORM) .cloned-$(PLATFORM)

distclean:
	rm -rf $(PLATFORM) .installed-$(PLATFORM) .configured-$(PLATFORM) .cloned-$(PLATFORM)
