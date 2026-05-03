#!/bin/bash
# configure-visionos.sh
# Single entry point to build Kodi for Apple visionOS (xrOS).
#
# Prerequisites:
#   Xcode 16.0+  (xcodebuild -version)
#   visionOS SDK 2.0+  (xcodebuild -showsdks | grep xros)
#   depot_tools  (for `gn` and `ninja` used by ANGLE)
#   Python 3.11+
#
# Usage:
#   ./build-scripts/configure-visionos.sh [--debug] [--skip-depends] [--skip-angle]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KODI_DIR="$(dirname "$SCRIPT_DIR")"

# ── Required versions ──────────────────────────────────────────────────────────
REQUIRED_XCODE_MAJOR=16
REQUIRED_VISIONOS_SDK="2.0"
# ──────────────────────────────────────────────────────────────────────────────

BUILD_TYPE="Release"
SKIP_DEPENDS=0
SKIP_ANGLE=0
JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)

for arg in "$@"; do
  case "$arg" in
    --debug)        BUILD_TYPE="Debug" ;;
    --skip-depends) SKIP_DEPENDS=1 ;;
    --skip-angle)   SKIP_ANGLE=1 ;;
    --help|-h)
      echo "Usage: $0 [--debug] [--skip-depends] [--skip-angle]"
      exit 0
      ;;
  esac
done

# ── Helper ─────────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

# ── Step 1: Verify prerequisites ───────────────────────────────────────────────
info "Checking Xcode version..."
XCODE_VERSION=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')
XCODE_MAJOR=$(echo "$XCODE_VERSION" | cut -d. -f1)
if [ "${XCODE_MAJOR:-0}" -lt "$REQUIRED_XCODE_MAJOR" ]; then
  die "Xcode $REQUIRED_XCODE_MAJOR+ required; found ${XCODE_VERSION:-none}"
fi
info "  Xcode $XCODE_VERSION — OK"

info "Checking visionOS SDK..."
SDK_PATH=$(xcrun --sdk xros --show-sdk-path 2>/dev/null) || die "visionOS SDK not found. Install Xcode with visionOS support."
SDK_VERSION=$(xcrun --sdk xros --show-sdk-version 2>/dev/null)
info "  visionOS SDK $SDK_VERSION at $SDK_PATH — OK"

# ── Step 2: Build ANGLE ────────────────────────────────────────────────────────
ANGLE_DEPENDS_DIR="$KODI_DIR/tools/depends/target/angle"
ANGLE_PREFIX="$KODI_DIR/tools/depends/angle-install"

if [ "$SKIP_ANGLE" -eq 0 ]; then
  info "Building ANGLE for visionOS..."
  info "  NOTE: ANGLE requires depot_tools (gn + ninja) in PATH."
  info "  See tools/depends/target/angle/Makefile for details."
  info "  Pinned commit: $(grep ANGLE_COMMIT "$ANGLE_DEPENDS_DIR/ANGLE-VERSION" | cut -d= -f2)"

  # Check gn is available
  if ! command -v gn &>/dev/null; then
    die "'gn' not found in PATH. Install depot_tools: https://commondatastorage.googleapis.com/chrome-infra-docs/flat/depot_tools/docs/html/depot_tools_tutorial.html#_setting_up"
  fi

  make -j"$JOBS" -C "$ANGLE_DEPENDS_DIR" PREFIX="$ANGLE_PREFIX"
  info "  ANGLE build complete. Headers: $ANGLE_PREFIX/include, Libs: $ANGLE_PREFIX/lib"
else
  info "Skipping ANGLE build (--skip-angle)."
  if [ ! -f "$ANGLE_PREFIX/lib/libEGL.a" ]; then
    die "ANGLE not built yet. Run without --skip-angle first."
  fi
fi

# ── Step 3: Locate native CMake from depends ───────────────────────────────────
DEPENDS_PREFIX="/Users/Shared/xbmc-depends"
if [ "$SKIP_DEPENDS" -eq 0 ]; then
  info "Building Kodi depends for visionOS..."
  cd "$KODI_DIR/tools/depends"
  ./bootstrap 2>/dev/null || true
  # Use the darwin host triplet so configure.ac's *darwin* case is matched;
  # platform differentiation (xros SDK) is done via --with-platform=visionos.
  # --with-sdk is intentionally omitted: configure auto-detects the SDK version
  # via `xcrun --sdk xros --show-sdk-version`.  Passing the full SDK path here
  # produces a malformed deps_dir with the entire SDK path embedded in it.
  ac_cv_prog_cc_c23=no ac_cv_prog_cc_c11=no ./configure \
    --host=aarch64-apple-darwin \
    --with-platform=visionos
  make -j"$JOBS"
  info "Depends build complete."
else
  info "Skipping depends build (--skip-depends)."
fi

NATIVE_CMAKE=$(find "$DEPENDS_PREFIX" -name "cmake" -type f -path "*-native/bin/*" 2>/dev/null | head -1)
TARGET_TOOLCHAIN=$(find "$DEPENDS_PREFIX" -name "Toolchain.cmake" -path "*-target-release/share/*" 2>/dev/null | head -1)

if [ -z "$NATIVE_CMAKE" ] || [ -z "$TARGET_TOOLCHAIN" ]; then
  die "Could not locate native cmake or target toolchain under $DEPENDS_PREFIX."
fi
info "cmake:     $NATIVE_CMAKE"
info "toolchain: $TARGET_TOOLCHAIN"

# ── Step 4: Configure CMake ────────────────────────────────────────────────────
BUILD_DIR="$KODI_DIR/kodi-build-visionos"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

info "Configuring CMake for visionOS ($BUILD_TYPE)..."
"$NATIVE_CMAKE" \
  -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE="$TARGET_TOOLCHAIN" \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
  -DCORE_SYSTEM_NAME=visionos \
  -DANGLE_INCLUDE_DIR="$ANGLE_PREFIX/include" \
  -DANGLE_LIBRARY_DIR="$ANGLE_PREFIX/lib" \
  ..

# ── Step 5: Build ──────────────────────────────────────────────────────────────
info "Building Kodi ($BUILD_TYPE, $JOBS jobs)..."
xcodebuild \
  -configuration "$BUILD_TYPE" \
  -target ALL_BUILD \
  -jobs "$JOBS"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Build complete!"
echo " App bundle: $BUILD_DIR/$BUILD_TYPE/Kodi.app"
echo " ANGLE libs: $ANGLE_PREFIX/lib"
echo "═══════════════════════════════════════════════════════════"
