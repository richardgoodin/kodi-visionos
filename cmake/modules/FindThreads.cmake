# cmake/modules/FindThreads.cmake
#
# Custom FindThreads override for the Kodi visionOS port.
#
# Problem: On visionOS, pthreads are bundled inside libc — there is no
# separate -pthread compiler flag or -lpthread link flag.  CMake's built-in
# FindThreads module tries (and fails) to compile a -pthread test, then marks
# Threads_FOUND = FALSE (as a local variable that shadows any cache value we
# pre-set).  The subsequent find_package_handle_standard_args call then fails
# with "Could NOT find Threads".
#
# Strategy:
#   • visionOS  → set all required variables and create the Threads::Threads
#                 imported target directly, bypassing CMake's detection logic.
#   • All other platforms → delegate to CMake's built-in FindThreads module
#                 via its absolute path to avoid infinite recursion through
#                 this override.

if("visionos" IN_LIST CORE_PLATFORM_NAME_LC OR CORE_SYSTEM_NAME STREQUAL "visionos")
  # visionOS: pthreads are in libc; no linker flag is needed.
  set(CMAKE_THREAD_LIBS_INIT     ""   CACHE STRING "Thread library"   FORCE)
  set(CMAKE_HAVE_THREADS_LIBRARY 1    CACHE BOOL   "Threads in libc"  FORCE)
  set(CMAKE_USE_WIN32_THREADS_INIT 0  CACHE BOOL   "No Win32 threads" FORCE)
  set(CMAKE_USE_PTHREADS_INIT    1    CACHE BOOL   "Use pthreads"     FORCE)
  set(Threads_FOUND              TRUE)

  if(NOT TARGET Threads::Threads)
    add_library(Threads::Threads INTERFACE IMPORTED)
  endif()

  # Satisfy find_package() bookkeeping (sets Threads_FOUND, prints status).
  include(FindPackageHandleStandardArgs)
  find_package_handle_standard_args(Threads DEFAULT_MSG Threads_FOUND)

else()
  # All other platforms: include the built-in FindThreads module by its
  # absolute path so we don't recurse back through this override.
  if(EXISTS "${CMAKE_ROOT}/Modules/FindThreads.cmake")
    include("${CMAKE_ROOT}/Modules/FindThreads.cmake")
  else()
    message(FATAL_ERROR
      "FindThreads: built-in module not found at ${CMAKE_ROOT}/Modules/FindThreads.cmake")
  endif()
endif()
