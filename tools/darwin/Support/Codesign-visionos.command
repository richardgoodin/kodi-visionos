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
  # Bundle id of the app we are signing, e.g. com.goodin.kodi
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Info.plist" 2>/dev/null)
  EXACT_APPID="${DEVELOPMENT_TEAM}.${BUNDLE_ID}"
  WILDCARD_APPID="${DEVELOPMENT_TEAM}.*"
  MATCH_EXACT=""; MATCH_WILDCARD=""; MATCH_TEAM=""
  for f in "${PROFILE_DIR}"/*.mobileprovision; do
    [ -e "$f" ] || continue
    security cms -D -i "$f" > /tmp/kodi_vos_scan.plist 2>/dev/null || continue
    appid=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' /tmp/kodi_vos_scan.plist 2>/dev/null)
    team=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' /tmp/kodi_vos_scan.plist 2>/dev/null)
    [ "$team" = "${DEVELOPMENT_TEAM}" ] || continue
    if [ "$appid" = "${EXACT_APPID}" ]; then MATCH_EXACT="$f"; fi
    if [ "$appid" = "${WILDCARD_APPID}" ]; then MATCH_WILDCARD="$f"; fi
    [ -z "${MATCH_TEAM}" ] && MATCH_TEAM="$f"
  done
  # Prefer exact bundle-id match, then team wildcard, then any team profile.
  PROFILE_SRC="${MATCH_EXACT:-${MATCH_WILDCARD:-${MATCH_TEAM}}}"
fi
if [ -z "${PROFILE_SRC}" ] || [ ! -e "${PROFILE_SRC}" ]; then
  echo "ERROR: no provisioning profile found for team ${DEVELOPMENT_TEAM}" >&2
  echo "       set VISIONOS_PROVISIONING_PROFILE to a .mobileprovision path" >&2
  exit 1
fi

# --- Resolve the signing identity from the team ---------------------------
# The signing cert name carries the team it was issued under, which may
# differ from DEVELOPMENT_TEAM used by the profile. Match the single
# Apple Development identity in the keychain. If more than one exists,
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

# Sign nested frameworks individually first (the device validates each one).
if [ -d "${APP}/Frameworks" ]; then
  for fw in "${APP}/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    echo "Signing framework $(basename "$fw")"
    codesign --force --sign "${IDENTITY}" --timestamp=none "$fw"
  done
fi

echo "Re-signing ${APP} with identity ${IDENTITY} (team ${DEVELOPMENT_TEAM})"
codesign --force --sign "${IDENTITY}" \
  --entitlements /tmp/kodi_vos.entitlements \
  --generate-entitlement-der "${APP}"

codesign -dv --verbose=4 "${APP}" 2>&1 | egrep "Authority=|TeamIdentifier=" || true
