# cmake/scripts/visionos/ArchSetup.cmake
# Architecture and platform setup for the Kodi visionOS port.
# Modelled on cmake/scripts/darwin_embedded/ArchSetup.cmake.

if(NOT CMAKE_TOOLCHAIN_FILE)
  message(FATAL_ERROR "CMAKE_TOOLCHAIN_FILE required for visionos. See ${CMAKE_SOURCE_DIR}/cmake/README.md")
endif()

# Entry point for XBMCApplication and the app bundle Info.plist
set(CORE_MAIN_SOURCE ${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/visionos/XBMCApplication.mm)
set(PLATFORM_BUNDLE_INFO_PLIST ${CMAKE_SOURCE_DIR}/xbmc/platform/darwin/visionos/Info.plist.in)

list(APPEND ARCH_DEFINES -DTARGET_POSIX -DTARGET_DARWIN -DTARGET_DARWIN_VISIONOS -DTARGET_DARWIN_EMBEDDED)
set(SYSTEM_DEFINES -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE
                   -D__STDC_CONSTANT_MACROS -DHAS_IOS_NETWORK -DHAS_ZEROCONF)
set(PLATFORM_DIR platform/darwin)
set(PLATFORMDEFS_DIR platform/posix)
set(CMAKE_SYSTEM_NAME Darwin)

if(WITH_ARCH)
  set(ARCH ${WITH_ARCH})
else()
  if(CPU STREQUAL arm64)
    set(ARCH aarch64)
  else()
    message(SEND_ERROR "Unknown CPU: ${CPU}")
  endif()
  set(CMAKE_OSX_ARCHITECTURES ${CPU})
  set(NEON True)
endif()

# visionOS does not expose native OpenGL ES; ANGLE provides GLES over Metal.
# PLATFORM_REQUIRED_DEPS is still set to OpenGLES so the rest of the build
# system installs GLES headers – ANGLE's EGL/GLES libraries replace the
# platform stubs at link time (see cmake/platform/visionos/visionos.cmake).
if(NOT APP_RENDER_SYSTEM OR APP_RENDER_SYSTEM STREQUAL "gles")
  set(PLATFORM_REQUIRED_DEPS OpenGLES)
  set(APP_RENDER_SYSTEM gles)
  list(APPEND SYSTEM_DEFINES -DGL_DO_NOT_WARN_IF_MULTI_GL_VERSION_HEADERS_INCLUDED
                             -DGLES_SILENCE_DEPRECATION)
else()
  message(SEND_ERROR "Currently only OpenGLES rendering is supported. Please set APP_RENDER_SYSTEM to \"gles\"")
endif()

list(APPEND DEPLIBS "-framework CoreFoundation" "-framework CoreVideo"
                    "-framework CoreAudio" "-framework AudioToolbox"
                    "-framework QuartzCore" "-framework MediaPlayer"
                    "-framework CFNetwork" "-framework CoreGraphics"
                    "-framework Foundation" "-framework UIKit"
                    "-framework CoreMedia" "-framework AVFoundation"
                    "-framework VideoToolbox" "-lresolv" "-ObjC"
                    "-framework AVKit" "-framework GameController"
                    "-framework Metal" "-framework IOSurface")

# visionOS SDK identifier is "xros"
set(CMAKE_OSX_SYSROOT xros)
# 2.0 floor: the stereo presentation uses RealityKit LowLevelTexture and
# TextureResource(image:), both visionOS 2+ APIs held in stored properties
# (which @available cannot gate).  Only 26.x hardware is targeted.
set(XROS_DEPLOYMENT_TARGET "2.0" CACHE STRING "Minimum visionOS deployment target version")
set(CMAKE_XCODE_ATTRIBUTE_XROS_DEPLOYMENT_TARGET ${XROS_DEPLOYMENT_TARGET})

set(ENABLE_OPTICAL OFF CACHE BOOL "" FORCE)
set(CMAKE_XCODE_ATTRIBUTE_INLINES_ARE_PRIVATE_EXTERN OFF)
set(CMAKE_XCODE_ATTRIBUTE_GCC_SYMBOLS_PRIVATE_EXTERN OFF)
set(CMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP OFF)

# Blank conflicting deployment-target attributes that Xcode injects at the
# project level (same workaround as darwin_embedded on macOS Tahoe / Xcode 16).
set(CMAKE_XCODE_ATTRIBUTE_DRIVERKIT_DEPLOYMENT_TARGET "")
set(CMAKE_XCODE_ATTRIBUTE_WATCHOS_DEPLOYMENT_TARGET "")
set(CMAKE_XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "")
set(CMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "")
set(CMAKE_XCODE_ATTRIBUTE_TVOS_DEPLOYMENT_TARGET "")

include(cmake/scripts/darwin/Macros.cmake)
enable_arc()

# Xcode strips dead code by default which breaks symbol wrapping
set(CMAKE_XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING OFF)

option(ENABLE_XCODE_ADDONBUILD "Enable Xcode automatic addon building?" OFF)

# Unify output directories so packaging scripts can locate the binary
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CORE_BUILD_DIR}/${CORE_BUILD_CONFIG})
foreach(OUTPUTCONFIG ${CMAKE_CONFIGURATION_TYPES})
  string(TOUPPER ${OUTPUTCONFIG} OUTPUTCONFIG)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${OUTPUTCONFIG} ${CORE_BUILD_DIR}/${CORE_BUILD_CONFIG})
endforeach()
