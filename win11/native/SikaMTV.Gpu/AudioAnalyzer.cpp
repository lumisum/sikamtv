#include "AudioAnalyzer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace
{
    constexpr UINT BandTotal = 64;
    constexpr size_t FftSize = 1024;
    constexpr UINT SampleRate = 22050;

    std::mutex StateMutex;
    std::condition_variable StateChanged;
    std::wstring SourcePath;
    std::uint64_t SourceVersion = 0;
    double DesiredPosition = 0;
    bool IsPlaying = false;
    std::array<float, BandTotal> PublishedBands{};
    std::atomic<float> AudioSmoothing{ 0.72f };
    std::atomic<float> AnalysisProgress{ 0 };
    std::atomic<bool> AnalysisCancelled{ false };
    std::jthread Worker;
    std::once_flag WorkerStarted;
    std::once_flag MediaFoundationStarted;

    void ComputeBands(const std::vector<float>& samples, std::array<float, BandTotal>& result)
    {
        if (samples.empty())
        {
            result.fill(0);
            return;
        }

        std::array<std::complex<float>, FftSize> values{};
        const auto count = std::min(samples.size(), FftSize);
        const auto offset = samples.size() - count;
        for (size_t index = 0; index < count; ++index)
        {
            const auto window = 0.5f - 0.5f * std::cos(6.28318530718f * static_cast<float>(index) / static_cast<float>(FftSize - 1));
            values[index] = std::complex<float>(samples[offset + index] * window, 0);
        }

        size_t reversed = 0;
        for (size_t index = 1; index < FftSize; ++index)
        {
            size_t bit = FftSize >> 1;
            while (reversed & bit)
            {
                reversed ^= bit;
                bit >>= 1;
            }
            reversed ^= bit;
            if (index < reversed) std::swap(values[index], values[reversed]);
        }

        for (size_t length = 2; length <= FftSize; length <<= 1)
        {
            const auto angle = -6.28318530718f / static_cast<float>(length);
            const std::complex<float> root(std::cos(angle), std::sin(angle));
            for (size_t start = 0; start < FftSize; start += length)
            {
                std::complex<float> factor(1, 0);
                for (size_t index = 0; index < length / 2; ++index)
                {
                    const auto even = values[start + index];
                    const auto odd = values[start + index + length / 2] * factor;
                    values[start + index] = even + odd;
                    values[start + index + length / 2] = even - odd;
                    factor *= root;
                }
            }
        }

        for (UINT band = 0; band < BandTotal; ++band)
        {
            const auto low = std::max<size_t>(1, static_cast<size_t>(std::pow(static_cast<double>(FftSize / 2), static_cast<double>(band) / BandTotal)));
            const auto high = std::max(low + 1, static_cast<size_t>(std::pow(static_cast<double>(FftSize / 2), static_cast<double>(band + 1) / BandTotal)));
            float energy = 0;
            size_t bins = 0;
            for (size_t bin = low; bin < std::min(high, FftSize / 2); ++bin)
            {
                energy += std::abs(values[bin]);
                ++bins;
            }
            const auto magnitude = bins == 0 ? 0 : energy / static_cast<float>(bins * FftSize);
            result[band] = std::clamp(std::log1p(magnitude * 700.0f), 0.0f, 1.0f);
        }
    }

    HRESULT CreateReader(const std::wstring& path, ComPtr<IMFSourceReader>& reader)
    {
        ComPtr<IMFAttributes> attributes;
        auto result = MFCreateAttributes(attributes.GetAddressOf(), 2);
        if (FAILED(result)) return result;
        result = MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(), reader.GetAddressOf());
        if (FAILED(result)) return result;

        ComPtr<IMFMediaType> mediaType;
        result = MFCreateMediaType(mediaType.GetAddressOf());
        if (FAILED(result)) return result;
        mediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        mediaType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
        mediaType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
        mediaType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, SampleRate);
        mediaType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
        mediaType->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, sizeof(float));
        mediaType->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, SampleRate * sizeof(float));
        return reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, mediaType.Get());
    }

    void AnalyzerWorker(std::stop_token stopToken)
    {
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        std::call_once(MediaFoundationStarted, [] { MFStartup(MF_VERSION, MFSTARTUP_LITE); });

        ComPtr<IMFSourceReader> reader;
        std::wstring readerPath;
        std::uint64_t readerVersion = 0;
        double decodedThrough = 0;
        std::vector<float> ring;
        ring.reserve(FftSize * 2);

        while (!stopToken.stop_requested())
        {
            std::wstring path;
            std::uint64_t version = 0;
            double target = 0;
            bool playing = false;
            {
                std::unique_lock lock(StateMutex);
                StateChanged.wait_for(lock, std::chrono::milliseconds(12));
                path = SourcePath;
                version = SourceVersion;
                target = DesiredPosition;
                playing = IsPlaying;
            }
            if (stopToken.stop_requested()) break;

            if (version != readerVersion || path != readerPath)
            {
                reader.Reset();
                readerPath = path;
                readerVersion = version;
                decodedThrough = 0;
                ring.clear();
                if (!path.empty()) CreateReader(path, reader);
            }
            if (!reader || !playing) continue;

            if (std::abs(target - decodedThrough) > 0.42)
            {
                PROPVARIANT seek{};
                if (SUCCEEDED(InitPropVariantFromInt64(static_cast<LONGLONG>(target * 10000000.0), &seek)))
                {
                    reader->SetCurrentPosition(GUID_NULL, seek);
                    PropVariantClear(&seek);
                    decodedThrough = target;
                    ring.clear();
                }
            }

            if (decodedThrough > target + 0.24) continue;

            DWORD streamIndex = 0;
            DWORD flags = 0;
            LONGLONG sampleTime = 0;
            ComPtr<IMFSample> sample;
            auto result = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &streamIndex, &flags, &sampleTime, sample.GetAddressOf());
            if (FAILED(result))
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(30));
                continue;
            }
            if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0)
            {
                decodedThrough = -1;
                continue;
            }
            if (!sample) continue;

            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf()))) continue;
            BYTE* bytes = nullptr;
            DWORD maximumLength = 0;
            DWORD currentLength = 0;
            if (FAILED(buffer->Lock(&bytes, &maximumLength, &currentLength))) continue;
            const auto sampleCount = currentLength / sizeof(float);
            const auto* audio = reinterpret_cast<const float*>(bytes);
            for (DWORD index = 0; index < sampleCount; ++index) ring.push_back(std::clamp(audio[index], -1.0f, 1.0f));
            buffer->Unlock();

            if (ring.size() > FftSize * 2) ring.erase(ring.begin(), ring.begin() + static_cast<ptrdiff_t>(ring.size() - FftSize * 2));
            std::array<float, BandTotal> bands{};
            ComputeBands(ring, bands);
            {
                std::scoped_lock lock(StateMutex);
                const auto smoothing = AudioSmoothing.load(std::memory_order_relaxed);
                const auto attack = 0.82f - smoothing * 0.44f;
                const auto release = 0.50f - smoothing * 0.38f;
                for (UINT index = 0; index < BandTotal; ++index)
                {
                    const auto coefficient = bands[index] > PublishedBands[index] ? attack : release;
                    PublishedBands[index] += (bands[index] - PublishedBands[index]) * coefficient;
                }
            }

            double duration = sampleCount / static_cast<double>(SampleRate);
            if (SUCCEEDED(sample->GetSampleDuration(&sampleTime))) duration = sampleTime / 10000000.0;
            LONGLONG pts = 0;
            if (SUCCEEDED(sample->GetSampleTime(&pts))) decodedThrough = pts / 10000000.0 + duration;
            else decodedThrough += duration;
        }

        reader.Reset();
        MFShutdown();
        CoUninitialize();
    }

    void EnsureWorker()
    {
        std::call_once(WorkerStarted, [] { Worker = std::jthread(AnalyzerWorker); });
    }
}

void __cdecl SikaMTV_SetAudioSource(const wchar_t* path)
{
    EnsureWorker();
    {
        std::scoped_lock lock(StateMutex);
        SourcePath = path == nullptr ? L"" : path;
        ++SourceVersion;
        DesiredPosition = 0;
        PublishedBands.fill(0);
    }
    StateChanged.notify_all();
}

void __cdecl SikaMTV_SetAudioPlaybackState(double positionSeconds, int isPlaying)
{
    EnsureWorker();
    {
        std::scoped_lock lock(StateMutex);
        DesiredPosition = std::max(0.0, positionSeconds);
        IsPlaying = isPlaying != 0;
    }
    StateChanged.notify_all();
}

void __cdecl SikaMTV_SetAudioSmoothing(float amount)
{
    if (!std::isfinite(amount)) return;
    AudioSmoothing.store(std::clamp(amount, 0.0f, 1.0f), std::memory_order_relaxed);
}

void __cdecl SikaMTV_CopyAudioBands(float* bands, int capacity)
{
    if (bands == nullptr || capacity <= 0) return;
    std::scoped_lock lock(StateMutex);
    const auto count = std::min(capacity, static_cast<int>(BandTotal));
    std::copy_n(PublishedBands.begin(), count, bands);
}

int __cdecl SikaMTV_AnalyzeAudioFile(const wchar_t* path, float* frameBands, int frameCapacity, int* framesWritten, double* durationSeconds)
{
    if (path == nullptr || path[0] == L'\0' || frameBands == nullptr || frameCapacity <= 0 || framesWritten == nullptr || durationSeconds == nullptr)
        return E_INVALIDARG;

    *framesWritten = 0;
    *durationSeconds = 0;
    AnalysisProgress.store(0, std::memory_order_relaxed);
    const auto comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninitializeCom = SUCCEEDED(comResult);
    if (FAILED(comResult) && comResult != RPC_E_CHANGED_MODE) return comResult;

    auto result = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    if (FAILED(result))
    {
        if (uninitializeCom) CoUninitialize();
        return result;
    }

    ComPtr<IMFSourceReader> reader;
    result = CreateReader(path, reader);
    if (FAILED(result)) goto cleanup;

    {
        PROPVARIANT durationValue;
        PropVariantInit(&durationValue);
        if (SUCCEEDED(reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &durationValue)))
        {
            LONGLONG duration100ns = 0;
            if (SUCCEEDED(PropVariantToInt64(durationValue, &duration100ns)) && duration100ns > 0)
                *durationSeconds = duration100ns / 10000000.0;
        }
        PropVariantClear(&durationValue);
    }

    if (*durationSeconds > 0 && std::ceil(*durationSeconds * 30.0) > frameCapacity)
    {
        result = HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
        goto cleanup;
    }

    {
        std::array<float, FftSize> ring{};
        std::vector<float> window(FftSize, 0.0f);
        size_t writeIndex = 0;
        std::uint64_t totalSamples = 0;
        int frameIndex = 0;

        for (;;)
        {
            if (AnalysisCancelled.load(std::memory_order_relaxed))
            {
                result = HRESULT_FROM_WIN32(ERROR_CANCELLED);
                break;
            }
            DWORD streamIndex = 0;
            DWORD flags = 0;
            LONGLONG sampleTime = 0;
            ComPtr<IMFSample> sample;
            result = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &streamIndex, &flags, &sampleTime, sample.GetAddressOf());
            if (FAILED(result)) break;
            if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
            if (!sample) continue;

            ComPtr<IMFMediaBuffer> buffer;
            result = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
            if (FAILED(result)) break;
            BYTE* bytes = nullptr;
            DWORD maximumLength = 0;
            DWORD currentLength = 0;
            result = buffer->Lock(&bytes, &maximumLength, &currentLength);
            if (FAILED(result)) break;
            const auto sampleCount = currentLength / sizeof(float);
            const auto* samples = reinterpret_cast<const float*>(bytes);
            for (DWORD sample = 0; sample < sampleCount; ++sample)
            {
                ring[writeIndex] = std::clamp(samples[sample], -1.0f, 1.0f);
                writeIndex = (writeIndex + 1) % FftSize;
                ++totalSamples;
            }
            buffer->Unlock();
            if (*durationSeconds > 0)
                AnalysisProgress.store(static_cast<float>(std::clamp(totalSamples / (SampleRate * *durationSeconds), 0.0, 1.0)), std::memory_order_relaxed);

            while (frameIndex < frameCapacity &&
                   static_cast<std::uint64_t>(frameIndex) * SampleRate / 30 <= totalSamples)
            {
                const auto validSamples = static_cast<size_t>(std::min<std::uint64_t>(totalSamples, FftSize));
                std::fill(window.begin(), window.end(), 0.0f);
                const auto first = (writeIndex + FftSize - validSamples) % FftSize;
                const auto padding = FftSize - validSamples;
                for (size_t sample = 0; sample < validSamples; ++sample)
                    window[padding + sample] = ring[(first + sample) % FftSize];

                std::array<float, BandTotal> bands{};
                ComputeBands(window, bands);
                std::copy(bands.begin(), bands.end(), frameBands + static_cast<size_t>(frameIndex) * BandTotal);
                ++frameIndex;
            }
        }

        if (SUCCEEDED(result))
        {
            if (*durationSeconds <= 0) *durationSeconds = totalSamples / static_cast<double>(SampleRate);
            *framesWritten = frameIndex;
            if (frameIndex == 0) result = MF_E_INVALID_FILE_FORMAT;
            else AnalysisProgress.store(1, std::memory_order_relaxed);
        }
    }

cleanup:
    reader.Reset();
    MFShutdown();
    if (uninitializeCom) CoUninitialize();
    return result;
}

float __cdecl SikaMTV_GetAudioAnalysisProgress()
{
    return AnalysisProgress.load(std::memory_order_relaxed);
}

void __cdecl SikaMTV_SetAudioAnalysisCancelled(int cancelled)
{
    AnalysisCancelled.store(cancelled != 0, std::memory_order_relaxed);
    if (!cancelled) AnalysisProgress.store(0, std::memory_order_relaxed);
}
