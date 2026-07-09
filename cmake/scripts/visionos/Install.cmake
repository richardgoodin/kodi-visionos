# cmake/scripts/visionos/Install.cmake
# visionOS app-bundle packaging rules.
# Modelled on cmake/scripts/darwin_embedded/Install.cmake.

# Entitlements
set(ENTITLEMENTS_OUT_PATH "${CMAKE_BINARY_DIR}/CMakeFiles/${APP_NAME_LC}.dir/Kodi.entitlements")
configure_file(${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/visionos/Kodi.entitlements.in
               ${ENTITLEMENTS_OUT_PATH} @ONLY)
set_target_properties(${APP_NAME_LC} PROPERTIES
  XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS ${ENTITLEMENTS_OUT_PATH})

# App icon (visionOS layered .solidimagestack)
# Attach the asset catalog to the target and tell Xcode to run actool on it,
# producing Assets.car in the bundle. Without this, visionOS shows the default
# gridded placeholder icon.
set(VISIONOS_ASSET_CATALOG
    ${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/visionos/Assets.xcassets)
target_sources(${APP_NAME_LC} PRIVATE ${VISIONOS_ASSET_CATALOG})
set_source_files_properties(${VISIONOS_ASSET_CATALOG} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources)
set_target_properties(${APP_NAME_LC} PROPERTIES
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon")

# Code signing
set(DEVELOPMENT_TEAM "" CACHE STRING "Development Team")
set(CODE_SIGN_IDENTITY
    $<IF:$<BOOL:${DEVELOPMENT_TEAM}>,Apple\ Development,>
    CACHE STRING "Code Sign Identity")

set(CODE_SIGN_STYLE_APP Automatic)
set(PROVISIONING_PROFILE_APP "" CACHE STRING "Provisioning profile name for the Kodi app")
if(PROVISIONING_PROFILE_APP)
  set(CODE_SIGN_STYLE_APP Manual)
endif()

set_target_properties(${APP_NAME_LC} PROPERTIES
  XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "${CODE_SIGN_IDENTITY}"
  XCODE_ATTRIBUTE_CODE_SIGN_STYLE ${CODE_SIGN_STYLE_APP}
  XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${DEVELOPMENT_TEAM}"
  XCODE_ATTRIBUTE_PROVISIONING_PROFILE_SPECIFIER "${PROVISIONING_PROFILE_APP}")

# Optional addon build target
if(ADDONS_TO_BUILD)
  set(_addons "ADDONS=${ADDONS_TO_BUILD}")
endif()
add_custom_target(binary-addons
  COMMAND make -C ${CMAKE_SOURCE_DIR}/tools/depends/target/binary-addons clean
  COMMAND make -C ${CMAKE_SOURCE_DIR}/tools/depends/target/binary-addons VERBOSE=1 V=99
          INSTALL_PREFIX="${CMAKE_BINARY_DIR}/addons" CROSS_COMPILING=yes ${_addons})
if(ENABLE_XCODE_ADDONBUILD)
  add_dependencies(${APP_NAME_LC} binary-addons)
endif()
unset(_addons)

# --- visionOS bundle payload staging (lifted from darwin_embedded) ------------
# DllPaths copy first (copyframeworks-darwin_embedded reads it), then root files,
# Python stdlib + dylib fixup, dylibs->frameworks, then the AppHome data payload.
# Runs BEFORE the ANGLE-embed + codesign command so everything is signed.
add_custom_command(TARGET ${APP_NAME_LC} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/${CORE_BUILD_DIR}/DllPaths_generated.h
                                     ${CMAKE_BINARY_DIR}/xbmc/DllPaths_generated.h
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:${APP_NAME_LC}>
                                     $<TARGET_FILE_DIR:${APP_NAME_LC}>/${APP_NAME}.bin
    COMMAND "ACTION=build"
            "APP_NAME=${APP_NAME}"
            "XBMC_DEPENDS=${DEPENDS_PATH}"
            "SRCROOT=${CMAKE_SOURCE_DIR}"
            ${CMAKE_SOURCE_DIR}/tools/darwin/Support/CopyRootFiles-darwin_embedded.command
    COMMAND "XBMC_DEPENDS=${DEPENDS_PATH}"
            "PYTHON_VERSION=${PYTHON_VERSION}"
            ${CMAKE_SOURCE_DIR}/tools/darwin/Support/copyframeworks-darwin_embedded.command
    COMMAND ${CMAKE_SOURCE_DIR}/tools/darwin/Support/copyframeworks-dylibs2frameworks.command
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${DEPENDS_PATH}/share/${APP_NAME_LC}
            $<TARGET_FILE_DIR:${APP_NAME_LC}>/AppData/AppHome
    COMMAND ${CMAKE_COMMAND} -E copy
            ${CMAKE_BINARY_DIR}/addons/skin.estuary/media/Textures.xbt
            $<TARGET_FILE_DIR:${APP_NAME_LC}>/AppData/AppHome/addons/skin.estuary/media/Textures.xbt
)

add_custom_command(TARGET ${APP_NAME_LC} POST_BUILD
    # visionOS: embed ANGLE frameworks + add rpath (before signing)
    COMMAND "ANGLE_FRAMEWORKS_DIR=${ANGLE_FRAMEWORKS_DIR}"
            ${CMAKE_SOURCE_DIR}/tools/darwin/Support/copyframeworks-visionos.command
    # visionOS: embed provisioning profile + genuine re-sign (installs on device)
    COMMAND "CMAKE_SOURCE_DIR=${CMAKE_SOURCE_DIR}"
            "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}"
            "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
            ${CMAKE_SOURCE_DIR}/tools/darwin/Support/Codesign-visionos.command)


configure_file(${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/Credits.html.in
               ${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/Credits.html @ONLY)
