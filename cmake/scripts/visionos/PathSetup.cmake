# cmake/scripts/visionos/PathSetup.cmake
# Path/bundle-identifier setup for the Kodi visionOS port.
# Modelled on cmake/scripts/darwin_embedded/PathSetup.cmake.

set(PLATFORM_BUNDLE_IDENTIFIER "${APP_PACKAGE}-visionos" CACHE STRING "Bundle ID")
if(DEFINED ENV{PLATFORM_BUNDLE_IDENTIFIER})
  set(PLATFORM_BUNDLE_IDENTIFIER "$ENV{PLATFORM_BUNDLE_IDENTIFIER}" CACHE STRING "Bundle ID" FORCE)
endif()
list(APPEND final_message "Bundle ID: ${PLATFORM_BUNDLE_IDENTIFIER}")
include(cmake/scripts/osx/PathSetup.cmake)
