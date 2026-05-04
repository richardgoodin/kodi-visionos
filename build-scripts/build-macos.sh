#!/bin/bash
# build-macos.sh
# Full pipeline: distclean → working Kodi.app for macOS (Apple Silicon or Intel).
#
# Prerequisites (must be installed before first run):
#   Xcode 16.0+          — xcodebuild -version
#   macOS SDK 14+        — xcodebuild -showsdks | grep macos
#   Python 3.11+
#   autoconf / automake  — brew install autoconf automake
#   libtool              — brew install libtool
#
# Usage:
#   ./build-scripts/build-macos.sh [options]
#
# Options:
#   --debug            Build Debug instead of Release
#   --jobs N           Parallel jobs (default: logical CPU count)
#   --arch ARCH        Target arch: arm64 (default on Apple Silicon) or x86_64
#   --skip-depends     Skip Kodi depends bootstrap+build (reuse existing prefix)
#   --skip-cmake       Skip CMake configure (reuse existing Xcode project)
#   --clean-depends    rm -rf the depends prefix before building depends
#   --clean-build      rm -rf the CMake build dir before configuring
#   -h|--help          Show this message

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KODI_DIR="$(dirname "$SCRIPT_DIR")"

DEPENDS_DIR="$KODI_DIR/tools/depends"

# Kodi depends installs here (matches what configure.ac generates).
DEPENDS_PREFIX="/Users/Shared/xbmc-depends"

# CMake build output.
BUILD_DIR="$KODI_DIR/kodi-build-macos"

# ── Required versions ──────────────────────────────────────────────────────────
REQUIRED_XCODE_MAJOR=16

# ── Defaults ───────────────────────────────────────────────────────────────────
BUILD_TYPE="Release"
JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)
# Detect native arch; user can override with --arch.
NATIVE_ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel
TARGET_ARCH="$NATIVE_ARCH"
SKIP_DEPENDS=0
SKIP_CMAKE=0
CLEAN_DEPENDS=0
CLEAN_BUILD=0

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)         BUILD_TYPE="Debug" ;;
    --jobs)          shift; JOBS="$1" ;;
    --arch)          shift; TARGET_ARCH="$1" ;;
    --skip-depends)  SKIP_DEPENDS=1 ;;
    --skip-cmake)    SKIP_CMAKE=1 ;;
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

# Validate arch.
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "✗ ERROR: --arch must be arm64 or x86_64 (got: $TARGET_ARCH)" >&2; exit 1 ;;
esac

# Derive the autoconf host triplet from the target arch.
HOST_TRIPLET="${TARGET_ARCH}-apple-darwin"

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
step "0/4  Checking prerequisites"

# Xcode
XCODE_VERSION=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}') \
  || die "xcodebuild not found. Install Xcode."
XCODE_MAJOR=$(echo "$XCODE_VERSION" | cut -d. -f1)
[[ "${XCODE_MAJOR:-0}" -ge "$REQUIRED_XCODE_MAJOR" ]] \
  || die "Xcode $REQUIRED_XCODE_MAJOR+ required; found $XCODE_VERSION"
ok "Xcode $XCODE_VERSION"

# macOS SDK
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null) \
  || die "macOS SDK not found. Install Xcode command-line tools."
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)
ok "macOS SDK $SDK_VERSION  ($SDK_PATH)"

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

ok "Target arch: $TARGET_ARCH  (host triplet: $HOST_TRIPLET)"

# ── Step 1: Kodi depends ───────────────────────────────────────────────────────
step "1/4  Kodi depends (macOS target, arch=$TARGET_ARCH)"

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

  info "Configuring depends (host=$HOST_TRIPLET, platform=macos)..."
  # ac_cv_prog_cc_c23/c11=no: suppress autoconf -std=gnu23 injection bug on
  # Xcode 16 / macOS 26 which causes clang to reject certain system headers.
  ac_cv_prog_cc_c23=no ac_cv_prog_cc_c11=no \
    ./configure \
      --host="$HOST_TRIPLET" \
      --with-platform=macos

  info "Building depends (-j$JOBS, takes 15–30 min on first run)..."
  make -j"$JOBS"
  ok "Kodi depends build complete."
fi

# ── Step 2: Locate native cmake + target toolchain ─────────────────────────────
step "2/4  Locating native cmake and target toolchain"

NATIVE_CMAKE=$(find "$DEPENDS_PREFIX" -name "cmake" -type f -path "*-native/bin/*" 2>/dev/null | head -1)
# Match either *-target-release or *-target-debug.
TARGET_TOOLCHAIN=$(find "$DEPENDS_PREFIX" -name "Toolchain.cmake" \
  \( -path "*-target-release/share/*" -o -path "*-target-debug/share/*" \) \
  2>/dev/null | head -1)

[[ -n "$NATIVE_CMAKE" ]]     || die "Could not find native cmake under $DEPENDS_PREFIX"
[[ -n "$TARGET_TOOLCHAIN" ]] || die "Could not find Toolchain.cmake under $DEPENDS_PREFIX"

ok "cmake:     $NATIVE_CMAKE"
ok "toolchain: $TARGET_TOOLCHAIN"

# ── Step 3: CMake configure ────────────────────────────────────────────────────
step "3/4  CMake configure  ($BUILD_TYPE)"

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
    -DCORE_SYSTEM_NAME=darwin \
    -DCMAKE_THREAD_LIBS_INIT="" \
    -DCMAKE_HAVE_THREADS_LIBRARY=1 \
    -DCMAKE_USE_WIN32_THREADS_INIT=0 \
    -DCMAKE_USE_PTHREADS_INIT=1 \
    -DThreads_FOUND=TRUE \
    "$KODI_DIR"

  ok "CMake configure complete."
fi

# ── Step 4: xcodebuild ─────────────────────────────────────────────────────────
step "4/4  xcodebuild  (configuration=$BUILD_TYPE, jobs=$JOBS)"

cd "$BUILD_DIR"

xcodebuild \
  -configuration "$BUILD_TYPE" \
  -target ALL_BUILD \
  -jobs "$JOBS"

APP_BUNDLE="$BUILD_DIR/$BUILD_TYPE/Kodi.app"
[[ -d "$APP_BUNDLE" ]] || die "Build appeared to succeed but $APP_BUNDLE not found."

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Build complete!                                             ║"
printf "║  App:        %-48s║\n" "$APP_BUNDLE"
printf "║  Config:     %-48s║\n" "$BUILD_TYPE"
printf "║  SDK:        %-48s║\n" "macOS $SDK_VERSION"
printf "║  Arch:       %-48s║\n" "$TARGET_ARCH"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
