/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include <CoreGraphics/CoreGraphics.h>

// The visionOS port renders a FIXED logical desktop and lets the system
// compositor scale it to whatever size the user has dragged the window to.
// Kodi is never told the window moved -- see README_visionos.md.
//
// These are the only dimensions Kodi ever sees, and all three consumers must
// agree or the fixed-desktop model silently breaks:
//
//   XBMCApplication.mm        launch size requested for the window scene
//   XBMCController.mm         the fixed frame glView is constructed with
//   VisionOSDisplayManager.mm the size reported up to CWinSystemVisionOS
//
// 1920x1080 is chosen to match the base resolution Kodi skins are authored
// against, so the GUI scales by an integer factor into the drawable.

constexpr CGFloat VISIONOS_DESKTOP_WIDTH = 1920.0;
constexpr CGFloat VISIONOS_DESKTOP_HEIGHT = 1080.0;

// UIScreen is unavailable on visionOS, so there is no device scale to query.
// The port fixes the logical scale instead: the drawable is always
// VISIONOS_DESKTOP_WIDTH x VISIONOS_DESKTOP_SCALE pixels wide.
constexpr CGFloat VISIONOS_DESKTOP_SCALE = 2.0;
