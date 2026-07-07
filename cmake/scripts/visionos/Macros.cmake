# cmake/scripts/visionos/Macros.cmake
# visionOS shares darwin's core macros (core_link_library, find_soname).
# Forward to the darwin_embedded definitions to keep a single source of truth.
include(${CMAKE_SOURCE_DIR}/cmake/scripts/darwin_embedded/Macros.cmake)
