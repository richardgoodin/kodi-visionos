# cmake/platform/darwin_embedded/visionos.cmake
# Platform-specific settings for the Kodi visionOS port.
# Loaded by cmake/scripts/common/Platform.cmake when
# CORE_SYSTEM_NAME=darwin_embedded and CORE_PLATFORM_NAME=visionos.

list(APPEND ARCH_DEFINES -DTARGET_DARWIN_VISIONOS)

# visionOS includes pthreads in libc — there is no separate -lpthread flag.
# Pre-satisfy CMake's Threads find-module so find_package(Threads REQUIRED)
# succeeds without trying (and failing) to compile a -pthread test program.
set(CMAKE_THREAD_LIBS_INIT "")
set(CMAKE_HAVE_THREADS_LIBRARY 1)
set(CMAKE_USE_WIN32_THREADS_INIT 0)
set(CMAKE_USE_PTHREADS_INIT 1)
set(Threads_FOUND TRUE)

# visionOS does not expose native OpenGL ES; ANGLE provides GLES over Metal.
# The EGL/GLES headers ship with ANGLE's include directory (not the platform SDK).
set(ENABLE_AIRTUNES OFF CACHE BOOL "" FORCE)
set(${CORE_SYSTEM_NAME}_SEARCH_CONFIG NO_DEFAULT_PATH CACHE STRING "")
set(PLATFORM_OPTIONAL_DEPS_EXCLUDE CEC)

# ANGLE headers must be on the include path before any platform SDK GLES headers.
if(DEFINED ANGLE_INCLUDE_DIR)
  include_directories(BEFORE ${ANGLE_INCLUDE_DIR})
endif()

# Link against the ANGLE EGL and GLES frameworks built by tools/depends.
# ANGLE builds as .framework bundles on Apple platforms, not static libs.
#
# IMPORTANT: Do NOT add -framework flags to SYSTEM_LDFLAGS.  FindFFMPEG.cmake
# appends SYSTEM_LDFLAGS to a CMake list and then expands that list as
# positional cmake arguments for the ffmpeg sub-build.  Each list element
# becomes a separate word, so "-framework libEGL" would be split into
# two cmake arguments ("-framework" and "libEGL") causing:
#   CMake Error: Unknown argument -framework libGLESv2
# Instead, append directly to CMAKE_EXE_LINKER_FLAGS as a plain string so
# the flags travel through FindFFMPEG correctly.
if(DEFINED ANGLE_FRAMEWORKS_DIR)
  list(APPEND CMAKE_FRAMEWORK_PATH ${ANGLE_FRAMEWORKS_DIR})
  string(APPEND CMAKE_EXE_LINKER_FLAGS " -F${ANGLE_FRAMEWORKS_DIR} -framework libEGL -framework libGLESv2 -framework Metal")
elseif(DEFINED ANGLE_LIBRARY_DIR)
  # Fallback: static lib layout (legacy)
  link_directories(${ANGLE_LIBRARY_DIR})
  list(APPEND SYSTEM_LDFLAGS -lEGL -lGLESv2)
endif()
