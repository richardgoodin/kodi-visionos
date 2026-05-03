/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "windowing/OSScreenSaver.h"

class COSScreenSaverVisionOS : public KODI::WINDOWING::IOSScreenSaver
{
public:
  void Inhibit() override;
  void Uninhibit() override;
};
