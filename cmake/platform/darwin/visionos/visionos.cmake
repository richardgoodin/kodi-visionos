# cmake/platform/darwin/visionos/visionos.cmake
# Platform-specific settings for the Kodi visionOS port.
# Loaded after the base darwin_embedded settings if CORE_SYSTEM_NAME=visionos.

list(APPEND ARCH_DEFINES -DTARGET_DARWIN_VISIONOS)

# visionOS does not expose native OpenGL ES; ANGLE provides GLES over Metal.
# The EGL/GLES headers ship with ANGLE's include directory (not the platform SDK).
set(ENABLE_AIRTUNES OFF CACHE BOOL "" FORCE)
set(${CORE_SYSTEM_NAME}_SEARCH_CONFIG NO_DEFAULT_PATH CACHE STRING "")
set(PLATFORM_OPTIONAL_DEPS_EXCLUDE CEC)

# ANGLE headers must be on the include path before any platform SDK GLES headers.
# The configure script is responsible for setting ANGLE_INCLUDE_DIR correctly.
if(DEFINED ANGLE_INCLUDE_DIR)
  include_directories(BEFORE ${ANGLE_INCLUDE_DIR})
endif()

# Link against the ANGLE EGL and GLES libraries built by tools/depends
if(DEFINED ANGLE_LIBRARY_DIR)
  link_directories(${ANGLE_LIBRARY_DIR})
  list(APPEND SYSTEM_LDFLAGS -lEGL -lGLESv2)
endif()
