#pragma once

#include <Windows.h>

#if defined(SIKAMTV_GPU_EXPORTS)
#define SIKAMTV_AUDIO_API extern "C" __declspec(dllexport)
#else
#define SIKAMTV_AUDIO_API extern "C" __declspec(dllimport)
#endif

SIKAMTV_AUDIO_API void __cdecl SikaMTV_SetAudioSource(const wchar_t* path);
SIKAMTV_AUDIO_API void __cdecl SikaMTV_SetAudioPlaybackState(double positionSeconds, int isPlaying);
SIKAMTV_AUDIO_API void __cdecl SikaMTV_SetAudioSmoothing(float amount);
SIKAMTV_AUDIO_API void __cdecl SikaMTV_CopyAudioBands(float* bands, int capacity);
SIKAMTV_AUDIO_API int __cdecl SikaMTV_AnalyzeAudioFile(const wchar_t* path, float* frameBands, int frameCapacity, int* framesWritten, double* durationSeconds);
SIKAMTV_AUDIO_API float __cdecl SikaMTV_GetAudioAnalysisProgress();
SIKAMTV_AUDIO_API void __cdecl SikaMTV_SetAudioAnalysisCancelled(int cancelled);
