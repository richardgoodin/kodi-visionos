# cmake/modules/FindLibLZMA.cmake
#
# Custom FindLibLZMA override for the Kodi visionOS port.
#
# Problem: CMake's built-in FindLibLZMA module uses CHECK_LIBRARY_EXISTS to
# verify that lzma_auto_decoder(), lzma_easy_encoder(), and lzma_lzma_preset()
# are present in liblzma.a.  CHECK_LIBRARY_EXISTS does this by linking a
# minimal test program.  In a cross-compilation setup (targeting visionOS from
# a macOS host) the linker produces a visionOS binary that the host cannot
# execute, so the check returns FALSE even though the symbols are present.
#
# Strategy:
#   • visionOS  → pre-set the three capability flags in the CMake cache as
#                 INTERNAL BOOL = TRUE before delegating to the built-in
#                 module.  CHECK_LIBRARY_EXISTS skips the link test whenever
#                 its result variable is already in the cache, so the
#                 pre-seeded values are used as-is.
#   • All other platforms → delegate directly to the built-in FindLibLZMA
#                 module via its absolute path to avoid infinite recursion
#                 through this override.

if("visionos" IN_LIST CORE_PLATFORM_NAME_LC OR CORE_SYSTEM_NAME STREQUAL "visionos")
  # Pre-satisfy the three capability checks so CHECK_LIBRARY_EXISTS in the
  # built-in module is a no-op.  liblzma built via tools/depends always
  # contains all three symbols.
  set(LIBLZMA_HAS_AUTO_DECODER 1 CACHE INTERNAL "liblzma has lzma_auto_decoder" FORCE)
  set(LIBLZMA_HAS_EASY_ENCODER 1 CACHE INTERNAL "liblzma has lzma_easy_encoder" FORCE)
  set(LIBLZMA_HAS_LZMA_PRESET  1 CACHE INTERNAL "liblzma has lzma_lzma_preset"  FORCE)
endif()

# Delegate to the built-in module by absolute path to avoid recursing back
# through this override.
if(EXISTS "${CMAKE_ROOT}/Modules/FindLibLZMA.cmake")
  include("${CMAKE_ROOT}/Modules/FindLibLZMA.cmake")
else()
  message(FATAL_ERROR
    "FindLibLZMA: built-in module not found at ${CMAKE_ROOT}/Modules/FindLibLZMA.cmake")
endif()
