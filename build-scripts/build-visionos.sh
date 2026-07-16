#!/bin/bash
# build-visionos.sh
# Full pipeline: distclean → working Kodi.app for Apple visionOS.
#
# Prerequisites (must be installed before first run):
#   Xcode 16.0+          — xcodebuild -version
#   visionOS SDK 2.0+    — xcodebuild -showsdks | grep xros
#   ninja                — brew install ninja
#   Python 3.11+
#   autoconf / automake  — brew install autoconf automake
#
#   depot_tools (gclient + gn) are fetched automatically into
#   tools/depot_tools/ if not already present.
#
# Usage:
#   ./build-scripts/build-visionos.sh [options]
#
# Options:
#   --debug            Build Debug instead of Release
#   --jobs N           Parallel jobs (default: logical CPU count)
#   --skip-angle       Skip ANGLE fetch+build (reuse existing install)
#   --skip-depends     Skip Kodi depends bootstrap+build (reuse existing prefix)
#   --skip-cmake       Skip CMake configure (reuse existing Xcode project)
#   --clean-angle      rm -rf the ANGLE checkout+install before building ANGLE
#   --clean-depends    rm -rf the depends prefix before building depends
#   --clean-build      rm -rf the CMake build dir before configuring
#   -h|--help          Show this message

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KODI_DIR="$(dirname "$SCRIPT_DIR")"

DEPENDS_DIR="$KODI_DIR/tools/depends"
ANGLE_DEPENDS_DIR="$KODI_DIR/tools/depends/target/angle"
DEPOT_TOOLS_DIR="$KODI_DIR/tools/depot_tools"

# ANGLE installs into a sibling directory of its Makefile so we can keep it
# alongside the source checkout without polluting the depends prefix.
ANGLE_INSTALL="$ANGLE_DEPENDS_DIR/angle-install"
ANGLE_FRAMEWORKS_DIR="$ANGLE_INSTALL/Frameworks"

# Kodi depends installs here (matches what configure.ac generates).
DEPENDS_PREFIX="/Users/Shared/xbmc-depends"

# CMake build output.
BUILD_DIR="$KODI_DIR/kodi-build-visionos"

# ── Required versions ──────────────────────────────────────────────────────────
REQUIRED_XCODE_MAJOR=16

# ── Defaults ───────────────────────────────────────────────────────────────────
BUILD_TYPE="Release"
JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)
SKIP_ANGLE=0
SKIP_DEPENDS=0
SKIP_CMAKE=0
CLEAN_ANGLE=0
CLEAN_DEPENDS=0
CLEAN_BUILD=0

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)         BUILD_TYPE="Debug" ;;
    --jobs)          shift; JOBS="$1" ;;
    --skip-angle)    SKIP_ANGLE=1 ;;
    --skip-depends)  SKIP_DEPENDS=1 ;;
    --skip-cmake)    SKIP_CMAKE=1 ;;
    --clean-angle)   CLEAN_ANGLE=1 ;;
    --clean-depends) CLEAN_DEPENDS=1 ;;
    --clean-build)   CLEAN_BUILD=1 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,2\}//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Helpers ────────────────────────────────────────────────────────────────────
die() {
  echo "" >&2
  echo "✗ ERROR: $*" >&2
  exit 1
}
step() { echo ""; echo "━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
info() { echo "    $*"; }
ok()   { echo "  ✓ $*"; }

# ── Step 0: Prerequisites ──────────────────────────────────────────────────────
step "0/5  Checking prerequisites"

# Xcode
XCODE_VERSION=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}') \
  || die "xcodebuild not found. Install Xcode."
XCODE_MAJOR=$(echo "$XCODE_VERSION" | cut -d. -f1)
[[ "${XCODE_MAJOR:-0}" -ge "$REQUIRED_XCODE_MAJOR" ]] \
  || die "Xcode $REQUIRED_XCODE_MAJOR+ required; found $XCODE_VERSION"
ok "Xcode $XCODE_VERSION"

# visionOS SDK
SDK_PATH=$(xcrun --sdk xros --show-sdk-path 2>/dev/null) \
  || die "visionOS SDK not found. Install Xcode with visionOS platform support."
SDK_VERSION=$(xcrun --sdk xros --show-sdk-version 2>/dev/null)
ok "visionOS SDK $SDK_VERSION  ($SDK_PATH)"

# ninja (needed for ANGLE)
if [[ "$SKIP_ANGLE" -eq 0 ]]; then
  command -v ninja &>/dev/null \
    || die "'ninja' not found.  Run: brew install ninja"
  ok "ninja $(ninja --version 2>/dev/null || echo unknown)"
fi

# Python 3
PYTHON3=$(command -v python3 2>/dev/null) || die "python3 not found."
PYVER=$("$PYTHON3" --version 2>&1 | awk '{print $2}')
ok "Python $PYVER"

# autoconf / automake (needed for depends bootstrap)
if [[ "$SKIP_DEPENDS" -eq 0 ]]; then
  command -v autoconf &>/dev/null || die "'autoconf' not found.  Run: brew install autoconf"
  command -v automake &>/dev/null || die "'automake' not found.  Run: brew install automake"
  ok "autoconf $(autoconf --version 2>&1 | head -1)"
fi

# ── depot_tools (gclient + gn) — auto-clone if missing ──────────────────────
if [[ "$SKIP_ANGLE" -eq 0 ]]; then
  step "0b/5  depot_tools"
  if [[ ! -x "$DEPOT_TOOLS_DIR/gclient" ]]; then
    info "depot_tools not found at $DEPOT_TOOLS_DIR — cloning..."
    git clone --depth=1 \
      https://chromium.googlesource.com/chromium/tools/depot_tools.git \
      "$DEPOT_TOOLS_DIR"
    ok "depot_tools cloned."
  else
    ok "depot_tools already present: $DEPOT_TOOLS_DIR"
  fi

  # Prepend depot_tools to PATH for this script's duration.
  export PATH="$DEPOT_TOOLS_DIR:$PATH"

  # Sanity-check that gclient and gn are now reachable.
  command -v gclient &>/dev/null || die "gclient still not found after cloning depot_tools."
  command -v gn &>/dev/null \
    || die "gn not found. depot_tools should supply it; try running 'gclient' once to bootstrap it, then re-run this script."
  ok "gclient $(gclient --version 2>&1 | head -1 || echo ok)"
  ok "gn      $(gn --version 2>/dev/null || echo ok)"
fi

# ── Step 1: ANGLE ──────────────────────────────────────────────────────────────
#
# Isolation: tools/depends/Makefile.include is generated by whichever depends
# target was last configured.  If a macOS build ran previously it leaves behind
# settings such as
#   CROSS_COMPILING=yes
#   PLATFORM=macosx26.4_arm64-target-debug
#   PATH:=/Users/Shared/xbmc-depends/aarch64-darwin25.4.0-native/bin:$(PATH)
#
# The ANGLE Makefile does "-include ../../Makefile.include" which would pick up
# those stale macOS settings and prepend the depends-built Python (which lacks
# lzma support) to PATH.  gclient sync's post-sync hooks then use that Python
# and fail when trying to decompress the Chromium clang .tar.xz toolchain.
#
# Fix: pass CROSS_COMPILING=no, PLATFORM=native, and a sanitised PATH (with the
# xbmc-depends native prefix stripped out) as GNU Make command-line variables.
# Command-line overrides have the highest precedence in GNU Make and override
# any := assignment in Makefile.include, including the PATH manipulation.
# depot_tools is already in PATH from the step above and is preserved.
ANGLE_PATH=$(echo "$PATH" | tr ':' '\n' \
  | grep -v '/xbmc-depends' \
  | tr '\n' ':' \
  | sed 's/:$//')

step "1/5  ANGLE"

if [[ "$SKIP_ANGLE" -eq 1 ]]; then
  info "Skipping ANGLE build (--skip-angle)."
  [[ -d "$ANGLE_FRAMEWORKS_DIR/libEGL.framework" ]] \
    || die "libEGL.framework not found at $ANGLE_FRAMEWORKS_DIR — run without --skip-angle first."
  ok "Reusing existing ANGLE install: $ANGLE_INSTALL"
else
  ANGLE_COMMIT=$(grep '^ANGLE_COMMIT' "$ANGLE_DEPENDS_DIR/ANGLE-VERSION" | cut -d= -f2 | tr -d '[:space:]')
  info "Pinned commit: $ANGLE_COMMIT"

  if [[ "$CLEAN_ANGLE" -eq 1 ]]; then
    info "Cleaning ANGLE checkout and install (--clean-angle)..."
    make -C "$ANGLE_DEPENDS_DIR" distclean \
      CROSS_COMPILING=no PLATFORM=native 2>/dev/null || true
    rm -rf "$ANGLE_INSTALL"
    ok "ANGLE cleaned."
  fi

  # Already installed?
  if [[ -f "$ANGLE_DEPENDS_DIR/.installed-native" && -d "$ANGLE_FRAMEWORKS_DIR/libEGL.framework" ]]; then
    ok "ANGLE already installed — skipping build.  (use --clean-angle to force rebuild)"
  else
    info "Fetching and building ANGLE (gclient sync + gn + ninja)..."
    info "This can take 20–40 minutes on the first run."
    # CROSS_COMPILING=no  — prevents ANGLE Makefile from using depends-native tools
    # PLATFORM=native     — uses the native/ build dir (not a stale macOS platform name)
    # PATH=               — strips xbmc-depends native prefix so gclient hooks use
    #                       the system Python, not the depends-built one
    make -j"$JOBS" -C "$ANGLE_DEPENDS_DIR" \
      CROSS_COMPILING=no PLATFORM=native \
      PATH="$ANGLE_PATH" \
      PREFIX="$ANGLE_INSTALL"
    ok "ANGLE build complete."
    info "  Headers:    $ANGLE_INSTALL/include"
    info "  Frameworks: $ANGLE_FRAMEWORKS_DIR"
  fi
fi

# ── Step 2: Kodi depends ───────────────────────────────────────────────────────
step "2/5  Kodi depends (visionOS target)"

if [[ "$SKIP_DEPENDS" -eq 1 ]]; then
  info "Skipping depends build (--skip-depends)."
  [[ -d "$DEPENDS_PREFIX" ]] \
    || die "Depends prefix $DEPENDS_PREFIX does not exist — run without --skip-depends first."
  ok "Reusing existing depends prefix: $DEPENDS_PREFIX"
else
  if [[ "$CLEAN_DEPENDS" -eq 1 ]]; then
    info "Cleaning depends prefix $DEPENDS_PREFIX (--clean-depends)..."
    rm -rf "$DEPENDS_PREFIX"
    ok "Depends prefix removed."
    info "Cleaning depends build tree..."
    make -C "$DEPENDS_DIR" distclean 2>/dev/null || true
    ok "Depends build tree cleaned."
  fi

  cd "$DEPENDS_DIR"
  info "Running bootstrap..."
  ./bootstrap 2>/dev/null || true   # idempotent; harmless if configure already exists

  info "Configuring depends (host=aarch64-apple-darwin, platform=visionos)..."
  # ac_cv_prog_cc_c23/c11=no: suppress autoconf -std=gnu23 injection bug on
  # Xcode 16 / macOS 26 which causes clang to reject certain system headers.
  ac_cv_prog_cc_c23=no ac_cv_prog_cc_c11=no \
    ./configure \
      --host=aarch64-apple-darwin \
      --with-platform=visionos

  info "Building depends (-j$JOBS, takes 15–30 min on first run)..."
  make -j"$JOBS"
  ok "Kodi depends build complete."
fi

# ── Step 3: Locate native cmake + target toolchain ─────────────────────────────
step "3/5  Locating native cmake and target toolchain"

NATIVE_CMAKE=$(find "$DEPENDS_PREFIX" -name "cmake" -type f -path "*-native/bin/*" 2>/dev/null | head -1)
# Match either *-target-release or *-target-debug (depends is configured
# with --enable-debug by default, producing a -debug suffix).
TARGET_TOOLCHAIN=$(find "$DEPENDS_PREFIX" -name "Toolchain.cmake" \
  \( -path "*-target-release/share/*" -o -path "*-target-debug/share/*" \) \
  2>/dev/null | head -1)

[[ -n "$NATIVE_CMAKE" ]]     || die "Could not find native cmake under $DEPENDS_PREFIX"
[[ -n "$TARGET_TOOLCHAIN" ]] || die "Could not find Toolchain.cmake under $DEPENDS_PREFIX"

ok "cmake:     $NATIVE_CMAKE"
ok "toolchain: $TARGET_TOOLCHAIN"

# ── Step 4: CMake configure ────────────────────────────────────────────────────
step "4/5  CMake configure  ($BUILD_TYPE)"

if [[ "$SKIP_CMAKE" -eq 1 ]]; then
  info "Skipping CMake configure (--skip-cmake)."
  [[ -f "$BUILD_DIR/Kodi.xcodeproj/project.pbxproj" ]] \
    || die "Xcode project not found in $BUILD_DIR — run without --skip-cmake first."
  ok "Reusing existing Xcode project: $BUILD_DIR"
else
  if [[ "$CLEAN_BUILD" -eq 1 ]]; then
    info "Removing build dir $BUILD_DIR (--clean-build)..."
    rm -rf "$BUILD_DIR"
    ok "Build dir removed."
  fi

  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  # Wipe CMake cache so a re-run doesn't pick up stale cache entries.
  rm -f CMakeCache.txt

  info "Running cmake..."
  "$NATIVE_CMAKE" \
    -G Xcode \
    -DCMAKE_TOOLCHAIN_FILE="$TARGET_TOOLCHAIN" \
    -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
    -DCORE_SYSTEM_NAME=visionos \
    -DADDONS_TO_BUILD="pvr.mythtv" \
    -DADDON_SRC_PREFIX="$(dirname "$KODI_DIR")" \
    -DENABLE_XCODE_ADDONBUILD=ON \
    -DANGLE_INCLUDE_DIR="$ANGLE_INSTALL/include" \
    -DANGLE_FRAMEWORKS_DIR="$ANGLE_FRAMEWORKS_DIR" \
    -DCMAKE_THREAD_LIBS_INIT="" \
    -DCMAKE_HAVE_THREADS_LIBRARY=1 \
    -DCMAKE_USE_WIN32_THREADS_INIT=0 \
    -DCMAKE_USE_PTHREADS_INIT=1 \
    -DThreads_FOUND=TRUE \
    -DPLATFORM_BUNDLE_IDENTIFIER="${PLATFORM_BUNDLE_IDENTIFIER:-org.xbmc.kodi-visionos}" \
    -DDEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
    "$KODI_DIR"

  ok "CMake configure complete."
fi

# ── Step 5: xcodebuild ─────────────────────────────────────────────────────────
step "5/5  xcodebuild  (configuration=$BUILD_TYPE, jobs=$JOBS)"

cd "$BUILD_DIR"

xcodebuild \
  -configuration "$BUILD_TYPE" \
  -target ALL_BUILD \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -jobs "$JOBS"

# visionOS Xcode builds go to build/<Config>-xros/ rather than <Config>/
APP_BUNDLE="$BUILD_DIR/build/${BUILD_TYPE}-xros/Kodi.app"
[[ -d "$APP_BUNDLE" ]] || die "Build appeared to succeed but $APP_BUNDLE not found."

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Build complete!                                             ║"
printf "║  App:        %-48s║\n" "$APP_BUNDLE"
printf "║  Config:     %-48s║\n" "$BUILD_TYPE"
printf "║  SDK:        %-48s║\n" "visionOS $SDK_VERSION"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "To install on a connected Vision Pro:"
echo "  xcodebuild -configuration $BUILD_TYPE -scheme Kodi \\"
echo "    -destination 'platform=visionOS,id=<device-udid>' install"
