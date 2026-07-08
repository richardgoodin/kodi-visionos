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
