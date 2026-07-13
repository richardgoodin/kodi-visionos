#!/bin/bash
set -e

# visionOS: embed ANGLE frameworks into the app bundle and add an rpath so
# the executable can locate them at runtime (@rpath/libEGL.framework/libEGL).
#
# Inputs:
#   CODESIGNING_FOLDER_PATH - the built .app (from Xcode)
#   ANGLE_FRAMEWORKS_DIR    - dir containing libEGL.framework / libGLESv2.framework

APP="${CODESIGNING_FOLDER_PATH}"
: "${ANGLE_FRAMEWORKS_DIR:?ANGLE_FRAMEWORKS_DIR must be set}"

EXE="${APP}/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP}/Info.plist")"
DEST="${APP}/Frameworks"
mkdir -p "${DEST}"

for fw in libEGL.framework libGLESv2.framework; do
  if [ ! -d "${ANGLE_FRAMEWORKS_DIR}/${fw}" ]; then
    echo "ERROR: ${fw} not found in ${ANGLE_FRAMEWORKS_DIR}" >&2
    exit 1
  fi
  echo "Embedding ${fw}"
  rm -rf "${DEST}/${fw}"
  cp -R "${ANGLE_FRAMEWORKS_DIR}/${fw}" "${DEST}/"
done

# Add @executable_path/Frameworks rpath if not already present.
if ! otool -l "${EXE}" | grep -q "@executable_path/Frameworks"; then
  echo "Adding rpath @executable_path/Frameworks"
  install_name_tool -add_rpath @executable_path/Frameworks "${EXE}"
fi

# visionOS: stage a pure-Python _scproxy stub into the app's Python stdlib.
# The real _scproxy C ext is macOS-only and isn't built for xrOS, but urllib
# (and add-ons that import it directly) expect it. The stub returns "no proxy",
# which is correct on-device. Only stage when no real _scproxy*.so is present.
PYLIB="${APP}/Frameworks/lib/python${PYTHON_VERSION}"
if [ -d "${PYLIB}" ] \
   && ! ls "${PYLIB}"/lib-dynload/_scproxy*.so >/dev/null 2>&1 \
   && ! ls "${PYLIB}"/_scproxy*.so >/dev/null 2>&1; then
  echo "Staging _scproxy stub into ${PYLIB}"
  cp "${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/visionos/_scproxy.py" "${PYLIB}/_scproxy.py"
fi
