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
#   ninja        (brew install ninja)
#   Xcode with visionOS SDK
#
# depot_tools must be in PATH when invoking make.
#
# BUILD STEPS (performed by this Makefile):
#   1. Write a .gclient spec and run gclient sync --no-history --shallow
#      This runs post-sync hooks including tools/clang/scripts/update.py
#      which downloads Chromium's bundled clang toolchain.  That toolchain
#      is required to supply libclang_rt.ios.a (used when linking ANGLE
#      object files targeting iOS/visionOS ABI).
#      SSL_CERT_FILE=/etc/ssl/cert.pem is passed so Python's urllib can
#      validate the download URL on macOS where the system cert bundle is
#      not in Python's default search path.
#   2. Write args.gn:
#      - target_os="ios"  (chromium/6611 BUILDCONFIG.gn predates "xros")
#      - ios_sdk_name="xros" so xcrun selects the visionOS SDK
#      - enable_rust=false: prevents build/config/rust.gni from reading
#        third_party/rust-toolchain/VERSION (only populated by the Rust
#        hook, which we intentionally do not run).
#      - angle_build_tests=false: avoids the testing → rust GN import
#        chain and dramatically speeds up the build.
#      - use_custom_libcxx=false: use the system libc++ from the visionOS SDK
#        rather than Chromium's bundled copy.
#   3. gn gen out/Release
#   4. ninja angle libEGL libGLESv2
#   5. Install headers and framework bundles into PREFIX

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
	# SSL_CERT_FILE: Python's urllib does not use the macOS system keychain;
	# /etc/ssl/cert.pem is the system trust store symlink on macOS and lets
	# the Chromium clang download script validate HTTPS certificates.
	cd $(PLATFORM) && SSL_CERT_FILE=/etc/ssl/cert.pem gclient sync --no-history --shallow
	touch $@

.configured-$(PLATFORM): .cloned-$(PLATFORM)
	mkdir -p $(ANGLE_SRC)/out/Release
	# Write args.gn directly to avoid shell quoting issues with gn --args.
	# - ios_sdk_name="xros": lets ios_sdk.gni run "xcrun --sdk xros" so
	#   all ios_sdk_* variables (including ios_platform_build) are populated.
	# - enable_rust=false: ANGLE's BUILD.gn imports testing infrastructure
	#   which imports build/config/rust.gni; that file reads
	#   third_party/rust-toolchain/VERSION (only fetched by the Rust hook,
	#   which we do not run).  Setting enable_rust=false short-circuits the
	#   entire rust dependency chain at GN level.
	# - angle_build_tests=false: avoids the testing/test.gni → rust path
	#   and speeds up the build considerably.
	# - use_custom_libcxx=false: use the system libc++ from Xcode rather than
	#   Chromium's bundled copy.
	printf '%s\n' \
	  'is_debug = false' \
	  'target_os = "ios"' \
	  'target_cpu = "arm64"' \
	  'target_platform = "iphoneos"' \
	  'target_environment = "device"' \
	  'ios_sdk_name = "xros"' \
	  'angle_enable_metal = true' \
	  'angle_enable_gl = false' \
	  'is_component_build = false' \
	  'enable_rust = false' \
	  'angle_build_tests = false' \
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
	# ANGLE's GN build system predates visionOS support and tags the resulting
	# dylibs as platform IOS even when ios_sdk_name="xros" is set.  Re-tag both
	# frameworks as VISIONOS so the linker does not reject them when building
	# other targets (e.g. udfread's Meson pread function-detection link test)
	# for the xros target.  vtool invalidates the existing code signature, so
	# we re-sign with an ad-hoc signature immediately after.
	SDK_VERSION=$$(xcrun --sdk xros --show-sdk-version); \
	vtool -set-build-version visionos 1.0 $${SDK_VERSION} -replace \
	      -output $(PREFIX)/Frameworks/libEGL.framework/libEGL \
	              $(PREFIX)/Frameworks/libEGL.framework/libEGL; \
	codesign -f -s - $(PREFIX)/Frameworks/libEGL.framework/libEGL; \
	vtool -set-build-version visionos 1.0 $${SDK_VERSION} -replace \
	      -output $(PREFIX)/Frameworks/libGLESv2.framework/libGLESv2 \
	              $(PREFIX)/Frameworks/libGLESv2.framework/libGLESv2; \
	codesign -f -s - $(PREFIX)/Frameworks/libGLESv2.framework/libGLESv2
	touch $@

clean:
	rm -rf $(PLATFORM)
	rm -f .installed-$(PLATFORM) .configured-$(PLATFORM) .cloned-$(PLATFORM)

distclean:
	rm -rf $(PLATFORM) .installed-$(PLATFORM) .configured-$(PLATFORM) .cloned-$(PLATFORM)
