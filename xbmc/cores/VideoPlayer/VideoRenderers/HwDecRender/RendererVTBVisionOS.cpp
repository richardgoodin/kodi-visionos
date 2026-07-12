/*
 *  Copyright (C) 2005-2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "RendererVTBVisionOS.h"

#include "../RenderFactory.h"
#include "cores/VideoPlayer/DVDCodecs/Video/VTB.h"
#include "utils/GLUtils.h"
#include "utils/log.h"

#include <CoreVideo/CVBuffer.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <IOSurface/IOSurfaceRef.h>

namespace
{
// One-time: a pbuffer + bind-to-texture-RGBA config for IOSurface client buffers.
EGLConfig ChoosePbufferConfig(EGLDisplay dpy)
{
  const EGLint attribs[] = {EGL_SURFACE_TYPE,          EGL_PBUFFER_BIT,
                            EGL_RENDERABLE_TYPE,       EGL_OPENGL_ES2_BIT,
                            EGL_RED_SIZE,              8,
                            EGL_GREEN_SIZE,            8,
                            EGL_BLUE_SIZE,             8,
                            EGL_ALPHA_SIZE,            8,
                            EGL_BIND_TO_TEXTURE_RGBA,  EGL_TRUE,
                            EGL_NONE};
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (!eglChooseConfig(dpy, attribs, &config, 1, &numConfigs) || numConfigs < 1)
  {
    CLog::Log(LOGERROR, "CRendererVTBVisionOS: eglChooseConfig failed (err 0x{:x})",
              static_cast<unsigned>(eglGetError()));
    return nullptr;
  }
  return config;
}
} // namespace

CRendererVTBVisionOS::~CRendererVTBVisionOS()
{
  for (int i = 0; i < NUM_BUFFERS; ++i)
  {
    ReleaseBuffer(i);
    DeleteTexture(i);
  }
}

CBaseRenderer* CRendererVTBVisionOS::Create(CVideoBuffer* buffer)
{
  VTB::CVideoBufferVTB* vb = dynamic_cast<VTB::CVideoBufferVTB*>(buffer);
  if (vb)
    return new CRendererVTBVisionOS();
  return nullptr;
}

bool CRendererVTBVisionOS::Register()
{
  VIDEOPLAYER::CRendererFactory::RegisterRenderer("vtbvisionos", CRendererVTBVisionOS::Create);
  return true;
}

EShaderFormat CRendererVTBVisionOS::GetShaderFormat()
{
  return SHADER_NV12;
}

bool CRendererVTBVisionOS::LoadShadersHook()
{
  CLog::Log(LOGINFO, "CRendererVTBVisionOS: using VideoToolbox IOSurface (ANGLE) render method");
  m_textureTarget = GL_TEXTURE_2D;
  m_eglDisplay = eglGetCurrentDisplay();
  return false;
}

bool CRendererVTBVisionOS::CreateTexture(int index)
{
  CPictureBuffer& buf = m_buffers[index];
  YuvImage& im = buf.image;
  CYuvPlane(&planes)[YuvImage::MAX_PLANES] = buf.fields[0];

  ReleaseBuffer(index);
  DeleteTexture(index);

  memset(&im, 0, sizeof(im));
  memset(&planes, 0, sizeof(CYuvPlane[YuvImage::MAX_PLANES]));
  im.bpp = 1;
  im.width = m_sourceWidth;
  im.height = m_sourceHeight;
  im.cshift_x = 1;
  im.cshift_y = 1;

  planes[0].texwidth = im.width;
  planes[0].texheight = im.height;
  planes[1].texwidth = planes[0].texwidth >> im.cshift_x;
  planes[1].texheight = planes[0].texheight >> im.cshift_y;
  planes[2].texwidth = planes[1].texwidth;
  planes[2].texheight = planes[1].texheight;

  for (int p = 0; p < 3; p++)
  {
    planes[p].pixpertex_x = 1;
    planes[p].pixpertex_y = 1;
  }

  glGenTextures(1, &planes[0].id);
  glGenTextures(1, &planes[1].id);
  planes[2].id = planes[1].id;

  return true;
}

void CRendererVTBVisionOS::DeleteTexture(int index)
{
  CPictureBuffer& buf = m_buffers[index];
  CYuvPlane(&planes)[YuvImage::MAX_PLANES] = buf.fields[0];
  CRenderBuffer& renderBuf = m_vtbBuffers[index];

  if (m_eglDisplay != EGL_NO_DISPLAY)
  {
    if (renderBuf.m_eglSurfaceY != EGL_NO_SURFACE)
    {
      eglReleaseTexImage(m_eglDisplay, renderBuf.m_eglSurfaceY, EGL_BACK_BUFFER);
      eglDestroySurface(m_eglDisplay, renderBuf.m_eglSurfaceY);
      renderBuf.m_eglSurfaceY = EGL_NO_SURFACE;
    }
    if (renderBuf.m_eglSurfaceUV != EGL_NO_SURFACE)
    {
      eglReleaseTexImage(m_eglDisplay, renderBuf.m_eglSurfaceUV, EGL_BACK_BUFFER);
      eglDestroySurface(m_eglDisplay, renderBuf.m_eglSurfaceUV);
      renderBuf.m_eglSurfaceUV = EGL_NO_SURFACE;
    }
  }

  buf.loaded = false;
  if (planes[0].id && glIsTexture(planes[0].id))
    glDeleteTextures(1, &planes[0].id);
  if (planes[1].id && glIsTexture(planes[1].id))
    glDeleteTextures(1, &planes[1].id);
  planes[0].id = 0;
  planes[1].id = 0;
  planes[2].id = 0;
}

bool CRendererVTBVisionOS::UploadTexture(int index)
{
  CPictureBuffer& buf = m_buffers[index];
  CYuvPlane(&planes)[YuvImage::MAX_PLANES] = m_buffers[index].fields[0];
  CRenderBuffer& renderBuf = m_vtbBuffers[index];

  VTB::CVideoBufferVTB* vb = dynamic_cast<VTB::CVideoBufferVTB*>(buf.videoBuffer);
  if (!vb)
    return false;

  CVImageBufferRef cvBufferRef = vb->GetPB();
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(cvBufferRef);
  if (!surface)
  {
    CLog::Log(LOGERROR, "CRendererVTBVisionOS: pixel buffer has no IOSurface");
    return false;
  }

  const OSType format_type = IOSurfaceGetPixelFormat(surface);
  if (format_type != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
      format_type != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
  {
    CLog::Log(LOGERROR, "CRendererVTBVisionOS: unexpected IOSurface format 0x{:x}",
              static_cast<unsigned>(format_type));
    return false;
  }
  if (IOSurfaceGetPlaneCount(surface) != 2)
    return false;

  if (m_eglDisplay == EGL_NO_DISPLAY)
    m_eglDisplay = eglGetCurrentDisplay();

  static EGLConfig s_config = ChoosePbufferConfig(m_eglDisplay);
  if (!s_config)
    return false;

  // Release the previous frame's surfaces bound to this slot.
  if (renderBuf.m_eglSurfaceY != EGL_NO_SURFACE)
  {
    eglReleaseTexImage(m_eglDisplay, renderBuf.m_eglSurfaceY, EGL_BACK_BUFFER);
    eglDestroySurface(m_eglDisplay, renderBuf.m_eglSurfaceY);
    renderBuf.m_eglSurfaceY = EGL_NO_SURFACE;
  }
  if (renderBuf.m_eglSurfaceUV != EGL_NO_SURFACE)
  {
    eglReleaseTexImage(m_eglDisplay, renderBuf.m_eglSurfaceUV, EGL_BACK_BUFFER);
    eglDestroySurface(m_eglDisplay, renderBuf.m_eglSurfaceUV);
    renderBuf.m_eglSurfaceUV = EGL_NO_SURFACE;
  }

  struct PlaneDesc
  {
    int plane;
    GLuint tex;
    GLint internalFormat;
    EGLSurface* out;
  };
  const PlaneDesc descs[2] = {
      {0, planes[0].id, GL_RED, &renderBuf.m_eglSurfaceY},
      {1, planes[1].id, GL_RG, &renderBuf.m_eglSurfaceUV},
  };

  for (const PlaneDesc& d : descs)
  {
    const GLsizei w = IOSurfaceGetWidthOfPlane(surface, d.plane);
    const GLsizei h = IOSurfaceGetHeightOfPlane(surface, d.plane);
    const EGLint attribs[] = {EGL_WIDTH,
                              w,
                              EGL_HEIGHT,
                              h,
                              EGL_IOSURFACE_PLANE_ANGLE,
                              d.plane,
                              EGL_TEXTURE_TARGET,
                              EGL_TEXTURE_2D,
                              EGL_TEXTURE_FORMAT,
                              EGL_TEXTURE_RGBA,
                              EGL_TEXTURE_INTERNAL_FORMAT_ANGLE,
                              d.internalFormat,
                              EGL_TEXTURE_TYPE_ANGLE,
                              GL_UNSIGNED_BYTE,
                              EGL_NONE};

    EGLSurface eglSurface = eglCreatePbufferFromClientBuffer(
        m_eglDisplay, EGL_IOSURFACE_ANGLE, reinterpret_cast<EGLClientBuffer>(surface), s_config,
        attribs);
    if (eglSurface == EGL_NO_SURFACE)
    {
      CLog::Log(LOGERROR,
                "CRendererVTBVisionOS: eglCreatePbufferFromClientBuffer plane {} failed (err 0x{:x})",
                d.plane, static_cast<unsigned>(eglGetError()));
      return false;
    }

    glBindTexture(m_textureTarget, d.tex);
    if (!eglBindTexImage(m_eglDisplay, eglSurface, EGL_BACK_BUFFER))
    {
      CLog::Log(LOGERROR, "CRendererVTBVisionOS: eglBindTexImage plane {} failed (err 0x{:x})",
                d.plane, static_cast<unsigned>(eglGetError()));
      eglDestroySurface(m_eglDisplay, eglSurface);
      return false;
    }

    glTexParameteri(m_textureTarget, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(m_textureTarget, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(m_textureTarget, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(m_textureTarget, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    if (d.plane == 1)
    {
      // Kodi NV12 shader reads Cb from .g and Cr from .a (it expects a
      // GL_LUMINANCE_ALPHA layout). Our IOSurface plane is GL_RG, so swizzle
      // .g->R (Cb) and .a->G (Cr) to match without editing the shader.
      glTexParameteri(m_textureTarget, GL_TEXTURE_SWIZZLE_G, GL_RED);
      glTexParameteri(m_textureTarget, GL_TEXTURE_SWIZZLE_A, GL_GREEN);
    }

    *d.out = eglSurface;
  }

  glBindTexture(m_textureTarget, 0);

  CalculateTextureSourceRects(index, 3);
  return true;
}

void CRendererVTBVisionOS::ReleaseBuffer(int idx)
{
  CPictureBuffer& buf = m_buffers[idx];
  CRenderBuffer& renderBuf = m_vtbBuffers[idx];

  if (m_eglDisplay != EGL_NO_DISPLAY)
  {
    if (renderBuf.m_eglSurfaceY != EGL_NO_SURFACE)
    {
      eglReleaseTexImage(m_eglDisplay, renderBuf.m_eglSurfaceY, EGL_BACK_BUFFER);
      eglDestroySurface(m_eglDisplay, renderBuf.m_eglSurfaceY);
      renderBuf.m_eglSurfaceY = EGL_NO_SURFACE;
    }
    if (renderBuf.m_eglSurfaceUV != EGL_NO_SURFACE)
    {
      eglReleaseTexImage(m_eglDisplay, renderBuf.m_eglSurfaceUV, EGL_BACK_BUFFER);
      eglDestroySurface(m_eglDisplay, renderBuf.m_eglSurfaceUV);
      renderBuf.m_eglSurfaceUV = EGL_NO_SURFACE;
    }
  }

  if (renderBuf.m_fence && glIsSync(renderBuf.m_fence))
  {
    glDeleteSync(renderBuf.m_fence);
    renderBuf.m_fence = nullptr;
  }

  if (buf.videoBuffer)
  {
    buf.videoBuffer->Release();
    buf.videoBuffer = nullptr;
  }
}

void CRendererVTBVisionOS::AfterRenderHook(int idx)
{
  CRenderBuffer& renderBuf = m_vtbBuffers[idx];
  if (renderBuf.m_fence && glIsSync(renderBuf.m_fence))
    glDeleteSync(renderBuf.m_fence);
  renderBuf.m_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
}

bool CRendererVTBVisionOS::NeedBuffer(int idx)
{
  CRenderBuffer& renderBuf = m_vtbBuffers[idx];
  if (renderBuf.m_fence && glIsSync(renderBuf.m_fence))
  {
    GLint syncState = GL_UNSIGNALED;
    GLsizei len = 0;
    glGetSynciv(renderBuf.m_fence, GL_SYNC_STATUS, 1, &len, &syncState);
    if (syncState != GL_SIGNALED)
      return true;
  }
  return false;
}
