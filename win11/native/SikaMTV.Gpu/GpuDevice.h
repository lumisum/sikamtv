#pragma once

#include <Windows.h>
#include <unknwn.h>

#if defined(SIKAMTV_GPU_EXPORTS)
#define SIKAMTV_GPU_API extern "C" __declspec(dllexport)
#else
#define SIKAMTV_GPU_API extern "C" __declspec(dllimport)
#endif

// Prefers the high-performance NVIDIA adapter, then falls back to another hardware D3D11 adapter.
SIKAMTV_GPU_API int __cdecl SikaMTV_InitializeGpu(wchar_t* adapterName, int capacity, int* isNvidia);
SIKAMTV_GPU_API int __cdecl SikaMTV_AttachSwapChainPanel(IUnknown* panel, unsigned int width, unsigned int height);
SIKAMTV_GPU_API int __cdecl SikaMTV_ResizeSwapChainPanel(unsigned int width, unsigned int height);
SIKAMTV_GPU_API int __cdecl SikaMTV_SetBackgroundImage(const unsigned char* pixels, unsigned int width, unsigned int height, unsigned int stride);
SIKAMTV_GPU_API void __cdecl SikaMTV_ClearBackgroundImage();
SIKAMTV_GPU_API int __cdecl SikaMTV_RenderVisualizer(float timeSeconds, unsigned int visualizerKind, float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow, const float* bands, int bandCount);
SIKAMTV_GPU_API int __cdecl SikaMTV_RenderExportFrame(unsigned int width, unsigned int height, float timeSeconds, unsigned int visualizerKind, float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow, const float* bands, int bandCount, unsigned char* bgra, int capacity);
SIKAMTV_GPU_API int __cdecl SikaMTV_UpdatePreviewBackgroundVideo(const wchar_t* path, double timeSeconds, int loop);
SIKAMTV_GPU_API void __cdecl SikaMTV_StopPreviewBackgroundVideo();
SIKAMTV_GPU_API int __cdecl SikaMTV_StartVideoExport(const wchar_t* backgroundVideoPath, const wchar_t* audioPath, const wchar_t* outputPath, const wchar_t* textTimeline, const wchar_t* title, const wchar_t* author, const wchar_t* date, const wchar_t* fontFamily, double audioDurationSeconds, double outputDurationSeconds, unsigned int width, unsigned int height, unsigned int visualizerKind, float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow, float lyricFontSize, float lyricPosition, int lyricWindowCount, int lyricAnimation, int articleMode, float articleFontSize, float articleLineSpacing, float introDuration, int showIntroDate, int introAnimation, int loopBackgroundVideo);
SIKAMTV_GPU_API void __cdecl SikaMTV_GetVideoExportProgress(float* progress, int* isRunning, int* result);
SIKAMTV_GPU_API void __cdecl SikaMTV_CancelVideoExport();
SIKAMTV_GPU_API int __cdecl SikaMTV_GetExportD3DDevice(IUnknown** device);
SIKAMTV_GPU_API void __cdecl SikaMTV_DetachSwapChainPanel();
SIKAMTV_GPU_API void __cdecl SikaMTV_ShutdownGpu();
SIKAMTV_GPU_API int __cdecl SikaMTV_GetFontFamily(const wchar_t* path, wchar_t* familyName, int capacity);
