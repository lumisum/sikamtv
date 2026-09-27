#include "GpuDevice.h"
#include "AudioAnalyzer.h"

#include <Windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <sstream>
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
        std::wstring backgroundManifest;
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
        float visualizerSmoothing = 0.72f;
        float lyricFontSize = 46;
        float lyricPosition = 0.6f;
        float lyricWidth = 0.82f;
        float lyricLineSpacing = 1.85f;
        float lyricInactiveOpacity = 0.24f;
        float lyricGlow = 0.82f;
        float lyricAnimationDuration = 0.62f;
        int lyricAlignment = 1;
        int lyricWindowCount = 5;
        int lyricAnimation = 0;
        bool articleMode = false;
        float articleFontSize = 38;
        float articleLineSpacing = 1.68f;
        float introDuration = 12;
        float introTitleSize = 72;
        float introAnimationDuration = 1.15f;
        bool introEnabled = true;
        bool showIntroDate = true;
        int introAnimation = 0;
        bool loopBackgroundVideo = true;
        int backgroundTransition = 0;
        float backgroundTransitionDuration = 1.35f;
        bool backgroundAudioEnabled = false;
        float backgroundAudioVolume = 0.25f;
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

    struct BackgroundMediaDescriptor
    {
        bool video = false;
        std::wstring path;
        float primary[3] = { 0.48f, 0.72f, 1.0f };
        float secondary[3] = { 0.82f, 0.52f, 0.94f };
        std::wstring subjectMaskPath;
    };

    std::vector<BackgroundMediaDescriptor> ParseBackgroundManifest(const std::wstring& manifest)
    {
        std::vector<BackgroundMediaDescriptor> result;
        std::wistringstream lines(manifest);
        std::wstring line;
        while (std::getline(lines, line))
        {
            const auto first = line.find(L'|');
            const auto second = first == std::wstring::npos ? first : line.find(L'|', first + 1);
            const auto third = second == std::wstring::npos ? second : line.find(L'|', second + 1);
            const auto fourth = third == std::wstring::npos ? third : line.find(L'|', third + 1);
            if (first != 1 || second == std::wstring::npos) continue;
            BackgroundMediaDescriptor item;
            item.video = line[0] == L'V';
            item.path = line.substr(first + 1, second - first - 1);
            if (third != std::wstring::npos)
            {
                auto parseColor = [](const std::wstring& value, float color[3])
                {
                    std::wistringstream parts(value);
                    std::wstring component;
                    for (size_t i = 0; i < 3 && std::getline(parts, component, L','); ++i)
                    {
                        try { color[i] = std::clamp(std::stof(component), 0.0f, 1.0f); }
                        catch (...) { }
                    }
                };
                parseColor(line.substr(second + 1, third - second - 1), item.primary);
                parseColor(line.substr(third + 1, fourth == std::wstring::npos ? std::wstring::npos : fourth - third - 1), item.secondary);
                if (fourth != std::wstring::npos) item.subjectMaskPath = line.substr(fourth + 1);
            }
            if (!item.path.empty()) result.push_back(std::move(item));
        }
        return result;
    }

    std::vector<unsigned char> ReadSubjectMask(const std::wstring& path)
    {
        constexpr size_t MaskBytes = 256u * 256u;
        if (path.empty()) return {};
        std::ifstream file(std::filesystem::path(path), std::ios::binary | std::ios::ate);
        if (!file || file.tellg() != static_cast<std::streamoff>(MaskBytes)) return {};
        std::vector<unsigned char> pixels(MaskBytes);
        file.seekg(0);
        if (!file.read(reinterpret_cast<char*>(pixels.data()), static_cast<std::streamsize>(pixels.size()))) return {};
        return pixels;
    }

    HRESULT DecodeBackgroundImage(const std::wstring& path, std::vector<unsigned char>& pixels, UINT& width, UINT& height)
    {
        pixels.clear();
        width = height = 0;
        ComPtr<IWICImagingFactory> factory;
        auto result = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(factory.GetAddressOf()));
        if (FAILED(result)) return result;
        ComPtr<IWICBitmapDecoder> decoder;
        result = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
            WICDecodeMetadataCacheOnLoad, decoder.GetAddressOf());
        if (FAILED(result)) return result;
        ComPtr<IWICBitmapFrameDecode> frame;
        result = decoder->GetFrame(0, frame.GetAddressOf());
        if (FAILED(result)) return result;
        WICBitmapTransformOptions orientationTransform = WICBitmapTransformRotate0;
        ComPtr<IWICMetadataQueryReader> metadata;
        if (SUCCEEDED(frame->GetMetadataQueryReader(metadata.GetAddressOf())))
        {
            PROPVARIANT orientation;
            PropVariantInit(&orientation);
            if (SUCCEEDED(metadata->GetMetadataByName(L"/app1/ifd/{ushort=274}", &orientation)) && orientation.vt == VT_UI2)
            {
                switch (orientation.uiVal)
                {
                case 2: orientationTransform = WICBitmapTransformFlipHorizontal; break;
                case 3: orientationTransform = WICBitmapTransformRotate180; break;
                case 4: orientationTransform = WICBitmapTransformFlipVertical; break;
                case 5: orientationTransform = static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal); break;
                case 6: orientationTransform = WICBitmapTransformRotate90; break;
                case 7: orientationTransform = static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal); break;
                case 8: orientationTransform = WICBitmapTransformRotate270; break;
                default: break;
                }
            }
            PropVariantClear(&orientation);
        }

        ComPtr<IWICBitmapSource> orientedSource;
        if (orientationTransform != WICBitmapTransformRotate0)
        {
            ComPtr<IWICBitmapFlipRotator> rotator;
            result = factory->CreateBitmapFlipRotator(rotator.GetAddressOf());
            if (FAILED(result)) return result;
            result = rotator->Initialize(frame.Get(), orientationTransform);
            if (FAILED(result)) return result;
            result = rotator.As(&orientedSource);
            if (FAILED(result)) return result;
        }
        else
        {
            result = frame.As(&orientedSource);
            if (FAILED(result)) return result;
        }

        UINT sourceWidth = 0, sourceHeight = 0;
        result = orientedSource->GetSize(&sourceWidth, &sourceHeight);
        if (FAILED(result) || sourceWidth == 0 || sourceHeight == 0) return FAILED(result) ? result : E_INVALIDARG;

        const double scale = std::min({ 1.0, 1920.0 / sourceWidth, 1080.0 / sourceHeight });
        width = std::max(1u, static_cast<UINT>(std::lround(sourceWidth * scale)));
        height = std::max(1u, static_cast<UINT>(std::lround(sourceHeight * scale)));
        ComPtr<IWICBitmapSource> source;
        if (width != sourceWidth || height != sourceHeight)
        {
            ComPtr<IWICBitmapScaler> scaler;
            result = factory->CreateBitmapScaler(scaler.GetAddressOf());
            if (FAILED(result)) return result;
            result = scaler->Initialize(orientedSource.Get(), width, height, WICBitmapInterpolationModeFant);
            if (FAILED(result)) return result;
            result = scaler.As(&source);
        }
        else source = orientedSource;
        if (FAILED(result)) return result;

        ComPtr<IWICFormatConverter> converter;
        result = factory->CreateFormatConverter(converter.GetAddressOf());
        if (FAILED(result)) return result;
        result = converter->Initialize(source.Get(), GUID_WICPixelFormat32bppBGRA,
            WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
        if (FAILED(result)) return result;
        const auto stride64 = static_cast<UINT64>(width) * 4;
        const auto byteCount64 = stride64 * height;
        if (byteCount64 > static_cast<UINT64>(std::numeric_limits<size_t>::max()) || byteCount64 > MAXDWORD) return E_OUTOFMEMORY;
        pixels.resize(static_cast<size_t>(byteCount64));
        result = converter->CopyPixels(nullptr, static_cast<UINT>(stride64), static_cast<UINT>(byteCount64), pixels.data());
        if (FAILED(result)) pixels.clear();
        return result;
    }

    struct BackgroundTimelineState
    {
        size_t currentIndex = 0;
        std::optional<size_t> nextIndex;
        double currentLocalTime = 0;
        double nextLocalTime = 0;
        double segmentDuration = 0;
        float transitionProgress = 0;
        int transitionKind = 0;
    };

    BackgroundTimelineState BackgroundStateAt(double time, double duration,
        const std::vector<BackgroundMediaDescriptor>& media, int transition, double transitionDuration,
        double singleVideoDuration)
    {
        BackgroundTimelineState state{};
        if (media.empty()) return state;
        if (media.size() == 1 && media[0].video && singleVideoDuration > 0)
        {
            const auto blend = std::min(std::max(0.2, transitionDuration), singleVideoDuration * 0.25);
            const auto cycle = std::max(0.001, singleVideoDuration - blend);
            const auto safeTime = std::max(0.0, time);
            const auto playhead = safeTime < singleVideoDuration
                ? safeTime : std::fmod(safeTime - singleVideoDuration, cycle) + blend;
            state.segmentDuration = singleVideoDuration;
            state.currentLocalTime = playhead;
            if (playhead >= singleVideoDuration - blend)
            {
                state.nextIndex = 0;
                state.nextLocalTime = std::max(0.0, playhead - (singleVideoDuration - blend));
                state.transitionProgress = static_cast<float>(std::clamp(state.nextLocalTime / blend, 0.0, 1.0));
                state.transitionKind = 1;
            }
            return state;
        }
        if (media.size() == 1 || duration <= 0)
        {
            state.segmentDuration = std::max(duration, 1.0);
            state.currentLocalTime = std::max(0.0, time);
            return state;
        }

        state.segmentDuration = duration / static_cast<double>(media.size());
        const auto safeTime = std::clamp(time, 0.0, std::max(0.0, duration - 0.000001));
        const auto active = std::min(media.size() - 1, static_cast<size_t>(safeTime / state.segmentDuration));
        const auto local = safeTime - static_cast<double>(active) * state.segmentDuration;
        const auto blend = std::min(std::max(0.05, transitionDuration), state.segmentDuration * 0.45);
        state.currentIndex = active;
        state.currentLocalTime = local;
        if (transition != 3 && active > 0 && local < blend)
        {
            state.currentIndex = active - 1;
            state.nextIndex = active;
            state.currentLocalTime = state.segmentDuration;
            state.nextLocalTime = local;
            state.transitionProgress = static_cast<float>(std::clamp(local / blend, 0.0, 1.0));
            state.transitionKind = std::clamp(transition + 1, 1, 3);
        }
        return state;
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

        HRESULT Update(double seconds, bool secondary = false)
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
            return secondary
                ? SikaMTV_SetBackgroundImageSecondary(pixels.data(), frameWidth, frameHeight, frameWidth * 4)
                : SikaMTV_SetBackgroundImage(pixels.data(), frameWidth, frameHeight, frameWidth * 4);
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

    struct BackgroundSource
    {
        size_t index = std::numeric_limits<size_t>::max();
        BackgroundMediaDescriptor descriptor;
        std::unique_ptr<BackgroundVideo> video;
        std::vector<unsigned char> pixels;
        std::vector<unsigned char> subjectMask;
        UINT width = 0;
        UINT height = 0;
        int imageSlot = -1;
        int maskSlot = -1;

        HRESULT Open(size_t sourceIndex, const BackgroundMediaDescriptor& source, bool loop)
        {
            index = sourceIndex;
            descriptor = source;
            pixels.clear();
            subjectMask.clear();
            video.reset();
            width = height = 0;
            imageSlot = -1;
            maskSlot = -1;
            if (source.video)
            {
                video = std::make_unique<BackgroundVideo>();
                auto result = video->Open(source.path, loop);
                if (FAILED(result)) video.reset();
                return result;
            }
            auto result = DecodeBackgroundImage(source.path, pixels, width, height);
            if (SUCCEEDED(result)) subjectMask = ReadSubjectMask(source.subjectMaskPath);
            return result;
        }

        double duration() const { return video ? video->duration : 0; }

        HRESULT Update(double seconds, bool secondary)
        {
            const int slot = secondary ? 1 : 0;
            if (maskSlot != slot)
            {
                const auto maskResult = subjectMask.empty()
                    ? SikaMTV_SetSubjectMask(nullptr, 0, 0, 0, slot)
                    : SikaMTV_SetSubjectMask(subjectMask.data(), 256, 256, 256, slot);
                if (FAILED(static_cast<HRESULT>(maskResult))) return maskResult;
                maskSlot = slot;
            }
            if (video) return video->Update(seconds, secondary);
            if (pixels.empty()) return MF_E_INVALID_FILE_FORMAT;
            if (imageSlot == slot) return S_OK;
            const auto result = secondary
                ? SikaMTV_SetBackgroundImageSecondary(pixels.data(), width, height, width * 4)
                : SikaMTV_SetBackgroundImage(pixels.data(), width, height, width * 4);
            if (SUCCEEDED(static_cast<HRESULT>(result))) imageSlot = slot;
            return result;
        }
    };

    struct PreviewVideoRequest
    {
        std::wstring primaryPath;
        double primarySeconds = 0;
        std::wstring secondaryPath;
        double secondarySeconds = 0;
        bool loop = true;
        std::uint64_t version = 0;
    };

    struct PreviewTrackState
    {
        std::unique_ptr<BackgroundVideo> source;
        std::wstring openedPath;
        std::wstring failedPath;
        bool openedLoop = true;
        bool failedLoop = true;
    };

    std::mutex PreviewRequestMutex;
    std::mutex PreviewDecodeMutex;
    std::condition_variable PreviewRequestChanged;
    std::wstring PreviewRequestedPrimaryPath;
    double PreviewRequestedPrimarySeconds = 0;
    std::wstring PreviewRequestedSecondaryPath;
    double PreviewRequestedSecondarySeconds = 0;
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

        PreviewTrackState primary;
        PreviewTrackState secondary;
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
                request = { PreviewRequestedPrimaryPath, PreviewRequestedPrimarySeconds,
                    PreviewRequestedSecondaryPath, PreviewRequestedSecondarySeconds,
                    PreviewRequestedLoop, PreviewRequestVersion };
            }
            if (PreviewVideoSuspended.load(std::memory_order_acquire))
            {
                processedVersion = request.version;
                continue;
            }
            auto updateTrack = [&](const std::wstring& path, double seconds, PreviewTrackState& track, bool isSecondary)
            {
                if (path.empty())
                {
                    track.source.reset();
                    track.openedPath.clear();
                    track.failedPath.clear();
                    return S_OK;
                }
                if (path == track.failedPath && request.loop == track.failedLoop) return MF_E_INVALID_FILE_FORMAT;
                if (!track.source || track.openedPath != path || track.openedLoop != request.loop)
                {
                    auto replacement = std::make_unique<BackgroundVideo>();
                    auto openResult = replacement->Open(path, request.loop);
                    if (FAILED(openResult))
                    {
                        track.source.reset();
                        track.openedPath.clear();
                        track.failedPath = path;
                        track.failedLoop = request.loop;
                        return openResult;
                    }
                    track.source = std::move(replacement);
                    track.openedPath = path;
                    track.failedPath.clear();
                    track.openedLoop = request.loop;
                }
                std::scoped_lock decodeLock(PreviewDecodeMutex);
                if (PreviewVideoSuspended.load(std::memory_order_acquire)) return S_OK;
                return track.source->Update(seconds, isSecondary);
            };

            const auto primaryResult = updateTrack(request.primaryPath, request.primarySeconds, primary, false);
            const auto secondaryResult = updateTrack(request.secondaryPath, request.secondarySeconds, secondary, true);
            PreviewVideoResult.store(FAILED(primaryResult) ? primaryResult : secondaryResult, std::memory_order_relaxed);
            processedVersion = request.version;
        }

        primary.source.reset();
        secondary.source.reset();
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

        void Composite(unsigned char* bgra, RECT area, float opacity, COLORREF color, float glow)
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

            glow = std::clamp(glow, 0.0f, 1.0f);
            for (LONG y = area.top; y < area.bottom; ++y)
            {
                for (LONG x = area.left; x < area.right; ++x)
                {
                    const auto mask = static_cast<unsigned char>((pixels[static_cast<size_t>(y) * width + x] >> 16) & 0xff);
                    if (mask == 0) continue;
                    const auto alpha = static_cast<unsigned char>(std::clamp(static_cast<int>(std::lround(mask * opacity)), 0, 255));
                    if (glow > 0.001f)
                    {
                        const auto glowAlpha = static_cast<unsigned char>(alpha * glow * 0.20f);
                        blend(x - 1, y, glowAlpha, GetBValue(color), GetGValue(color), GetRValue(color));
                        blend(x + 1, y, glowAlpha, GetBValue(color), GetGValue(color), GetRValue(color));
                        blend(x, y - 1, glowAlpha, GetBValue(color), GetGValue(color), GetRValue(color));
                        blend(x, y + 1, glowAlpha, GetBValue(color), GetGValue(color), GetRValue(color));
                    }
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
        const auto lyricWidth = static_cast<LONG>(request.width * std::clamp(request.lyricWidth, 0.45f, 0.96f));
        const auto lyricMarginX = static_cast<LONG>((request.width - lyricWidth) / 2);
        const LONG textWidth = lyricWidth;
        const int cueIndex = CurrentCueIndex(cues, seconds);
        const auto compositeAccentLine = [frame, &request](LONG left, LONG top, LONG width, LONG height, float opacity)
        {
            const auto alpha = static_cast<unsigned>(std::clamp(std::lround(opacity * 255.0f), 0l, 255l));
            if (!frame || alpha == 0 || width <= 0 || height <= 0) return;
            const LONG right = std::clamp<LONG>(left + width, 0, static_cast<LONG>(request.width));
            const LONG bottom = std::clamp<LONG>(top + height, 0, static_cast<LONG>(request.height));
            left = std::clamp<LONG>(left, 0, static_cast<LONG>(request.width));
            top = std::clamp<LONG>(top, 0, static_cast<LONG>(request.height));
            for (LONG y = top; y < bottom; ++y)
            for (LONG x = left; x < right; ++x)
            {
                auto* pixel = frame + (static_cast<size_t>(y) * request.width + static_cast<size_t>(x)) * 4;
                const auto inverse = 255 - alpha;
                pixel[0] = static_cast<unsigned char>((pixel[0] * inverse + 255 * alpha + 127) / 255);
                pixel[1] = static_cast<unsigned char>((pixel[1] * inverse + 156 * alpha + 127) / 255);
                pixel[2] = static_cast<unsigned char>((pixel[2] * inverse + 182 * alpha + 127) / 255);
            }
        };

        if (request.introEnabled && !request.title.empty() && seconds < request.introDuration && request.introDuration > 0)
        {
            const float fadeDuration = std::clamp(request.introAnimationDuration, 0.2f, 3.0f);
            const float fadeIn = Ease(static_cast<float>(seconds / fadeDuration));
            const float fadeOut = Ease(static_cast<float>((request.introDuration - seconds) / fadeDuration));
            const float opacity = std::min(fadeIn, fadeOut);
            if (opacity > 0)
            {
                const float introScale = request.introAnimation == 2 ? 0.97f + fadeIn * 0.03f : 1.0f;
                const float outputScale = landscape ? request.width / 640.0f : square ? request.width / 580.0f : request.height / 640.0f;
                const LONG columnWidth = static_cast<LONG>(std::lround((landscape ? 420.0f : 320.0f) * outputScale));
                const LONG left = landscape
                    ? static_cast<LONG>(std::lround(24.0f * outputScale))
                    : std::max<LONG>(0, (static_cast<LONG>(request.width) - columnWidth) / 2);
                const LONG right = std::min<LONG>(static_cast<LONG>(request.width), left + columnWidth);
                const LONG top = static_cast<LONG>(std::lround((landscape ? 24.0f : 70.0f) * outputScale +
                    (request.introAnimation == 0 ? (1.0f - fadeIn) * 12.0f * outputScale : 0)));
                const UINT alignment = DT_CENTER;
                const auto titleSize = std::max(1, static_cast<int>(std::lround(request.introTitleSize * introScale)));
                const auto authorSize = std::max(1, static_cast<int>(std::lround(titleSize * 0.46f)));
                const auto dateSize = std::max(1, static_cast<int>(std::lround(titleSize * 0.30f)));
                LONG cursor = top;
                const auto titleHeight = surface.MeasureTextHeight(request.title, request.fontFamily, titleSize, FW_SEMIBOLD, right - left);
                RECT titleRect{ left, cursor, right, cursor + titleHeight };
                auto area = surface.DrawMask(request.title, request.fontFamily, titleSize, FW_SEMIBOLD, titleRect, alignment);
                surface.Composite(frame, area, opacity, RGB(255, 252, 246), true);
                cursor = titleRect.bottom + static_cast<LONG>(std::lround(10.0f * outputScale));
                const LONG accentWidth = static_cast<LONG>(std::lround(58.0f * outputScale));
                const LONG accentHeight = std::max<LONG>(1, static_cast<LONG>(std::lround(outputScale)));
                compositeAccentLine(left + (right - left - accentWidth) / 2, cursor, accentWidth, accentHeight, opacity * 0.80f);
                cursor += accentHeight + static_cast<LONG>(std::lround(10.0f * outputScale));
                if (!request.author.empty())
                {
                    const auto authorHeight = surface.MeasureTextHeight(request.author, request.fontFamily, authorSize, FW_NORMAL, right - left);
                    RECT authorRect{ left, cursor, right, cursor + authorHeight };
                    area = surface.DrawMask(request.author, request.fontFamily, authorSize, FW_NORMAL, authorRect, alignment);
                    surface.Composite(frame, area, opacity * 0.88f, RGB(237, 231, 222), true);
                    cursor = authorRect.bottom + static_cast<LONG>(std::lround(10.0f * outputScale));
                }
                if (request.showIntroDate && !request.date.empty())
                {
                    const auto dateHeight = surface.MeasureTextHeight(request.date, request.fontFamily, dateSize, FW_NORMAL, right - left);
                    RECT dateRect{ left, cursor, right, cursor + dateHeight };
                    area = surface.DrawMask(request.date, request.fontFamily, dateSize, FW_NORMAL, dateRect, alignment);
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
                RECT rectangle{ lyricMarginX, static_cast<LONG>(request.height * 0.18),
                    lyricMarginX + lyricWidth, static_cast<LONG>(request.height * 0.82) };
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
            const float transition = request.lyricAnimation == 5 ? 1.0f
                : Ease(elapsed / std::max(0.18f, request.lyricAnimationDuration));
            struct LyricRow
            {
                int cue = 0;
                int fontSize = 0;
                LONG height = 0;
                int offset = 0;
            };
            std::vector<LyricRow> rows;
            float blockHeight = 0;
            float rowGap = request.lyricFontSize * scale * std::clamp(request.lyricLineSpacing - 1.0f, 0.10f, 1.50f) * 0.16f;
            for (int offset = firstOffset; offset <= lastOffset; ++offset)
            {
                const auto index = cueIndex + offset;
                if (index < 0 || index >= static_cast<int>(cues.size())) continue;
                const float relative = offset == 0 ? 1.0f : (std::abs(offset) == 1 ? 0.68f : 0.52f);
                float animationScale = 1;
                if (offset == 0 && request.lyricAnimation == 2) animationScale = 0.93f + transition * 0.07f;
                if (offset == 0 && request.lyricAnimation == 4) animationScale = 0.84f + transition * 0.16f;
                const auto fontSize = std::max(1, static_cast<int>(std::lround(request.lyricFontSize * scale * relative * animationScale)));
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
                const float inactive = std::clamp(request.lyricInactiveOpacity, 0.08f, 0.72f);
                float opacity = offset == 0 ? (request.lyricAnimation == 5 ? 1.0f : 0.22f + transition * 0.78f) : (std::abs(offset) == 1 ? std::max(inactive, 0.66f) : std::max(inactive * 0.88f, 0.42f));
                if (offset == 0 && request.lyricAnimation == 0) offsetY = (1.0f - transition) * 16.0f * scale;
                if (offset == 0 && request.lyricAnimation == 1) opacity = transition;
                if (offset == 0 && request.lyricAnimation == 3) opacity = transition;
                const UINT alignment = request.lyricAlignment == 0 ? DT_LEFT : request.lyricAlignment == 2 ? DT_RIGHT : DT_CENTER;
                RECT rectangle{ lyricMarginX, static_cast<LONG>(cursorY + offsetY),
                    lyricMarginX + lyricWidth, static_cast<LONG>(cursorY + offsetY + row.height) };
                const auto area = surface.DrawMask(cues[static_cast<size_t>(row.cue)].text, request.fontFamily, row.fontSize,
                    offset == 0 ? FW_SEMIBOLD : FW_NORMAL, rectangle, alignment | DT_VCENTER);
                const auto color = offset == 0 && request.lyricAnimation == 4
                    ? RGB(static_cast<BYTE>(197 + 58 * transition), static_cast<BYTE>(176 + 79 * transition), 255)
                    : RGB(255, 255, 255);
                surface.Composite(frame, area, opacity, color, request.lyricGlow);
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

    HRESULT ReadBackgroundAudioPcm(const std::wstring& path, std::vector<std::int16_t>& samples,
        size_t maximumBytes = 256ull * 1024 * 1024, float progressBase = 0, float progressSpan = 0)
    {
        ComPtr<IMFSourceReader> reader;
        auto result = CreateAudioReader(path, reader);
        if (FAILED(result)) return S_OK; // A background video without an audio stream is valid.
        double duration = 0;
        ReadDuration(reader.Get(), duration);

        for (;;)
        {
            if (ExportCancelled.load(std::memory_order_relaxed)) return HRESULT_FROM_WIN32(ERROR_CANCELLED);
            DWORD stream = 0;
            DWORD flags = 0;
            LONGLONG sampleTime = 0;
            ComPtr<IMFSample> sample;
            result = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &stream, &flags, &sampleTime, sample.GetAddressOf());
            if (FAILED(result)) return result;
            if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
            if (!sample) continue;

            ComPtr<IMFMediaBuffer> buffer;
            result = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
            if (FAILED(result)) return result;
            BYTE* data = nullptr;
            DWORD maximum = 0;
            DWORD length = 0;
            result = buffer->Lock(&data, &maximum, &length);
            if (FAILED(result)) return result;
            if (samples.size() * sizeof(std::int16_t) + length > maximumBytes)
            {
                buffer->Unlock();
                return HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
            }
            const auto oldSize = samples.size();
            samples.resize(oldSize + length / sizeof(std::int16_t));
            std::memcpy(samples.data() + oldSize, data, length - (length % sizeof(std::int16_t)));
            buffer->Unlock();
            if (progressSpan > 0 && duration > 0)
                ExportProgress.store(std::clamp(progressBase + progressSpan * static_cast<float>(sampleTime /
                    static_cast<double>(TicksPerSecond) / duration), progressBase, progressBase + progressSpan),
                    std::memory_order_relaxed);
        }
        return S_OK;
    }

    HRESULT MixBackgroundAudio(IMFSample* sample, LONGLONG outputTime,
        const std::vector<std::vector<std::int16_t>>& backgrounds,
        const std::vector<BackgroundMediaDescriptor>& media, const ExportRequest& request,
        double singleVideoDuration)
    {
        if (!sample || !request.backgroundAudioEnabled || request.backgroundAudioVolume <= 0) return S_OK;
        ComPtr<IMFMediaBuffer> buffer;
        auto result = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
        if (FAILED(result)) return result;
        BYTE* data = nullptr;
        DWORD maximum = 0;
        DWORD length = 0;
        result = buffer->Lock(&data, &maximum, &length);
        if (FAILED(result)) return result;
        const auto primaryFrames = length / (AudioChannels * sizeof(std::int16_t));
        const auto firstFrame = static_cast<std::uint64_t>(std::max<LONGLONG>(0, outputTime)) * AudioSampleRate / TicksPerSecond;
        auto* primary = reinterpret_cast<std::int16_t*>(data);
        for (size_t frame = 0; frame < primaryFrames; ++frame)
        {
            const double seconds = static_cast<double>(firstFrame + frame) / AudioSampleRate;
            const auto state = BackgroundStateAt(seconds, request.outputDuration, media,
                request.backgroundTransition, request.backgroundTransitionDuration, singleVideoDuration);
            auto addClip = [&](size_t index, double localTime, float gain)
            {
                if (index >= backgrounds.size() || gain <= 0.0001f) return;
                const auto& pcm = backgrounds[index];
                const auto frames = pcm.size() / AudioChannels;
                if (frames == 0) return;
                auto sourceFrame = static_cast<std::uint64_t>(std::max(0.0, localTime) * AudioSampleRate);
                sourceFrame = request.loopBackgroundVideo ? sourceFrame % frames : std::min<std::uint64_t>(sourceFrame, frames - 1);
                for (size_t channel = 0; channel < AudioChannels; ++channel)
                {
                    const auto mixed = static_cast<float>(primary[frame * AudioChannels + channel]) +
                        static_cast<float>(pcm[sourceFrame * AudioChannels + channel]) * request.backgroundAudioVolume * gain;
                    primary[frame * AudioChannels + channel] = static_cast<std::int16_t>(std::clamp(
                        static_cast<int>(std::lround(mixed)), -32768, 32767));
                }
            };
            const float progress = state.nextIndex ? state.transitionProgress : 0.0f;
            double outgoingLocalTime = state.currentLocalTime;
            if (state.nextIndex && *state.nextIndex != state.currentIndex && media.size() > 1)
            {
                const auto blend = std::min(std::max(0.05, static_cast<double>(request.backgroundTransitionDuration)), state.segmentDuration * 0.45);
                outgoingLocalTime = std::max(0.0, state.segmentDuration - blend + progress * blend);
            }
            addClip(state.currentIndex, outgoingLocalTime, 1.0f - progress);
            if (state.nextIndex) addClip(*state.nextIndex, state.nextLocalTime, progress);
        }
        buffer->Unlock();
        return S_OK;
    }

    HRESULT WriteAudioUntil(IMFSinkWriter* writer, DWORD audioIndex, IMFSourceReader* reader,
        ComPtr<IMFSample>& pending, LONGLONG& pendingTime, LONGLONG& pendingDuration, LONGLONG& loopOffset,
        double audioDuration, double outputDuration, LONGLONG throughTime, bool loopAudio,
        const std::vector<std::vector<std::int16_t>>& backgroundPcm,
        const std::vector<BackgroundMediaDescriptor>& backgrounds, const ExportRequest& request,
        double singleVideoDuration)
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
            auto mixResult = MixBackgroundAudio(pending.Get(), outputTime, backgroundPcm,
                backgrounds, request, singleVideoDuration);
            if (FAILED(mixResult)) return mixResult;
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
            ExportProgress.store(0, std::memory_order_relaxed);

            const auto backgrounds = ParseBackgroundManifest(request.backgroundManifest);
            if (backgrounds.empty())
            {
                result = E_INVALIDARG;
                goto cleanup;
            }
            auto currentBackground = std::make_unique<BackgroundSource>();
            result = currentBackground->Open(0, backgrounds[0], request.loopBackgroundVideo);
            if (FAILED(result)) goto cleanup;
            std::unique_ptr<BackgroundSource> nextBackground;
            const double singleVideoDuration = backgrounds.size() == 1 && request.loopBackgroundVideo
                ? currentBackground->duration() : 0;
            std::vector<std::vector<std::int16_t>> backgroundAudioPcm(backgrounds.size());
            if (request.backgroundAudioEnabled)
            {
                ExportStage.store(2, std::memory_order_relaxed);
                size_t audioMemoryUsed = 0;
                constexpr size_t MaximumBackgroundAudioBytes = 256ull * 1024 * 1024;
                const auto videoAudioCount = static_cast<float>(std::count_if(backgrounds.begin(), backgrounds.end(),
                    [](const auto& item) { return item.video; }));
                size_t videoAudioIndex = 0;
                for (size_t index = 0; index < backgrounds.size(); ++index)
                {
                    if (!backgrounds[index].video) continue;
                    result = ReadBackgroundAudioPcm(backgrounds[index].path, backgroundAudioPcm[index],
                        MaximumBackgroundAudioBytes - audioMemoryUsed,
                        videoAudioCount > 0 ? static_cast<float>(videoAudioIndex) / videoAudioCount : 0,
                        videoAudioCount > 0 ? 1.0f / videoAudioCount : 0);
                    if (FAILED(result)) goto cleanup;
                    audioMemoryUsed += backgroundAudioPcm[index].size() * sizeof(std::int16_t);
                    ++videoAudioIndex;
                }
            }
            ExportProgress.store(1, std::memory_order_relaxed);

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
            std::array<float, AudioBandCount> smoothedBands{};
            ExportStage.store(3, std::memory_order_relaxed);
            ExportProgress.store(0, std::memory_order_relaxed);

            for (std::uint64_t frame = 0; frame < frameCount; ++frame)
            {
                if (ExportCancelled.load(std::memory_order_relaxed))
                {
                    result = HRESULT_FROM_WIN32(ERROR_CANCELLED);
                    break;
                }
                const auto time = frame / static_cast<double>(VideoFps);
                const auto frameTime = static_cast<LONGLONG>(frame) * frameDuration;
                const auto backgroundState = BackgroundStateAt(time, request.outputDuration, backgrounds,
                    request.backgroundTransition, request.backgroundTransitionDuration,
                    request.loopBackgroundVideo ? singleVideoDuration : 0);
                if (currentBackground->index != backgroundState.currentIndex)
                {
                    if (nextBackground && nextBackground->index == backgroundState.currentIndex &&
                        backgroundState.nextIndex != backgroundState.currentIndex)
                        std::swap(currentBackground, nextBackground);
                    else
                    {
                        currentBackground = std::make_unique<BackgroundSource>();
                        result = currentBackground->Open(backgroundState.currentIndex, backgrounds[backgroundState.currentIndex], request.loopBackgroundVideo);
                        if (FAILED(result)) break;
                    }
                }
                if (backgroundState.nextIndex)
                {
                    if (!nextBackground || nextBackground->index != *backgroundState.nextIndex ||
                        (backgroundState.nextIndex == backgroundState.currentIndex && nextBackground == currentBackground))
                    {
                        nextBackground = std::make_unique<BackgroundSource>();
                        result = nextBackground->Open(*backgroundState.nextIndex, backgrounds[*backgroundState.nextIndex], request.loopBackgroundVideo);
                        if (FAILED(result)) break;
                    }
                }
                else nextBackground.reset();

                result = currentBackground->Update(backgroundState.currentLocalTime, false);
                if (FAILED(result)) break;
                if (backgroundState.nextIndex)
                {
                    result = nextBackground->Update(backgroundState.nextLocalTime, true);
                    if (FAILED(result)) break;
                }
                result = SikaMTV_SetBackgroundMotionTimeline(
                    static_cast<float>(std::clamp(backgroundState.currentLocalTime / std::max(0.001, backgroundState.segmentDuration), 0.0, 1.0)),
                    backgrounds[backgroundState.currentIndex].video ? 0.16f : 1.0f,
                    static_cast<float>(std::clamp(backgroundState.nextLocalTime / std::max(0.001, backgroundState.segmentDuration), 0.0, 1.0)),
                    backgroundState.nextIndex
                        ? (backgrounds[*backgroundState.nextIndex].video ? 0.16f : 1.0f)
                        : 0.0f);
                if (FAILED(result)) break;
                result = SikaMTV_SetBackgroundTransition(backgroundState.transitionProgress, backgroundState.transitionKind);
                if (FAILED(result)) break;
                const auto& paletteA = backgrounds[backgroundState.currentIndex];
                const auto& paletteB = backgroundState.nextIndex ? backgrounds[*backgroundState.nextIndex] : paletteA;
                const float paletteMix = backgroundState.nextIndex ? backgroundState.transitionProgress : 0.0f;
                result = SikaMTV_SetScenePalette(
                    std::lerp(paletteA.primary[0], paletteB.primary[0], paletteMix),
                    std::lerp(paletteA.primary[1], paletteB.primary[1], paletteMix),
                    std::lerp(paletteA.primary[2], paletteB.primary[2], paletteMix),
                    std::lerp(paletteA.secondary[0], paletteB.secondary[0], paletteMix),
                    std::lerp(paletteA.secondary[1], paletteB.secondary[1], paletteMix),
                    std::lerp(paletteA.secondary[2], paletteB.secondary[2], paletteMix));
                if (FAILED(result)) break;

                const auto audioFrame = static_cast<size_t>(frame) % static_cast<size_t>(analysisFrames);
                const auto* rawBands = analysis.data() + audioFrame * AudioBandCount;
                const float attack = 0.82f - request.visualizerSmoothing * 0.44f;
                const float release = 0.50f - request.visualizerSmoothing * 0.38f;
                for (size_t band = 0; band < smoothedBands.size(); ++band)
                {
                    const auto coefficient = rawBands[band] > smoothedBands[band] ? attack : release;
                    smoothedBands[band] += (rawBands[band] - smoothedBands[band]) * coefficient;
                }
                result = SikaMTV_RenderExportFrame(request.width, request.height, static_cast<float>(time), request.visualizerKind,
                    request.intensity, request.blur, request.vignette, request.saturation, request.slowZoom,
                    request.visualizerScale, request.rainbow, smoothedBands.data(), AudioBandCount, pixels.data(), static_cast<int>(pixels.size()));
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
                    request.outputDuration, frameTime + frameDuration, request.articleMode,
                    backgroundAudioPcm, backgrounds, request,
                    request.loopBackgroundVideo ? singleVideoDuration : 0);
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

int __cdecl SikaMTV_StartVideoExport(const wchar_t* backgroundManifest, const wchar_t* audioPath, const wchar_t* outputPath,
    const wchar_t* textTimeline, const wchar_t* title, const wchar_t* author, const wchar_t* date, const wchar_t* fontFamily,
    double audioDurationSeconds, double outputDurationSeconds, unsigned int width, unsigned int height, unsigned int visualizerKind,
    float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow,
    float visualizerSmoothing,
    float lyricFontSize, float lyricPosition, float lyricWidth, float lyricLineSpacing, float lyricInactiveOpacity,
    float lyricGlow, float lyricAnimationDuration, int lyricAlignment, int lyricWindowCount, int lyricAnimation, int articleMode,
    float articleFontSize, float articleLineSpacing, float introDuration, float introTitleSize, float introAnimationDuration,
    int introEnabled, int showIntroDate, int introAnimation,
    int loopBackgroundVideo, int backgroundTransition, float backgroundTransitionDuration,
    int backgroundAudioEnabled, float backgroundAudioVolume)
{
    if (audioPath == nullptr || audioPath[0] == L'\0' || outputPath == nullptr || outputPath[0] == L'\0') return E_INVALIDARG;
    if (ExportRunning.exchange(true, std::memory_order_acq_rel)) return HRESULT_FROM_WIN32(ERROR_BUSY);
    if (ExportThread.joinable()) ExportThread.join();

    try
    {
        ExportRequest request;
        request.backgroundManifest = SafeString(backgroundManifest);
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
        request.visualizerSmoothing = std::clamp(visualizerSmoothing, 0.0f, 1.0f);
        request.lyricFontSize = lyricFontSize;
        request.lyricPosition = lyricPosition;
        request.lyricWidth = lyricWidth;
        request.lyricLineSpacing = lyricLineSpacing;
        request.lyricInactiveOpacity = lyricInactiveOpacity;
        request.lyricGlow = lyricGlow;
        request.lyricAnimationDuration = lyricAnimationDuration;
        request.lyricAlignment = lyricAlignment;
        request.lyricWindowCount = lyricWindowCount;
        request.lyricAnimation = lyricAnimation;
        request.articleMode = articleMode != 0;
        request.articleFontSize = articleFontSize;
        request.articleLineSpacing = articleLineSpacing;
        request.introDuration = introDuration;
        request.introTitleSize = std::clamp(introTitleSize, 36.0f, 96.0f);
        request.introAnimationDuration = std::clamp(introAnimationDuration, 0.2f, 3.0f);
        request.introEnabled = introEnabled != 0;
        request.showIntroDate = showIntroDate != 0;
        request.introAnimation = introAnimation;
        request.loopBackgroundVideo = loopBackgroundVideo != 0;
        request.backgroundTransition = std::clamp(backgroundTransition, 0, 3);
        request.backgroundTransitionDuration = std::clamp(backgroundTransitionDuration, 0.2f, 2.5f);
        request.backgroundAudioEnabled = backgroundAudioEnabled != 0;
        request.backgroundAudioVolume = std::clamp(backgroundAudioVolume, 0.0f, 1.0f);

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
    return SikaMTV_UpdatePreviewBackgroundCarousel(path, timeSeconds, L"", 0, loop, 0, 0);
}

int __cdecl SikaMTV_UpdatePreviewBackgroundCarousel(const wchar_t* primaryVideoPath, double primaryTime,
    const wchar_t* secondaryVideoPath, double secondaryTime, int loop, float transitionProgress, int transitionKind)
{
    try
    {
        const auto requestedPrimary = SafeString(primaryVideoPath);
        const auto requestedSecondary = SafeString(secondaryVideoPath);
        const auto requestedLoop = loop != 0;
        const auto safePrimaryTime = std::max(0.0, primaryTime);
        const auto safeSecondaryTime = std::max(0.0, secondaryTime);
        const auto transitionResult = SikaMTV_SetBackgroundTransition(transitionProgress, transitionKind);
        if (FAILED(static_cast<HRESULT>(transitionResult))) return transitionResult;
        bool startWorker = false;
        {
            std::scoped_lock lock(PreviewRequestMutex);
            const bool sourceChanged = requestedPrimary != PreviewRequestedPrimaryPath ||
                requestedSecondary != PreviewRequestedSecondaryPath || PreviewRequestedLoop != requestedLoop;
            if (sourceChanged || std::abs(PreviewRequestedPrimarySeconds - safePrimaryTime) >= 0.012 ||
                std::abs(PreviewRequestedSecondarySeconds - safeSecondaryTime) >= 0.012)
            {
                PreviewRequestedPrimaryPath = requestedPrimary;
                PreviewRequestedPrimarySeconds = safePrimaryTime;
                PreviewRequestedSecondaryPath = requestedSecondary;
                PreviewRequestedSecondarySeconds = safeSecondaryTime;
                PreviewRequestedLoop = requestedLoop;
                ++PreviewRequestVersion;
            }
            if (sourceChanged) PreviewVideoResult.store(S_OK, std::memory_order_relaxed);
            startWorker = (!requestedPrimary.empty() || !requestedSecondary.empty()) && (!PreviewVideoThread.joinable() ||
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
    PreviewRequestedPrimaryPath.clear();
    PreviewRequestedPrimarySeconds = 0;
    PreviewRequestedSecondaryPath.clear();
    PreviewRequestedSecondarySeconds = 0;
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
            : stage == 2 ? 0.08f + ExportProgress.load(std::memory_order_relaxed) * 0.05f
            : stage == 3 ? 0.13f + ExportProgress.load(std::memory_order_relaxed) * 0.87f
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
