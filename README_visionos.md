# Kodi for visionOS

An experimental port of Kodi to Apple Vision Pro (visionOS).

This document covers what works, how to build it, how to drive it, and — most
importantly for anyone reviewing the code — *why* several things are done the
way they are. A number of the decisions here look like bugs or unfinished stubs
until you know the constraint behind them.

---

## Status

Working:

- Kodi runs natively on visionOS as a windowed app
- GLES rendering via ANGLE on Metal
- Gaze/pinch input: select, context menu, four-way navigation, back
- Bluetooth keyboard, including Kodi's generic on-screen keyboard
- Window drag-to-resize with the GUI scaling to match
- Video playback (tested via HTTP sources and MythTV PVR)
- Square window corners

Not addressed yet:

- No key-repeat for long lists — one drag is one keypress
- `VisionOSDisplayManager::getDisplayRate` returns a fixed 90.0

---

## Architecture decisions

### ANGLE on Metal, not EAGL

This is the largest departure from the other Apple targets and the first thing
worth scrutinising.

Kodi's iOS and tvOS targets render GLES through EAGL. **EAGL does not exist on
visionOS.** There is no OpenGL ES implementation on the platform at all, so a
translation layer is not a preference here, it is a requirement. This port uses
ANGLE targeting Metal, with `VisionOSGLView` replacing `TVOSEAGLView`.

Consequences reviewers will care about:

- ANGLE becomes a build dependency for this platform
- The view's layer is a `CAMetalLayer`; the EGL surface is created from it
- `CWinSystemVisionOS::GetScreenResolution` queries the live EGL surface for
  its dimensions, falling back to `VisionOSDisplayManager` only before the
  surface exists

### The desktop is a fixed 1920x1080

visionOS windows are user-resizable by dragging. The obvious implementation —
tell Kodi its resolution changed on every drag frame — was tried and rejected.
It re-laid out the entire GUI roughly thirty times a second, and it required
mutating `CGraphicContext` from the UIKit main thread while the render thread
owns the EGL context.

Instead: **Kodi renders one fixed 1920x1080 desktop (3840x2160 pixels at scale
2.0), forever. The compositor scales that image to whatever size the window is.**

The mechanism is deliberately small:

- `XBMCController::viewDidLoad` builds `glView` with a fixed
  `CGRectMake(0, 0, 1920, 1080)` frame — *not* `self.view.bounds`
- `XBMCController::viewDidLayoutSubviews` scales and centres it into the window
  with a `CGAffineTransform`, using `min(w-ratio, h-ratio)` to preserve aspect

The key property is that **a transform does not change `bounds`**. `glView.bounds`
stays 1920x1080 for the lifetime of the app, so `VisionOSGLView::layoutSubviews`
never fires on a drag, so the EGL surface is never recreated and Kodi is never
told anything changed. There is no thread violation because there is no call.

This is also why `VisionOSDisplayManager::getScreenSize` returns a hardcoded
1920x1080 — under this model that constant is *correct*, not a stub.

Video at other resolutions is unaffected: Kodi's renderer scales each decoded
frame into the destination rect it is given, which here is simply always
1920x1080 — the same case as any 1080p display. Confirmed on device.

### The window launches at a fixed size

visionOS restores each scene's size across launches. `XBMCApplication`'s
`didFinishLaunchingWithOptions` issues a `UIWindowSceneGeometryPreferencesVision`
request with `size = 1920x1080` and `resizingRestrictions = Uniform`, so the
window comes up identically every launch and drags with a locked aspect ratio.

The request is made *after* `[self.window makeKeyAndVisible]`, because
`self.window.windowScene` is nil until the window is attached.

Note that closing the window with its X button backgrounds the app rather than
terminating it, so `didFinishLaunchingWithOptions` does not run again and the
window returns at its existing size. This is Apple's documented model and is
intentional.

### Square corners

visionOS draws windows inside a rounded glass container, which clips content.
Kodi's skins assume a rectangular screen and draw to the very edge, so the
corners cut off real UI.

`XBMCController` overrides `preferredContainerBackgroundStyle` to return
`UIContainerBackgroundStyleHidden`. This removes the glass container and, with
it, the corner rounding. Window drag and resize affordances are unaffected.

### Input: the shim sends keys, Kodi's keymap decides meaning

The gaze/pinch handler in `VisionOSGLView` does not know what a context menu,
an OSD, or a seek is. It sends **real keys with real press-and-release timing**
into `CAppInboundProtocol`, and Kodi's existing `keyboard.xml` supplies every
context-sensitive meaning. The same held pinch is `ContextMenu` in the GUI and
`PlayPause` in fullscreen video, with no code aware of the difference.

Two consequences worth knowing:

- **Select is focus-based, not positional.** A pinch sends Return, which acts on
  whatever Kodi has focused — not on what you looked at. There is deliberately
  no hover highlight, because a hover ball sitting on a *different* item than
  the focused one would misrepresent what a pinch will do.
- **Gaze position is used for exactly one thing:** the left-edge back gesture.
  Everything else ignores it.

---

## Binary add-ons: why this build fetches from forks

Two things make `pvr.mythtv` unbuildable for visionOS from upstream today, and
both are worked around with forked repositories rather than patches in this tree:

- **No binary add-on repository targets visionOS yet.** The platform is absent
  from the upstream manifests, and Kodi's own platform gate rejects any add-on
  that does not declare it.
- **zlib collides with the xrOS SDK over `fdopen`.** The version upstream pins
  does not compile.

**All of these forks must stay public** — the build fetches them anonymously,
with no credentials.

Four repositories are involved, and only the first is obvious. Each of the
others is discoverable only by opening the previous one and reading a manifest:

| Repository | Role |
|---|---|
| `richardgoodin/kodi-visionos` | This fork of Kodi |
| `richardgoodin/repo-binary-addons` (branch `Piers`) | Manifest fork; points at the add-on fork |
| `richardgoodin/pvr.mythtv` | The add-on fork |
| `richardgoodin/zlib` | Dependency fork; clears the `fdopen` clash |

The chain, working outward from this repo:

1. `cmake/addons/bootstrap/repositories/binary-addons.txt` — tracked here —
   points at `richardgoodin/repo-binary-addons` (branch `Piers`) rather than
   `xbmc/repo-binary-addons`. Being tracked, it survives `git clean`.
2. That fork's `pvr.mythtv/pvr.mythtv.txt` manifest points at
   `richardgoodin/pvr.mythtv`.
3. That add-on's depends manifest points at `richardgoodin/zlib`, at 1.3.2, to
   clear the `fdopen` clash.

**The manifest is the source of truth.** Add-on source is fetched by git ref from
the `repo-binary-addons` manifest — *not* from a local clone and *not* from
`ADDON_SRC_PREFIX`. Editing a local checkout of the add-on has no effect on what
actually gets built, which is a confusing failure mode worth knowing up front.

Beyond the zlib pin, the add-on fork also carries:

- **`01-build-static.patch` dropped.** Obsolete against the newer zlib, and it
  no longer applies.
- **`<platform>visionos</platform>` in `addon.xml.in`.** Without it Kodi refuses
  to load the built add-on — *"No platform ... supported platforms:
  ios-aarch64"*. This pairs with a change on the Kodi side, in
  `xbmc/addons/addoninfo/AddonInfoBuilder.cpp`, which now emits `visionos` and
  `visionos-aarch64` into `supportedPlatforms` under `TARGET_DARWIN_VISIONOS`.

If you rebuild after changing any of this, clear the stale fetches first — under
`tools/depends/target/binary-addons/<sdk>_arm64-target-debug/`, remove
`build/bootstrap`, `build/pvr.mythtv`, `build/zlib`, and `pvr.mythtv-prefix`.
That last one is an ExternalProject cache and is easy to miss.

The same pattern generalises to any binary add-on on visionOS: fork the add-on,
point a forked `repo-binary-addons` at it, point the tracked bootstrap file at
that, declare the platform in `addon.xml.in`, and add the add-on to
`ADDONS_TO_BUILD` with `ENABLE_XCODE_ADDONBUILD=ON`.

---

## Building

Requirements:

- macOS with Xcode and the visionOS (XROS) SDK
- An Apple Developer team for code signing

```
DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
PLATFORM_BUNDLE_IDENTIFIER=<your.bundle.id> \
CODE_SIGN_IDENTITY="Apple Development" \
./build-scripts/build-visionos.sh
```

The first build compiles ANGLE and the dependency tree and takes a long time.
Afterwards, for iterating on Kodi source only:

```
DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
PLATFORM_BUNDLE_IDENTIFIER=<your.bundle.id> \
CODE_SIGN_IDENTITY="Apple Development" \
./build-scripts/build-visionos.sh --skip-angle --skip-depends
```

Output: `kodi-build-visionos/build/Release-xros/Kodi.app`

---

## Installing and running

Find your device identifier:

```
xcrun devicectl list devices
```

Install and launch:

```
xcrun devicectl device install app --device <DEVICE_UDID> \
  kodi-build-visionos/build/Release-xros/Kodi.app

xcrun devicectl device process launch --device <DEVICE_UDID> \
  --terminate-existing <your.bundle.id>
```

Logs: open Console.app, select the device in the sidebar, filter on `Kodi`.

Note that `os_log` redacts `%@` arguments as `<private>`. Use numeric format
specifiers when adding diagnostics, or you will log nothing useful.

---

## Operating

### Gaze and pinch

Look at the Kodi window and pinch. Where you look does not select anything —
Kodi's own highlight does. Gaze only decides that the pinch belongs to Kodi.

| Gesture | Key sent | In the GUI | In fullscreen video |
|---|---|---|---|
| Quick pinch | `Return` | Select | Show OSD |
| Pinch and hold (~0.5s) | `Return` held | Context menu | Play/pause |
| Drag left / right | `Left` / `Right` | Navigate | Seek back / forward |
| Drag up / down | `Up` / `Down` | Navigate | Chapter or big step |
| Drag right from the left edge | `Escape` | Previous menu | Exit fullscreen |
| Clearly diagonal drag | — | Ignored | Ignored |

Drags need roughly 40 points of travel. Direction is resolved from the *total*
displacement when you release, not from the first movement detected — early
measurement is dominated by hand acceleration out of the pinch and reads clean
sweeps as diagonals.

Hold until the context menu appears; it arrives at a fixed delay rather than
being measured against how long you hold.

### Bluetooth keyboard

A paired Bluetooth keyboard works throughout, including text entry into Kodi's
on-screen keyboard. `XBMCController` conforms to `UIKeyInput` and suppresses the
system software keyboard.

### Window

Drag a corner to resize. The GUI scales with it; aspect ratio is locked. Kodi's
internal resolution never changes.

---

## Files of interest

| Path | Purpose |
|---|---|
| `xbmc/platform/darwin/visionos/XBMCApplication.mm` | App delegate; scene geometry request |
| `xbmc/platform/darwin/visionos/XBMCController.mm` | Root view controller; key injection; BT keyboard; window appearance |
| `xbmc/platform/darwin/visionos/VisionOSGLView.mm` | ANGLE/Metal EGL view; gaze/pinch handling |
| `xbmc/platform/darwin/visionos/VisionOSDisplayManager.mm` | Screen size and refresh rate |
| `xbmc/windowing/visionos/WinSystemVisionOS.mm` | Window system; resolution reporting |

---

## Notes for reviewers

Things that look wrong but are not:

- `getScreenSize` returning a constant — the desktop is fixed by design
- The geometry request being made after `makeKeyAndVisible` — `windowScene` is
  nil before then
- A second `KEYDOWN` being sent while a pinch is held — Kodi computes hold time
  only when the same keysym arrives again (`CKeyboardStat::TranslateKey`), so a
  single down/up pair can never produce a long-press no matter how long it is
  held
- No hover style on the view — a gesture recognizer alone is sufficient to
  advertise interactivity for gaze-pinch delivery, and a hover highlight would
  contradict focus-based selection

Open questions worth discussing:

- ANGLE as a platform dependency: build system, CI, maintenance
- Whether the fixed-desktop model should be configurable rather than hardcoded
