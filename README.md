# Kodi — visionOS Port

Personal fork of [xbmc/xbmc](https://github.com/xbmc/xbmc) targeting Apple visionOS.

## Status

**Stage 1 (in progress):** Windowed 2D app running on Vision Pro.  
ANGLE-backed GLES rendering into a CAMetalLayer.  
Input: keyboard, gamepad, Siri Remote.

Stage 2 (spatial/immersive mode) is out of scope for this effort.

## Architecture

All visionOS-specific code lives in dedicated peer directories that mirror the
tvOS backend; upstream files are not modified unless absolutely necessary.

| Directory | Purpose |
|---|---|
| `xbmc/platform/darwin/visionos/` | App delegate, controller, GL view, display manager, power management |
| `xbmc/windowing/visionos/` | WinSystem, WinEvents, VideoSync, OSScreenSaver |
| `cmake/platform/darwin/visionos/` | CMake platform module (`-DCORE_SYSTEM_NAME=visionos`) |
| `cmake/treedata/darwin/visionos/` | Source-directory list for CMake |
| `tools/depends/target/angle/` | ANGLE (GLES→Metal) build recipe |
| `build-scripts/configure-visionos.sh` | Single build entry point |

## Rendering

Kodi's GLES renderer is unchanged. ANGLE translates all GLES calls to Metal
at the link level.  `VisionOSGLView` creates an EGL display backed by a
`CAMetalLayer`, an EGL context, and an EGL surface; `CWinSystemVisionOS`
drives the frame loop through a `CADisplayLink`.

## Prerequisites

| Tool | Version |
|---|---|
| Xcode | 16.0+ |
| visionOS SDK | 2.0+ |
| depot_tools (`gn` + `ninja`) | latest |
| Python | 3.11+ |

## Building

```bash
# Build everything from scratch (ANGLE + depends + Kodi)
./build-scripts/configure-visionos.sh --debug

# Skip ANGLE if already built
./build-scripts/configure-visionos.sh --debug --skip-angle

# Skip depends if already built
./build-scripts/configure-visionos.sh --debug --skip-depends --skip-angle
```

## Upstream merges

This repo tracks `upstream/master` (xbmc/xbmc).  To pull new upstream commits:

```bash
git fetch upstream
git merge upstream/master
```

The overlay is designed so merge conflicts are rare; all new code lives in
`visionos/` peer directories.

## License

GPL v2, same as upstream Kodi.  ANGLE is BSD-licensed (compatible).
