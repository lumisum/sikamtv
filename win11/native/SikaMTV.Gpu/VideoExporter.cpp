#include "GpuDevice.h"
#include "AudioAnalyzer.h"

#include <Windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace
{
    constexpr UINT AudioBandCount = 64;
    constexpr UINT VideoFps = 30;
    constexpr LONGLONG TicksPerSecond = 10'000'000;
    constexpr UINT AudioSampleRate = 48'000;
    constexpr UINT AudioChannels = 2;

    struct SubtitleLine
    {
        double start = 0;
        double end = 0;
        std::wstring text;
    };

    struct ExportRequest
    {
        std::wstring backgroundVideoPath;
        std::wstring audioPath;
        std::wstring outputPath;
        std::wstring textTimeline;
        std::wstring title;
        std::wstring author;
        std::wstring date;
        std::wstring fontFamily;
        double audioDuration = 0;
        double outputDuration = 0;
        UINT width = 0;
        UINT height = 0;
        UINT visualizerKind = 0;
        float intensity = 0;
        float blur = 0;
        float vignette = 0;
        float saturation = 1;
        float slowZoom = 0;
        float visualizerScale = 1;
        float rainbow = 1;
        float lyricFontSize = 46;
        float lyricPosition = 0.6f;
        int lyricWindowCount = 5;
        int lyricAnimation = 0;
        bool articleMode = false;
        float articleFontSize = 38;
        float articleLineSpacing = 1.68f;
        float introDuration = 12;
        bool showIntroDate = true;
        int introAnimation = 0;
        bool loopBackgroundVideo = true;
    };

    std::atomic<bool> ExportRunning{ false };
    std::atomic<bool> ExportCancelled{ false };
    std::atomic<float> ExportProgress{ 0 };
    std::atomic<int> ExportStage{ 0 };
    std::atomic<int> ExportResult{ E_PENDING };
    std::jthread ExportThread;

    struct TemporaryOutputFile
    {
        std::wstring path;
        bool committed = false;

        HRESULT Commit(const std::wstring& destination)
        {
            if (!MoveFileExW(path.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                return HRESULT_FROM_WIN32(GetLastError());
            committed = true;
            return S_OK;
        }

        ~TemporaryOutputFile()
        {
            if (!committed && !path.empty()) DeleteFileW(path.c_str());
        }
    };

    std::wstring SafeString(const wchar_t* value)
    {
        return value == nullptr ? std::wstring{} : std::wstring(value);
    }

    std::vector<SubtitleLine> ParseTimeline(const std::wstring& value)
    {
        std::vector<SubtitleLine> result;
        size_t cursor = 0;
        while (cursor < value.size())
        {
            const auto lineEnd = value.find(L'\n', cursor);
            const auto length = (lineEnd == std::wstring::npos ? value.size() : lineEnd) - cursor;
            const auto line = value.substr(cursor, length);
            const auto first = line.find(L'\t');
            const auto second = first == std::wstring::npos ? first : line.find(L'\t', first + 1);
            if (first != std::wstring::npos && second != std::wstring::npos && second + 1 < line.size())
            {
                try
                {
                    SubtitleLine cue;
                    cue.start = std::stod(line.substr(0, first));
                    cue.end = std::stod(line.substr(first + 1, second - first - 1));
                    cue.text = line.substr(second + 1);
                    if (!cue.text.empty() && cue.end >= cue.start) result.push_back(std::move(cue));
                }
                catch (...) { }
            }
            if (lineEnd == std::wstring::npos) break;
            cursor = lineEnd + 1;
        }
        std::stable_sort(result.begin(), result.end(), [](const auto& a, const auto& b) { return a.start < b.start; });
        return result;
    }

    HRESULT ReadDuration(IMFSourceReader* reader, double& seconds)
    {
        seconds = 0;
        PROPVARIANT value;
        PropVariantInit(&value);
        const auto result = reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &value);
        if (SUCCEEDED(result))
        {
            LONGLONG ticks = 0;
            if (SUCCEEDED(PropVariantToInt64(value, &ticks)) && ticks > 0) seconds = ticks / static_cast<double>(TicksPerSecond);
        }
        PropVariantClear(&value);
        return result;
    }

    HRESULT SeekReader(IMFSourceReader* reader, LONGLONG ticks)
    {
        PROPVARIANT position;
        PropVariantInit(&position);
        position.vt = VT_I8;
        position.hVal.QuadPart = ticks;
        const auto result = reader->SetCurrentPosition(GUID_NULL, position);
        PropVariantClear(&position);
        return result;
    }

    class BackgroundVideo
    {
    public:
        HRESULT Open(const std::wstring& path, bool shouldLoop)
        {
            loop = shouldLoop;
            ComPtr<IMFAttributes> attributes;
            auto result = MFCreateAttributes(attributes.GetAddressOf(), 2);
            if (FAILED(result)) return result;
            attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
            ComPtr<IUnknown> unknownDevice;
            if (SUCCEEDED(static_cast<HRESULT>(SikaMTV_GetExportD3DDevice(unknownDevice.GetAddressOf()))) && unknownDevice)
            {
                ComPtr<ID3D11Device> device;
                if (SUCCEEDED(unknownDevice.As(&device)))
                {
                    UINT resetToken = 0;
                    if (SUCCEEDED(MFCreateDXGIDeviceManager(&resetToken, deviceManager.GetAddressOf())) &&
                        SUCCEEDED(deviceManager->ResetDevice(device.Get(), resetToken)))
                        attributes->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, deviceManager.Get());
                    else deviceManager.Reset();
                }
            }
            result = MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(), reader.GetAddressOf());
            if (FAILED(result)) return result;

            ComPtr<IMFMediaType> mediaType;
            result = MFCreateMediaType(mediaType.GetAddressOf());
            if (FAILED(result)) return result;
            mediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
            mediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
            result = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, mediaType.Get());
            if (FAILED(result)) return result;

            ComPtr<IMFMediaType> currentType;
            result = reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, currentType.GetAddressOf());
            if (FAILED(result)) return result;
            UINT32 width = 0;
            UINT32 height = 0;
            result = MFGetAttributeSize(currentType.Get(), MF_MT_FRAME_SIZE, &width, &height);
            if (FAILED(result) || width == 0 || height == 0) return FAILED(result) ? result : MF_E_INVALIDMEDIATYPE;
            frameWidth = width;
            frameHeight = height;
            LONG defaultStride = static_cast<LONG>(width * 4);
            UINT32 rawStride = 0;
            if (SUCCEEDED(currentType->GetUINT32(MF_MT_DEFAULT_STRIDE, &rawStride))) defaultStride = static_cast<LONG>(rawStride);
            stride = defaultStride == 0 ? static_cast<LONG>(width * 4) : defaultStride;
            result = ReadDuration(reader.Get(), duration);
            if (FAILED(result) || duration <= 0) duration = 0;
            pixels.resize(static_cast<size_t>(frameWidth) * frameHeight * 4);
            return S_OK;
        }

        HRESULT Update(double seconds)
        {
            if (!reader) return E_UNEXPECTED;
            if (duration > 0 && loop) seconds = std::fmod(std::max(0.0, seconds), duration);
            const auto target = static_cast<LONGLONG>(seconds * TicksPerSecond);
            if (hasFrame && (target < currentTime || target - currentTime > 2 * TicksPerSecond))
            {
                auto seekResult = SeekReader(reader.Get(), target);
                if (FAILED(seekResult)) return seekResult;
                currentTime = -1;
                hasFrame = false;
            }
            while (!hasFrame || currentTime <= target)
            {
                DWORD stream = 0;
                DWORD flags = 0;
                LONGLONG sampleTime = 0;
                ComPtr<IMFSample> sample;
                auto result = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &sampleTime, sample.GetAddressOf());
                if (FAILED(result)) return result;
                if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0)
                {
                    if (!loop || duration <= 0) break;
                    result = SeekReader(reader.Get(), 0);
                    if (FAILED(result)) return result;
                    currentTime = -1;
                    continue;
                }
                if (!sample) continue;

                ComPtr<IMFMediaBuffer> buffer;
                result = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
                if (FAILED(result)) return result;
                BYTE* source = nullptr;
                DWORD maximum = 0;
                DWORD length = 0;
                result = buffer->Lock(&source, &maximum, &length);
                if (FAILED(result)) return result;
                const auto rowBytes = static_cast<size_t>(frameWidth) * 4;
                const auto sourceStride = static_cast<size_t>(std::abs(stride));
                const auto needed = sourceStride * frameHeight;
                if (length < needed)
                {
                    buffer->Unlock();
                    return MF_E_BUFFERTOOSMALL;
                }
                for (UINT row = 0; row < frameHeight; ++row)
                {
                    const UINT sourceRow = stride < 0 ? frameHeight - row - 1 : row;
                    std::memcpy(pixels.data() + static_cast<size_t>(row) * rowBytes,
                        source + static_cast<size_t>(sourceRow) * sourceStride, rowBytes);
                }
                buffer->Unlock();
                hasFrame = true;
                currentTime = sampleTime;
                if (currentTime > target) break;
            }

            if (!hasFrame) return MF_E_INVALID_FILE_FORMAT;
            return SikaMTV_SetBackgroundImage(pixels.data(), frameWidth, frameHeight, frameWidth * 4);
        }

        double duration = 0;

    private:
        ComPtr<IMFSourceReader> reader;
        UINT frameWidth = 0;
        UINT frameHeight = 0;
        LONG stride = 0;
        bool loop = true;
        bool hasFrame = false;
        LONGLONG currentTime = -1;
        std::vector<unsigned char> pixels;
        ComPtr<IMFDXGIDeviceManager> deviceManager;
    };

    struct PreviewVideoRequest
    {
        std::wstring path;
        double seconds = 0;
        bool loop = true;
        std::uint64_t version = 0;
    };

    std::mutex PreviewRequestMutex;
    std::mutex PreviewDecodeMutex;
    std::condition_variable PreviewRequestChanged;
    std::wstring PreviewRequestedPath;
    double PreviewRequestedSeconds = 0;
    bool PreviewRequestedLoop = true;
    std::uint64_t PreviewRequestVersion = 0;
    std::jthread PreviewVideoThread;
    std::atomic<bool> PreviewVideoWorkerRunning{ false };
    std::atomic<bool> PreviewVideoSuspended{ false };
    std::atomic<int> PreviewVideoResult{ S_OK };

    void PreviewVideoWorker(std::stop_token stopToken)
    {
        PreviewVideoWorkerRunning.store(true, std::memory_order_release);
        const auto comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        const bool uninitializeCom = SUCCEEDED(comResult);
        if (FAILED(comResult) && comResult != RPC_E_CHANGED_MODE)
        {
            PreviewVideoResult.store(comResult, std::memory_order_relaxed);
            PreviewVideoWorkerRunning.store(false, std::memory_order_release);
            return;
        }
        auto mfResult = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        if (FAILED(mfResult))
        {
            PreviewVideoResult.store(mfResult, std::memory_order_relaxed);
            if (uninitializeCom) CoUninitialize();
            PreviewVideoWorkerRunning.store(false, std::memory_order_release);
            return;
        }

        std::unique_ptr<BackgroundVideo> source;
        std::wstring openedPath;
        std::wstring failedPath;
        bool openedLoop = true;
        bool failedLoop = true;
        std::uint64_t processedVersion = 0;
        while (!stopToken.stop_requested())
        {
            PreviewVideoRequest request;
            {
                std::unique_lock lock(PreviewRequestMutex);
                PreviewRequestChanged.wait(lock, [&]
                {
                    return stopToken.stop_requested() || PreviewRequestVersion != processedVersion;
                });
                if (stopToken.stop_requested()) break;
                request = { PreviewRequestedPath, PreviewRequestedSeconds, PreviewRequestedLoop, PreviewRequestVersion };
            }

            if (request.path.empty())
            {
                source.reset();
                openedPath.clear();
                failedPath.clear();
                processedVersion = request.version;
                PreviewVideoResult.store(S_OK, std::memory_order_relaxed);
                continue;
            }
            if (request.path == failedPath && request.loop == failedLoop)
            {
                processedVersion = request.version;
                continue;
            }
            if (PreviewVideoSuspended.load(std::memory_order_acquire))
            {
                processedVersion = request.version;
                continue;
            }
            if (!source || openedPath != request.path || openedLoop != request.loop)
            {
                auto replacement = std::make_unique<BackgroundVideo>();
                mfResult = replacement->Open(request.path, request.loop);
                if (FAILED(mfResult))
                {
                    source.reset();
                    openedPath.clear();
                    failedPath = request.path;
                    failedLoop = request.loop;
                    PreviewVideoResult.store(mfResult, std::memory_order_relaxed);
                    processedVersion = request.version;
                    continue;
                }
                source = std::move(replacement);
                openedPath = request.path;
                failedPath.clear();
                openedLoop = request.loop;
            }

            HRESULT updateResult = S_OK;
            {
                std::scoped_lock decodeLock(PreviewDecodeMutex);
                if (!PreviewVideoSuspended.load(std::memory_order_acquire)) updateResult = source->Update(request.seconds);
            }
            PreviewVideoResult.store(updateResult, std::memory_order_relaxed);
            processedVersion = request.version;
        }

        source.reset();
        MFShutdown();
        if (uninitializeCom) CoUninitialize();
        PreviewVideoWorkerRunning.store(false, std::memory_order_release);
    }

    void SuspendPreviewVideo(bool suspended)
    {
        if (suspended)
        {
            PreviewVideoSuspended.store(true, std::memory_order_release);
            std::scoped_lock lock(PreviewDecodeMutex);
        }
        else
        {
            PreviewVideoSuspended.store(false, std::memory_order_release);
            {
                std::scoped_lock lock(PreviewRequestMutex);
                ++PreviewRequestVersion;
            }
            PreviewRequestChanged.notify_all();
        }
    }

    HRESULT CreateAudioReader(const std::wstring& path, ComPtr<IMFSourceReader>& reader)
    {
        ComPtr<IMFAttributes> attributes;
        auto result = MFCreateAttributes(attributes.GetAddressOf(), 2);
        if (FAILED(result)) return result;
        attributes->SetUINT32(MF_SOURCE_READER_ENABLE_AUDIO_PROCESSING, TRUE);
        result = MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(), reader.GetAddressOf());
        if (FAILED(result)) return result;

        ComPtr<IMFMediaType> outputType;
        result = MFCreateMediaType(outputType.GetAddressOf());
        if (FAILED(result)) return result;
        outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        outputType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        outputType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, AudioChannels);
        outputType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, AudioSampleRate);
        outputType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        outputType->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, AudioChannels * 2);
        outputType->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, AudioSampleRate * AudioChannels * 2);
        return reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, outputType.Get());
    }

    HRESULT ConfigureWriter(const ExportRequest& request, ComPtr<IMFSinkWriter>& writer, DWORD& videoIndex, DWORD& audioIndex)
    {
        ComPtr<IMFAttributes> attributes;
        auto result = MFCreateAttributes(attributes.GetAddressOf(), 4);
        if (FAILED(result)) return result;
        attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
        attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);

        ComPtr<IUnknown> unknownDevice;
        if (SUCCEEDED(static_cast<HRESULT>(SikaMTV_GetExportD3DDevice(unknownDevice.GetAddressOf()))) && unknownDevice)
        {
            ComPtr<ID3D11Device> device;
            if (SUCCEEDED(unknownDevice.As(&device)))
            {
                ComPtr<IMFDXGIDeviceManager> deviceManager;
                UINT resetToken = 0;
                if (SUCCEEDED(MFCreateDXGIDeviceManager(&resetToken, deviceManager.GetAddressOf())) &&
                    SUCCEEDED(deviceManager->ResetDevice(device.Get(), resetToken)))
                    attributes->SetUnknown(MF_SINK_WRITER_D3D_MANAGER, deviceManager.Get());
            }
        }

        result = MFCreateSinkWriterFromURL(request.outputPath.c_str(), nullptr, attributes.Get(), writer.GetAddressOf());
        if (FAILED(result)) return result;

        ComPtr<IMFMediaType> videoOutput;
        result = MFCreateMediaType(videoOutput.GetAddressOf());
        if (FAILED(result)) return result;
        videoOutput->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        videoOutput->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        videoOutput->SetUINT32(MF_MT_AVG_BITRATE, 16'000'000);
        videoOutput->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        MFSetAttributeSize(videoOutput.Get(), MF_MT_FRAME_SIZE, request.width, request.height);
        MFSetAttributeRatio(videoOutput.Get(), MF_MT_FRAME_RATE, VideoFps, 1);
        MFSetAttributeRatio(videoOutput.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        result = writer->AddStream(videoOutput.Get(), &videoIndex);
        if (FAILED(result)) return result;

        ComPtr<IMFMediaType> videoInput;
        result = MFCreateMediaType(videoInput.GetAddressOf());
        if (FAILED(result)) return result;
        videoInput->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        videoInput->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
        videoInput->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        MFSetAttributeSize(videoInput.Get(), MF_MT_FRAME_SIZE, request.width, request.height);
        MFSetAttributeRatio(videoInput.Get(), MF_MT_FRAME_RATE, VideoFps, 1);
        MFSetAttributeRatio(videoInput.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        result = writer->SetInputMediaType(videoIndex, videoInput.Get(), nullptr);
        if (FAILED(result)) return result;

        ComPtr<IMFMediaType> audioOutput;
        result = MFCreateMediaType(audioOutput.GetAddressOf());
        if (FAILED(result)) return result;
        audioOutput->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        audioOutput->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        audioOutput->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, AudioChannels);
        audioOutput->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, AudioSampleRate);
        audioOutput->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        audioOutput->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24'000);
        audioOutput->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
        audioOutput->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
        result = writer->AddStream(audioOutput.Get(), &audioIndex);
        if (FAILED(result)) return result;

        ComPtr<IMFMediaType> audioInput;
        result = MFCreateMediaType(audioInput.GetAddressOf());
        if (FAILED(result)) return result;
        audioInput->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        audioInput->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        audioInput->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, AudioChannels);
        audioInput->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, AudioSampleRate);
        audioInput->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        audioInput->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, AudioChannels * 2);
        audioInput->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, AudioSampleRate * AudioChannels * 2);
        return writer->SetInputMediaType(audioIndex, audioInput.Get(), nullptr);
    }

    struct TextSurface
    {
        HDC dc = nullptr;
        HBITMAP bitmap = nullptr;
        HGDIOBJ previousBitmap = nullptr;
        std::uint32_t* pixels = nullptr;
        UINT width = 0;
        UINT height = 0;
        std::map<std::tuple<std::wstring, int, int>, HFONT> fonts;

        bool Initialize(UINT w, UINT h)
        {
            width = w;
            height = h;
            dc = CreateCompatibleDC(nullptr);
            if (!dc) return false;
            BITMAPINFO info{};
            info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            info.bmiHeader.biWidth = static_cast<LONG>(width);
            info.bmiHeader.biHeight = -static_cast<LONG>(height);
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            void* data = nullptr;
            bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &data, nullptr, 0);
            if (!bitmap || !data) return false;
            pixels = static_cast<std::uint32_t*>(data);
            previousBitmap = SelectObject(dc, bitmap);
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, RGB(255, 255, 255));
            SetTextAlign(dc, TA_LEFT | TA_TOP | TA_NOUPDATECP);
            return true;
        }

        ~TextSurface()
        {
            for (const auto& entry : fonts) DeleteObject(entry.second);
            if (dc && previousBitmap) SelectObject(dc, previousBitmap);
            if (bitmap) DeleteObject(bitmap);
            if (dc) DeleteDC(dc);
        }

        RECT DrawMask(const std::wstring& text, const std::wstring& family, int fontSize, int weight, RECT rectangle, UINT format)
        {
            RECT bounds{
                std::clamp<LONG>(rectangle.left, 0, static_cast<LONG>(width)),
                std::clamp<LONG>(rectangle.top, 0, static_cast<LONG>(height)),
                std::clamp<LONG>(rectangle.right, 0, static_cast<LONG>(width)),
                std::clamp<LONG>(rectangle.bottom, 0, static_cast<LONG>(height))
            };
            if (bounds.right <= bounds.left || bounds.bottom <= bounds.top || text.empty()) return RECT{};
            for (LONG y = bounds.top; y < bounds.bottom; ++y)
                std::memset(pixels + static_cast<size_t>(y) * width + bounds.left, 0, static_cast<size_t>(bounds.right - bounds.left) * 4);

            const auto font = GetFont(family, fontSize, weight);
            if (!font) return RECT{};
            const auto oldFont = SelectObject(dc, font);
            RECT textBounds = bounds;
            DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &textBounds, format | DT_NOPREFIX | DT_WORDBREAK);
            SelectObject(dc, oldFont);
            return bounds;
        }

        LONG MeasureTextHeight(const std::wstring& text, const std::wstring& family, int fontSize, int weight, LONG textWidth)
        {
            const auto font = GetFont(family, fontSize, weight);
            if (!font || text.empty()) return std::max<LONG>(fontSize, 1);
            const auto oldFont = SelectObject(dc, font);
            RECT measured{ 0, 0, std::max<LONG>(textWidth, 1), 0 };
            DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &measured, DT_CALCRECT | DT_NOPREFIX | DT_WORDBREAK);
            SelectObject(dc, oldFont);
            return std::max<LONG>(fontSize, measured.bottom - measured.top);
        }

        void Composite(unsigned char* bgra, RECT area, float opacity, COLORREF color, bool shadow)
        {
            if (!bgra || opacity <= 0 || area.right <= area.left || area.bottom <= area.top) return;
            opacity = std::clamp(opacity, 0.0f, 1.0f);
            const auto blend = [bgra, this](LONG x, LONG y, unsigned char alpha, unsigned char blue, unsigned char green, unsigned char red)
            {
                if (x < 0 || y < 0 || x >= static_cast<LONG>(width) || y >= static_cast<LONG>(height) || alpha == 0) return;
                auto* pixel = bgra + (static_cast<size_t>(y) * width + static_cast<size_t>(x)) * 4;
                const auto inverse = 255 - alpha;
                pixel[0] = static_cast<unsigned char>((pixel[0] * inverse + blue * alpha + 127) / 255);
                pixel[1] = static_cast<unsigned char>((pixel[1] * inverse + green * alpha + 127) / 255);
                pixel[2] = static_cast<unsigned char>((pixel[2] * inverse + red * alpha + 127) / 255);
            };

            const LONG pad = shadow ? 3 : 0;
            for (LONG y = area.top; y < area.bottom; ++y)
            {
                for (LONG x = area.left; x < area.right; ++x)
                {
                    const auto mask = static_cast<unsigned char>((pixels[static_cast<size_t>(y) * width + x] >> 16) & 0xff);
                    if (mask == 0) continue;
                    const auto alpha = static_cast<unsigned char>(std::clamp(static_cast<int>(std::lround(mask * opacity)), 0, 255));
                    if (shadow) blend(x + 1, y + pad, static_cast<unsigned char>(alpha * 0.58f), 0, 0, 0);
                    blend(x, y, alpha, GetBValue(color), GetGValue(color), GetRValue(color));
                }
            }
        }

    private:
        HFONT GetFont(const std::wstring& family, int fontSize, int weight)
        {
            const auto key = std::make_tuple(family, fontSize, weight);
            auto found = fonts.find(key);
            if (found != fonts.end()) return found->second;
            const auto font = CreateFontW(-std::max(fontSize, 1), 0, 0, 0, weight, FALSE, FALSE, FALSE,
                DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                family.empty() ? L"Segoe UI" : family.c_str());
            if (!font) return nullptr;
            fonts.emplace(key, font);
            return font;
        }
    };

    float Ease(float value)
    {
        value = std::clamp(value, 0.0f, 1.0f);
        return value * value * (3.0f - 2.0f * value);
    }

    int CurrentCueIndex(const std::vector<SubtitleLine>& cues, double seconds)
    {
        const auto found = std::upper_bound(cues.begin(), cues.end(), seconds,
            [](double time, const SubtitleLine& cue) { return time < cue.start; });
        if (found == cues.begin()) return -1;
        return static_cast<int>(std::distance(cues.begin(), found) - 1);
    }

    void CompositeText(const ExportRequest& request, const std::vector<SubtitleLine>& cues, double seconds,
        TextSurface& surface, unsigned char* frame)
    {
        const bool landscape = request.width > request.height;
        const bool square = !landscape && request.width == request.height;
        const float scale = landscape ? request.width / 640.0f : square ? request.width / 580.0f : request.height / 640.0f;
        const float textMargin = landscape ? 0.258f : square ? 0.233f : 0.07f;
        const auto marginX = static_cast<LONG>(request.width * textMargin);
        const LONG textWidth = static_cast<LONG>(request.width) - marginX * 2;
        const int cueIndex = CurrentCueIndex(cues, seconds);

        if (!request.title.empty() && seconds < request.introDuration && request.introDuration > 0)
        {
            const float fadeIn = Ease(static_cast<float>(seconds / 0.8));
            const float fadeOut = Ease(static_cast<float>((request.introDuration - seconds) / 0.9));
            const float opacity = std::min(fadeIn, fadeOut);
            if (opacity > 0)
            {
                const float introScale = request.introAnimation == 2 ? 0.97f + fadeIn * 0.03f : 1.0f;
                const LONG top = static_cast<LONG>(request.height * (landscape ? 0.07 : 0.12) +
                    (request.introAnimation == 0 ? (1.0f - fadeIn) * request.height * 0.018f : 0));
                const LONG left = landscape ? static_cast<LONG>(request.width * 0.06) : marginX;
                const UINT alignment = landscape ? DT_LEFT : DT_CENTER;
                const auto titleDimension = landscape ? request.width : request.height;
                const auto titleSize = std::max(1, static_cast<int>(titleDimension * 0.053f * introScale));
                const auto authorSize = std::max(1, static_cast<int>(titleDimension * 0.024f * introScale));
                const auto dateSize = std::max(1, static_cast<int>(titleDimension * 0.017f));
                LONG cursor = top;
                RECT titleRect{ left, cursor, static_cast<LONG>(request.width) - left, cursor + titleSize * 2 + 20 };
                auto area = surface.DrawMask(request.title, request.fontFamily, titleSize, FW_SEMIBOLD, titleRect, alignment | DT_VCENTER);
                surface.Composite(frame, area, opacity, RGB(255, 252, 246), true);
                cursor = titleRect.bottom + static_cast<LONG>(request.height * 0.012f);
                if (!request.author.empty())
                {
                    RECT authorRect{ left, cursor, static_cast<LONG>(request.width) - left, cursor + authorSize * 2 };
                    area = surface.DrawMask(request.author, request.fontFamily, authorSize, FW_NORMAL, authorRect, alignment | DT_VCENTER);
                    surface.Composite(frame, area, opacity * 0.88f, RGB(237, 231, 222), true);
                    cursor = authorRect.bottom + static_cast<LONG>(request.height * 0.009f);
                }
                if (request.showIntroDate && !request.date.empty())
                {
                    RECT dateRect{ left, cursor, static_cast<LONG>(request.width) - left, cursor + dateSize * 2 };
                    area = surface.DrawMask(request.date, request.fontFamily, dateSize, FW_NORMAL, dateRect, alignment | DT_VCENTER);
                    surface.Composite(frame, area, opacity * 0.68f, RGB(219, 214, 207), true);
                }
            }
            return;
        }

        if (request.articleMode)
        {
            if (cueIndex >= 0)
            {
                const auto& cue = cues[static_cast<size_t>(cueIndex)];
                const auto fontSize = std::max(1, static_cast<int>(std::lround(request.articleFontSize * scale)));
                RECT rectangle{ marginX, static_cast<LONG>(request.height * 0.18),
                    static_cast<LONG>(request.width) - marginX, static_cast<LONG>(request.height * 0.82) };
                const auto area = surface.DrawMask(cue.text, request.fontFamily, fontSize, FW_NORMAL, rectangle, DT_CENTER | DT_VCENTER);
                const auto fade = Ease(static_cast<float>((seconds - cue.start) / 0.35));
                surface.Composite(frame, area, 0.94f * std::max(0.15f, fade), RGB(250, 248, 244), true);
            }
            return;
        }

        if (cueIndex >= 0 && !cues.empty())
        {
            const int window = request.lyricWindowCount >= 5 ? 5 : 3;
            const int firstOffset = window == 5 ? -2 : -1;
            const int lastOffset = window == 5 ? 2 : 1;
            const float elapsed = static_cast<float>(seconds - cues[static_cast<size_t>(cueIndex)].start);
            const float transition = Ease(elapsed / 0.48f);
            struct LyricRow
            {
                int cue = 0;
                int fontSize = 0;
                LONG height = 0;
                int offset = 0;
            };
            std::vector<LyricRow> rows;
            float blockHeight = 0;
            float rowGap = request.lyricFontSize * scale * 0.12f;
            for (int offset = firstOffset; offset <= lastOffset; ++offset)
            {
                const auto index = cueIndex + offset;
                if (index < 0 || index >= static_cast<int>(cues.size())) continue;
                const float relative = offset == 0 ? 1.0f : (std::abs(offset) == 1 ? 0.68f : 0.52f);
                float animationScale = 1;
                if (offset == 0 && request.lyricAnimation == 2) animationScale = 0.93f + transition * 0.07f;
                if (offset == 0 && request.lyricAnimation == 4) animationScale = 0.84f + transition * 0.16f;
                const auto fontSize = std::max(1, static_cast<int>(std::lround(request.lyricFontSize * scale * 0.78f * relative * animationScale)));
                const auto rowHeight = surface.MeasureTextHeight(cues[static_cast<size_t>(index)].text,
                    request.fontFamily, fontSize, offset == 0 ? FW_SEMIBOLD : FW_NORMAL, textWidth);
                rows.push_back({ index, fontSize, rowHeight, offset });
                blockHeight += rowHeight + rowGap;
            }

            const float verticalLimit = request.height * 0.70f;
            if (blockHeight > verticalLimit && blockHeight > 0)
            {
                const float shrink = verticalLimit / blockHeight;
                blockHeight = 0;
                rowGap *= shrink;
                for (auto& row : rows)
                {
                    row.fontSize = std::max(1, static_cast<int>(std::lround(row.fontSize * shrink)));
                    row.height = std::max<LONG>(row.fontSize, static_cast<LONG>(std::lround(row.height * shrink)));
                    blockHeight += row.height + rowGap;
                }
            }
            float cursorY = request.height * std::clamp(request.lyricPosition, 0.28f, 0.82f) - blockHeight * 0.5f;
            for (const auto& row : rows)
            {
                const auto offset = row.offset;
                float offsetY = 0;
                float opacity = offset == 0 ? 0.22f + transition * 0.78f : (std::abs(offset) == 1 ? 0.56f : 0.32f);
                if (offset == 0 && request.lyricAnimation == 0) offsetY = (1.0f - transition) * 16.0f * scale;
                if (offset == 0 && request.lyricAnimation == 1) opacity = transition;
                if (offset == 0 && request.lyricAnimation == 3) opacity = transition;
                RECT rectangle{ marginX, static_cast<LONG>(cursorY + offsetY),
                    static_cast<LONG>(request.width) - marginX, static_cast<LONG>(cursorY + offsetY + row.height) };
                const auto area = surface.DrawMask(cues[static_cast<size_t>(row.cue)].text, request.fontFamily, row.fontSize,
                    offset == 0 ? FW_SEMIBOLD : FW_NORMAL, rectangle, DT_CENTER | DT_VCENTER);
                const auto color = offset == 0 && request.lyricAnimation == 4
                    ? RGB(static_cast<BYTE>(197 + 58 * transition), static_cast<BYTE>(176 + 79 * transition), 255)
                    : RGB(255, 255, 255);
                surface.Composite(frame, area, opacity, color, true);
                cursorY += row.height + rowGap;
            }
        }

    }

    HRESULT ReadAudioSample(IMFSourceReader* reader, ComPtr<IMFSample>& sample, LONGLONG& time, LONGLONG& duration, DWORD& flags)
    {
        DWORD stream = 0;
        auto result = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &stream, &flags, &time, sample.ReleaseAndGetAddressOf());
        if (FAILED(result) || !sample) return result;
        if (FAILED(sample->GetSampleDuration(&duration)))
        {
            ComPtr<IMFMediaBuffer> buffer;
            result = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
            if (FAILED(result)) return result;
            DWORD length = 0;
            result = buffer->GetCurrentLength(&length);
            if (FAILED(result)) return result;
            duration = static_cast<LONGLONG>(length / (AudioChannels * 2.0) / AudioSampleRate * TicksPerSecond);
        }
        return S_OK;
    }

    HRESULT WriteAudioUntil(IMFSinkWriter* writer, DWORD audioIndex, IMFSourceReader* reader,
        ComPtr<IMFSample>& pending, LONGLONG& pendingTime, LONGLONG& pendingDuration, LONGLONG& loopOffset,
        double audioDuration, double outputDuration, LONGLONG throughTime, bool loopAudio)
    {
        for (;;)
        {
            if (!pending)
            {
                DWORD flags = 0;
                auto result = ReadAudioSample(reader, pending, pendingTime, pendingDuration, flags);
                if (FAILED(result)) return result;
                if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0 || !pending)
                {
                    if (!loopAudio || audioDuration <= 0 || (loopOffset / static_cast<double>(TicksPerSecond)) + audioDuration >= outputDuration)
                        return S_OK;
                    loopOffset += static_cast<LONGLONG>(audioDuration * TicksPerSecond);
                    result = SeekReader(reader, 0);
                    if (FAILED(result)) return result;
                    continue;
                }
            }

            const auto outputTime = pendingTime + loopOffset;
            if (outputTime >= throughTime) return S_OK;
            auto result = pending->SetSampleTime(outputTime);
            if (FAILED(result)) return result;
            result = pending->SetSampleDuration(pendingDuration);
            if (FAILED(result)) return result;
            result = writer->WriteSample(audioIndex, pending.Get());
            if (FAILED(result)) return result;
            pending.Reset();
        }
    }

    HRESULT RunExport(const ExportRequest& request)
    {
        if (request.width < 2 || request.height < 2 || request.audioDuration <= 0 || request.outputDuration <= 0 ||
            request.outputDuration > 21'600 || request.audioDuration > 21'600) return E_INVALIDARG;

        const auto comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        const bool uninitializeCom = SUCCEEDED(comResult);
        if (FAILED(comResult) && comResult != RPC_E_CHANGED_MODE) return comResult;
        HRESULT result = S_OK;
        bool mediaFoundationStarted = false;
        TemporaryOutputFile temporaryOutput;
        const auto frameCount64 = static_cast<std::uint64_t>(std::ceil(request.outputDuration * VideoFps));
        const auto analysisCapacity64 = static_cast<std::uint64_t>(std::ceil(request.audioDuration * VideoFps)) + 2;
        if (frameCount64 == 0 || frameCount64 > static_cast<std::uint64_t>(std::numeric_limits<int>::max()) ||
            analysisCapacity64 > static_cast<std::uint64_t>(std::numeric_limits<int>::max()) ||
            static_cast<std::uint64_t>(request.width) * request.height * 4 > static_cast<std::uint64_t>(std::numeric_limits<int>::max()))
        {
            result = E_INVALIDARG;
            goto cleanup;
        }

        {
            const auto analysisCapacity = static_cast<int>(analysisCapacity64);
            std::vector<float> analysis(static_cast<size_t>(analysisCapacity) * AudioBandCount);
            int analysisFrames = 0;
            double measuredAudioDuration = 0;
            ExportStage.store(1, std::memory_order_relaxed);
            result = SikaMTV_AnalyzeAudioFile(request.audioPath.c_str(), analysis.data(), analysisCapacity,
                &analysisFrames, &measuredAudioDuration);
            if (FAILED(static_cast<HRESULT>(result)) || analysisFrames <= 0)
            {
                result = FAILED(static_cast<HRESULT>(result)) ? result : MF_E_INVALID_FILE_FORMAT;
                goto cleanup;
            }

            result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
            if (FAILED(result)) goto cleanup;
            mediaFoundationStarted = true;

            ComPtr<IMFSourceReader> audioReader;
            result = CreateAudioReader(request.audioPath, audioReader);
            if (FAILED(result)) goto cleanup;
            double readerAudioDuration = 0;
            ReadDuration(audioReader.Get(), readerAudioDuration);
            if (readerAudioDuration > 0) measuredAudioDuration = readerAudioDuration;
            ExportStage.store(2, std::memory_order_relaxed);

            BackgroundVideo background;
            if (!request.backgroundVideoPath.empty())
            {
                result = background.Open(request.backgroundVideoPath, request.loopBackgroundVideo);
                if (FAILED(result)) goto cleanup;
            }

            ComPtr<IMFSinkWriter> writer;
            DWORD videoIndex = 0;
            DWORD audioIndex = 0;
            GUID temporaryGuid{};
            if (FAILED(CoCreateGuid(&temporaryGuid)))
            {
                result = E_FAIL;
                goto cleanup;
            }
            wchar_t temporarySuffix[40]{};
            StringFromGUID2(temporaryGuid, temporarySuffix, ARRAYSIZE(temporarySuffix));
            temporaryOutput.path = request.outputPath + L".sikamtv-" + temporarySuffix + L".mp4";
            ExportRequest writerRequest = request;
            writerRequest.outputPath = temporaryOutput.path;
            result = ConfigureWriter(writerRequest, writer, videoIndex, audioIndex);
            if (FAILED(result)) goto cleanup;
            result = writer->BeginWriting();
            if (FAILED(result)) goto cleanup;

            TextSurface textSurface;
            if (!textSurface.Initialize(request.width, request.height))
            {
                result = HRESULT_FROM_WIN32(GetLastError());
                if (result == S_OK) result = E_OUTOFMEMORY;
                writer->Finalize();
                goto cleanup;
            }
            const auto cues = ParseTimeline(request.textTimeline);
            const auto frameBytes = static_cast<DWORD>(request.width * request.height * 4);
            const auto frameDuration = TicksPerSecond / VideoFps;
            const auto frameCount = static_cast<std::uint64_t>(frameCount64);
            ComPtr<IMFSample> pendingAudio;
            LONGLONG pendingAudioTime = 0;
            LONGLONG pendingAudioDuration = 0;
            LONGLONG audioLoopOffset = 0;
            std::vector<unsigned char> pixels(frameBytes);

            for (std::uint64_t frame = 0; frame < frameCount; ++frame)
            {
                if (ExportCancelled.load(std::memory_order_relaxed))
                {
                    result = HRESULT_FROM_WIN32(ERROR_CANCELLED);
                    break;
                }
                const auto time = frame / static_cast<double>(VideoFps);
                const auto frameTime = static_cast<LONGLONG>(frame) * frameDuration;
                if (background.duration > 0 || !request.backgroundVideoPath.empty())
                {
                    result = background.Update(time);
                    if (FAILED(result)) break;
                }

                const auto audioFrame = static_cast<size_t>(frame) % static_cast<size_t>(analysisFrames);
                const auto* bands = analysis.data() + audioFrame * AudioBandCount;
                result = SikaMTV_RenderExportFrame(request.width, request.height, static_cast<float>(time), request.visualizerKind,
                    request.intensity, request.blur, request.vignette, request.saturation, request.slowZoom,
                    request.visualizerScale, request.rainbow, bands, AudioBandCount, pixels.data(), static_cast<int>(pixels.size()));
                if (FAILED(static_cast<HRESULT>(result))) break;
                CompositeText(request, cues, time, textSurface, pixels.data());

                ComPtr<IMFMediaBuffer> videoBuffer;
                result = MFCreateMemoryBuffer(frameBytes, videoBuffer.GetAddressOf());
                if (FAILED(result)) break;
                BYTE* destination = nullptr;
                DWORD maximum = 0;
                DWORD current = 0;
                result = videoBuffer->Lock(&destination, &maximum, &current);
                if (FAILED(result)) break;
                std::memcpy(destination, pixels.data(), frameBytes);
                videoBuffer->Unlock();
                result = videoBuffer->SetCurrentLength(frameBytes);
                if (FAILED(result)) break;
                ComPtr<IMFSample> videoSample;
                result = MFCreateSample(videoSample.GetAddressOf());
                if (FAILED(result)) break;
                result = videoSample->AddBuffer(videoBuffer.Get());
                if (FAILED(result)) break;
                result = videoSample->SetSampleTime(frameTime);
                if (FAILED(result)) break;
                result = videoSample->SetSampleDuration(frameDuration);
                if (FAILED(result)) break;

                result = WriteAudioUntil(writer.Get(), audioIndex, audioReader.Get(), pendingAudio,
                    pendingAudioTime, pendingAudioDuration, audioLoopOffset, measuredAudioDuration,
                    request.outputDuration, frameTime + frameDuration, request.articleMode);
                if (FAILED(result)) break;
                result = writer->WriteSample(videoIndex, videoSample.Get());
                if (FAILED(result)) break;
                if ((frame & 7) == 0 || frame + 1 == frameCount)
                    ExportProgress.store(static_cast<float>(frame + 1) / static_cast<float>(frameCount), std::memory_order_relaxed);
            }

            const auto finalizeResult = writer->Finalize();
            if (SUCCEEDED(result) && FAILED(finalizeResult)) result = finalizeResult;
            writer.Reset();
        }

cleanup:
        if (mediaFoundationStarted) MFShutdown();
        if (uninitializeCom) CoUninitialize();
        if (SUCCEEDED(result) && !ExportCancelled.load(std::memory_order_relaxed) && !temporaryOutput.path.empty())
            result = temporaryOutput.Commit(request.outputPath);
        return result;
    }

    void ExportWorker(ExportRequest request)
    {
        HRESULT result = E_FAIL;
        try
        {
            result = RunExport(request);
        }
        catch (const std::bad_alloc&)
        {
            result = E_OUTOFMEMORY;
        }
        catch (...)
        {
            result = E_FAIL;
        }
        if (ExportCancelled.load(std::memory_order_relaxed) && SUCCEEDED(result)) result = HRESULT_FROM_WIN32(ERROR_CANCELLED);
        if (SUCCEEDED(result)) ExportProgress.store(1, std::memory_order_relaxed);
        SuspendPreviewVideo(false);
        ExportStage.store(0, std::memory_order_relaxed);
        ExportResult.store(result, std::memory_order_relaxed);
        ExportRunning.store(false, std::memory_order_release);
    }
}

int __cdecl SikaMTV_StartVideoExport(const wchar_t* backgroundVideoPath, const wchar_t* audioPath, const wchar_t* outputPath,
    const wchar_t* textTimeline, const wchar_t* title, const wchar_t* author, const wchar_t* date, const wchar_t* fontFamily,
    double audioDurationSeconds, double outputDurationSeconds, unsigned int width, unsigned int height, unsigned int visualizerKind,
    float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow,
    float lyricFontSize, float lyricPosition, int lyricWindowCount, int lyricAnimation, int articleMode,
    float articleFontSize, float articleLineSpacing, float introDuration, int showIntroDate, int introAnimation, int loopBackgroundVideo)
{
    if (audioPath == nullptr || audioPath[0] == L'\0' || outputPath == nullptr || outputPath[0] == L'\0') return E_INVALIDARG;
    if (ExportRunning.exchange(true, std::memory_order_acq_rel)) return HRESULT_FROM_WIN32(ERROR_BUSY);
    if (ExportThread.joinable()) ExportThread.join();

    try
    {
        ExportRequest request;
        request.backgroundVideoPath = SafeString(backgroundVideoPath);
        request.audioPath = SafeString(audioPath);
        request.outputPath = SafeString(outputPath);
        request.textTimeline = SafeString(textTimeline);
        request.title = SafeString(title);
        request.author = SafeString(author);
        request.date = SafeString(date);
        request.fontFamily = SafeString(fontFamily);
        request.audioDuration = audioDurationSeconds;
        request.outputDuration = outputDurationSeconds;
        request.width = width;
        request.height = height;
        request.visualizerKind = visualizerKind;
        request.intensity = intensity;
        request.blur = blur;
        request.vignette = vignette;
        request.saturation = saturation;
        request.slowZoom = slowZoom;
        request.visualizerScale = visualizerScale;
        request.rainbow = rainbow;
        request.lyricFontSize = lyricFontSize;
        request.lyricPosition = lyricPosition;
        request.lyricWindowCount = lyricWindowCount;
        request.lyricAnimation = lyricAnimation;
        request.articleMode = articleMode != 0;
        request.articleFontSize = articleFontSize;
        request.articleLineSpacing = articleLineSpacing;
        request.introDuration = introDuration;
        request.showIntroDate = showIntroDate != 0;
        request.introAnimation = introAnimation;
        request.loopBackgroundVideo = loopBackgroundVideo != 0;

        ExportCancelled.store(false, std::memory_order_relaxed);
        SikaMTV_SetAudioAnalysisCancelled(0);
        ExportStage.store(1, std::memory_order_relaxed);
        ExportProgress.store(0, std::memory_order_relaxed);
        ExportResult.store(E_PENDING, std::memory_order_relaxed);
        SuspendPreviewVideo(true);
        ExportThread = std::jthread(ExportWorker, std::move(request));
    }
    catch (...)
    {
        SuspendPreviewVideo(false);
        ExportStage.store(0, std::memory_order_relaxed);
        ExportRunning.store(false, std::memory_order_release);
        ExportResult.store(E_OUTOFMEMORY, std::memory_order_relaxed);
        return E_OUTOFMEMORY;
    }
    return S_OK;
}

int __cdecl SikaMTV_UpdatePreviewBackgroundVideo(const wchar_t* path, double timeSeconds, int loop)
{
    try
    {
        const auto requestedPath = SafeString(path);
        bool startWorker = false;
        {
            std::scoped_lock lock(PreviewRequestMutex);
            const bool sourceChanged = requestedPath != PreviewRequestedPath || PreviewRequestedLoop != (loop != 0);
            if (sourceChanged ||
                std::abs(PreviewRequestedSeconds - timeSeconds) >= 0.012)
            {
                PreviewRequestedPath = requestedPath;
                PreviewRequestedSeconds = std::max(0.0, timeSeconds);
                PreviewRequestedLoop = loop != 0;
                ++PreviewRequestVersion;
            }
            if (sourceChanged) PreviewVideoResult.store(S_OK, std::memory_order_relaxed);
            startWorker = !requestedPath.empty() && (!PreviewVideoThread.joinable() ||
                (!PreviewVideoWorkerRunning.load(std::memory_order_acquire) && sourceChanged));
        }

        if (startWorker)
        {
            if (PreviewVideoThread.joinable()) PreviewVideoThread.join();
            PreviewVideoWorkerRunning.store(true, std::memory_order_release);
            PreviewVideoThread = std::jthread(PreviewVideoWorker);
        }
        PreviewRequestChanged.notify_all();
        return PreviewVideoResult.load(std::memory_order_relaxed);
    }
    catch (...)
    {
        PreviewVideoWorkerRunning.store(false, std::memory_order_release);
        PreviewVideoResult.store(E_OUTOFMEMORY, std::memory_order_relaxed);
        return E_OUTOFMEMORY;
    }
}

void __cdecl SikaMTV_StopPreviewBackgroundVideo()
{
    if (PreviewVideoThread.joinable())
    {
        PreviewVideoThread.request_stop();
        PreviewRequestChanged.notify_all();
        PreviewVideoThread.join();
    }
    PreviewVideoWorkerRunning.store(false, std::memory_order_release);
    std::scoped_lock lock(PreviewRequestMutex);
    PreviewRequestedPath.clear();
    PreviewRequestedSeconds = 0;
    ++PreviewRequestVersion;
    PreviewVideoResult.store(S_OK, std::memory_order_relaxed);
}

void __cdecl SikaMTV_GetVideoExportProgress(float* progress, int* isRunning, int* result)
{
    if (progress)
    {
        const auto stage = ExportStage.load(std::memory_order_relaxed);
        const auto value = stage == 1
            ? SikaMTV_GetAudioAnalysisProgress() * 0.08f
            : stage == 2 ? 0.08f + ExportProgress.load(std::memory_order_relaxed) * 0.92f
                         : ExportProgress.load(std::memory_order_relaxed);
        *progress = value;
    }
    if (isRunning) *isRunning = ExportRunning.load(std::memory_order_acquire) ? 1 : 0;
    if (result) *result = ExportResult.load(std::memory_order_relaxed);
}

void __cdecl SikaMTV_CancelVideoExport()
{
    if (ExportRunning.load(std::memory_order_acquire))
    {
        ExportCancelled.store(true, std::memory_order_relaxed);
        SikaMTV_SetAudioAnalysisCancelled(1);
    }
}
