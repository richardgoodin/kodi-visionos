#!/bin/bash
set -e

# visionOS: embed provisioning profile + genuine re-sign so the bundle
# installs on a non-jailbroken Vision Pro.
#
# Inputs (from environment / CMake -D):
#   CODESIGNING_FOLDER_PATH  - the built .app (provided by Xcode)
#   DEVELOPMENT_TEAM         - team id used to select the signing identity
#   VISIONOS_PROVISIONING_PROFILE - path to a .mobileprovision to embed
#       (if unset, searches ~/Library/Developer/Xcode/UserData/Provisioning Profiles
#        for a profile whose team matches DEVELOPMENT_TEAM)

APP="${CODESIGNING_FOLDER_PATH}"
: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM must be set}"

# --- Resolve the provisioning profile -------------------------------------
PROFILE_SRC="${VISIONOS_PROVISIONING_PROFILE:-}"
if [ -z "${PROFILE_SRC}" ]; then
  PROFILE_DIR="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  for f in "${PROFILE_DIR}"/*.mobileprovision; do
    [ -e "$f" ] || continue
    security cms -D -i "$f" > /tmp/kodi_vos_scan.plist 2>/dev/null || continue
    team=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' /tmp/kodi_vos_scan.plist 2>/dev/null)
    if [ "$team" = "${DEVELOPMENT_TEAM}" ]; then
      PROFILE_SRC="$f"; break
    fi
  done
fi
if [ -z "${PROFILE_SRC}" ] || [ ! -e "${PROFILE_SRC}" ]; then
  echo "ERROR: no provisioning profile found for team ${DEVELOPMENT_TEAM}" >&2
  echo "       set VISIONOS_PROVISIONING_PROFILE to a .mobileprovision path" >&2
  exit 1
fi

# --- Resolve the signing identity from the team ---------------------------
# The signing cert's name carries the team it was *issued* under (which may
# differ from DEVELOPMENT_TEAM used by the profile). Match the single
# "Apple Development" identity in the keychain. If more than one exists,
# set VISIONOS_SIGN_IDENTITY to the desired 40-char hash to disambiguate.
if [ -n "${VISIONOS_SIGN_IDENTITY:-}" ]; then
  IDENTITY="${VISIONOS_SIGN_IDENTITY}"
else
  matches=$(security find-identity -v -p codesigning | grep "Apple Development" | awk '{print $2}')
  count=$(printf '%s\n' "${matches}" | grep -c .)
  if [ "${count}" -ne 1 ]; then
    echo "ERROR: expected exactly 1 'Apple Development' identity, found ${count}." >&2
    echo "       set VISIONOS_SIGN_IDENTITY to the desired identity hash." >&2
    exit 1
  fi
  IDENTITY="${matches}"
fi

echo "Embedding provisioning profile: ${PROFILE_SRC}"
cp "${PROFILE_SRC}" "${APP}/embedded.mobileprovision"

security cms -D -i "${APP}/embedded.mobileprovision" > /tmp/kodi_vos_pp.plist
/usr/libexec/PlistBuddy -x -c 'Print Entitlements' /tmp/kodi_vos_pp.plist > /tmp/kodi_vos.entitlements

echo "Re-signing ${APP} with identity ${IDENTITY} (team ${DEVELOPMENT_TEAM})"
codesign --force --sign "${IDENTITY}" \
  --entitlements /tmp/kodi_vos.entitlements \
  --generate-entitlement-der "${APP}"

codesign -dv --verbose=4 "${APP}" 2>&1 | egrep "Authority=|TeamIdentifier=" || true
