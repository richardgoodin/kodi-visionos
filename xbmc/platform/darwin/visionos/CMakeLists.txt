# XBMCApplication.mm is excluded here; it is listed as CORE_MAIN_SOURCE in
# cmake/scripts/visionos/ArchSetup.cmake so it gets compiled directly into
# the kodi executable target.  Including it here too would produce duplicate
# symbol errors at link time.
set(SOURCES VisionOSDisplayManager.mm
            VisionOSGLView.mm
            VisionOSKeyboardView.mm
            XBMCController.mm)

set(HEADERS VisionOSDisplayManager.h
            VisionOSGLView.h
            VisionOSKeyboardView.h
            VisionOSLog.h
            XBMCApplication.h
            XBMCController.h)

core_add_library(platform_visionos)
