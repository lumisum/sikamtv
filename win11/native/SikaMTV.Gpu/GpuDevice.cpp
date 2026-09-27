#include "GpuDevice.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dwrite.h>
#include <dwrite_3.h>
#include <dxgi1_6.h>
#include <windows.ui.xaml.media.dxinterop.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iterator>
#include <mutex>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace
{
    constexpr UINT NvidiaVendorId = 0x10DE;
    constexpr UINT VisualizerBands = 64;
    constexpr size_t AdvancedSettingCount = 41;
    std::array<float, AdvancedSettingCount> AdvancedSettings = {
        0.31f, 0.96f, 0.86f, 0.72f,
        0.72f, 0.28f, 0.72f, 0.56f,
        0.55f, 0.88f, 1.0f, 0.74f,
        0.48f, 0.72f, 1.0f, 0.73f,
        0.54f, 1.0f, 0.0f, 0.58f,
        0.68f, 0.52f, 0.70f, 1.0f,
        0.82f, 0.12f, 0.20f, 1.0f,
        1.0f, 1.0f, 0.0f,
        0.0f, 0.42f, 0.34f, 0.14f,
        0.22f, 0.12f, 0.82f, 1.0f,
        0.12f, 1.0f
    };

    struct alignas(16) VisualState
    {
        float timeSeconds;
        float intensity;
        float width;
        float height;
        UINT visualizerKind;
        UINT bandCount;
        float padding[2];
        float bands[VisualizerBands];
        float backgroundInfo[4];
        float backgroundTransition[4];
        float backgroundEffects[4];
        float visualizerEffects[4];
        float scenePalettePrimary[4];
        float scenePaletteSecondary[4];
        float visualizerAdvanced1[4];
        float visualizerAdvanced2[4];
        float visualizerAdvanced3[4];
        float atmosphereSettings[4];
        float atmosphereGeometry[4];
        float backgroundColorSettings[4];
        float backgroundMotion[4];
        float backgroundMotion2[4];
        float backgroundMotion3[4];
        float backgroundTimeline[4];
    };

    static_assert(sizeof(VisualState) == 544);

    std::mutex DeviceMutex;
    ComPtr<ID3D11Device> Device;
    ComPtr<ID3D11DeviceContext> Context;
    ComPtr<IDXGIAdapter1> SelectedAdapter;
    ComPtr<IDXGISwapChain1> SwapChain;
    ComPtr<ID3D11RenderTargetView> RenderTarget;
    ComPtr<ID3D11VertexShader> VertexShader;
    ComPtr<ID3D11PixelShader> PixelShader;
    ComPtr<ID3D11Buffer> ConstantBuffer;
    ComPtr<ID3D11BlendState> BlendState;
    ComPtr<ID3D11Texture2D> BackgroundTexture;
    ComPtr<ID3D11ShaderResourceView> BackgroundView;
    ComPtr<ID3D11Texture2D> SecondaryBackgroundTexture;
    ComPtr<ID3D11ShaderResourceView> SecondaryBackgroundView;
    ComPtr<ID3D11Texture2D> SubjectMaskTexture;
    ComPtr<ID3D11ShaderResourceView> SubjectMaskView;
    ComPtr<ID3D11Texture2D> SecondarySubjectMaskTexture;
    ComPtr<ID3D11ShaderResourceView> SecondarySubjectMaskView;
    ComPtr<ID3D11SamplerState> BackgroundSampler;
    ComPtr<ID3D11Texture2D> ExportTexture;
    ComPtr<ID3D11Texture2D> ExportStagingTexture;
    ComPtr<ID3D11RenderTargetView> ExportRenderTarget;
    bool SelectedNvidia = false;
    UINT SurfaceWidth = 0;
    UINT SurfaceHeight = 0;
    UINT BackgroundWidth = 0;
    UINT BackgroundHeight = 0;
    UINT SecondaryBackgroundWidth = 0;
    UINT SecondaryBackgroundHeight = 0;
    float BackgroundTransitionProgress = 0;
    int BackgroundTransitionKind = 0;
    std::array<float, 4> BackgroundMotionTimeline{};
    UINT ExportWidth = 0;
    UINT ExportHeight = 0;

    HRESULT CreateDeviceForAdapter(IDXGIAdapter1* adapter, ComPtr<ID3D11Device>& device, ComPtr<ID3D11DeviceContext>& context)
    {
        const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
        D3D_FEATURE_LEVEL selectedLevel{};
        auto result = D3D11CreateDevice(
            adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
            levels,
            ARRAYSIZE(levels),
            D3D11_SDK_VERSION,
            device.GetAddressOf(),
            &selectedLevel,
            context.GetAddressOf());

        if (result == E_INVALIDARG)
        {
            device.Reset();
            context.Reset();
            result = D3D11CreateDevice(
                adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                &levels[1],
                1,
                D3D11_SDK_VERSION,
                device.GetAddressOf(),
                &selectedLevel,
                context.GetAddressOf());
        }
        return result;
    }

    HRESULT CreateRenderResources()
    {
        if (!Device || !Context) return E_UNEXPECTED;

        wchar_t executablePath[MAX_PATH]{};
        const auto length = GetModuleFileNameW(nullptr, executablePath, ARRAYSIZE(executablePath));
        if (length == 0 || length >= ARRAYSIZE(executablePath)) return HRESULT_FROM_WIN32(GetLastError());
        const auto shaderPath = std::filesystem::path(executablePath).parent_path() / L"Assets" / L"Shaders" / L"Visualizer.hlsl";

        ComPtr<ID3DBlob> vertexCode;
        ComPtr<ID3DBlob> pixelCode;
        ComPtr<ID3DBlob> diagnostics;
        auto result = D3DCompileFromFile(shaderPath.c_str(), nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE,
            "VSMain", "vs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, vertexCode.GetAddressOf(), diagnostics.GetAddressOf());
        if (FAILED(result)) return result;
        diagnostics.Reset();
        result = D3DCompileFromFile(shaderPath.c_str(), nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE,
            "PSMain", "ps_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, pixelCode.GetAddressOf(), diagnostics.GetAddressOf());
        if (FAILED(result)) return result;

        result = Device->CreateVertexShader(vertexCode->GetBufferPointer(), vertexCode->GetBufferSize(), nullptr, VertexShader.GetAddressOf());
        if (FAILED(result)) return result;
        result = Device->CreatePixelShader(pixelCode->GetBufferPointer(), pixelCode->GetBufferSize(), nullptr, PixelShader.GetAddressOf());
        if (FAILED(result)) return result;

        D3D11_BUFFER_DESC bufferDescription{};
        bufferDescription.ByteWidth = sizeof(VisualState);
        bufferDescription.Usage = D3D11_USAGE_DYNAMIC;
        bufferDescription.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        bufferDescription.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        result = Device->CreateBuffer(&bufferDescription, nullptr, ConstantBuffer.GetAddressOf());
        if (FAILED(result)) return result;

        D3D11_BLEND_DESC blendDescription{};
        auto& target = blendDescription.RenderTarget[0];
        target.BlendEnable = TRUE;
        target.SrcBlend = D3D11_BLEND_ONE;
        target.DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
        target.BlendOp = D3D11_BLEND_OP_ADD;
        target.SrcBlendAlpha = D3D11_BLEND_ONE;
        target.DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
        target.BlendOpAlpha = D3D11_BLEND_OP_ADD;
        target.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
        result = Device->CreateBlendState(&blendDescription, BlendState.GetAddressOf());
        if (FAILED(result)) return result;
        D3D11_SAMPLER_DESC samplerDescription{};
        samplerDescription.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        samplerDescription.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
        samplerDescription.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
        samplerDescription.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        samplerDescription.MaxLOD = D3D11_FLOAT32_MAX;
        return Device->CreateSamplerState(&samplerDescription, BackgroundSampler.GetAddressOf());
    }

    HRESULT CreateRenderTarget()
    {
        if (!SwapChain) return E_UNEXPECTED;
        ComPtr<ID3D11Texture2D> backBuffer;
        auto result = SwapChain->GetBuffer(0, IID_PPV_ARGS(backBuffer.GetAddressOf()));
        if (FAILED(result)) return result;
        return Device->CreateRenderTargetView(backBuffer.Get(), nullptr, RenderTarget.GetAddressOf());
    }

    HRESULT CreateExportTarget(UINT width, UINT height)
    {
        if (!Device || width == 0 || height == 0) return E_INVALIDARG;
        ExportRenderTarget.Reset();
        ExportStagingTexture.Reset();
        ExportTexture.Reset();

        D3D11_TEXTURE2D_DESC targetDescription{};
        targetDescription.Width = width;
        targetDescription.Height = height;
        targetDescription.MipLevels = 1;
        targetDescription.ArraySize = 1;
        targetDescription.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        targetDescription.SampleDesc.Count = 1;
        targetDescription.Usage = D3D11_USAGE_DEFAULT;
        targetDescription.BindFlags = D3D11_BIND_RENDER_TARGET;
        auto result = Device->CreateTexture2D(&targetDescription, nullptr, ExportTexture.GetAddressOf());
        if (FAILED(result)) return result;
        result = Device->CreateRenderTargetView(ExportTexture.Get(), nullptr, ExportRenderTarget.GetAddressOf());
        if (FAILED(result)) return result;

        auto stagingDescription = targetDescription;
        stagingDescription.Usage = D3D11_USAGE_STAGING;
        stagingDescription.BindFlags = 0;
        stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        result = Device->CreateTexture2D(&stagingDescription, nullptr, ExportStagingTexture.GetAddressOf());
        if (SUCCEEDED(result))
        {
            ExportWidth = width;
            ExportHeight = height;
        }
        return result;
    }

    HRESULT RenderVisualizerFrame(ID3D11RenderTargetView* target, UINT width, UINT height, float timeSeconds,
        UINT visualizerKind, float intensity, float blur, float vignette, float saturation, float slowZoom,
        float visualizerScale, float rainbow, const float* bands, int bandCount)
    {
        if (!target || !ConstantBuffer || !VertexShader || !PixelShader || !BackgroundSampler) return E_UNEXPECTED;

        VisualState state{};
        state.timeSeconds = timeSeconds;
        state.intensity = std::clamp(intensity * visualizerScale, 0.0f, 1.5f);
        state.width = static_cast<float>(width);
        state.height = static_cast<float>(height);
        state.backgroundInfo[0] = BackgroundView ? 1.0f : 0.0f;
        state.backgroundInfo[1] = static_cast<float>(BackgroundWidth);
        state.backgroundInfo[2] = static_cast<float>(BackgroundHeight);
        state.backgroundTransition[0] = BackgroundTransitionProgress;
        state.backgroundTransition[1] = static_cast<float>(BackgroundTransitionKind);
        state.backgroundTransition[2] = static_cast<float>(SecondaryBackgroundWidth);
        state.backgroundTransition[3] = static_cast<float>(SecondaryBackgroundHeight);
        state.backgroundEffects[0] = std::clamp(blur, 0.0f, 1.0f);
        state.backgroundEffects[1] = std::clamp(vignette, 0.0f, 1.0f);
        state.backgroundEffects[2] = std::clamp(saturation, 0.0f, 2.0f);
        state.backgroundEffects[3] = std::clamp(slowZoom, 0.0f, 1.0f);
        state.visualizerEffects[0] = std::clamp(visualizerScale, 0.4f, 1.5f);
        state.visualizerEffects[1] = rainbow > 0.5f ? 1.0f : 0.0f;
        state.visualizerEffects[2] = AdvancedSettings[26];
        state.scenePalettePrimary[0] = AdvancedSettings[12];
        state.scenePalettePrimary[1] = AdvancedSettings[13];
        state.scenePalettePrimary[2] = AdvancedSettings[14];
        state.scenePaletteSecondary[0] = AdvancedSettings[15];
        state.scenePaletteSecondary[1] = AdvancedSettings[16];
        state.scenePaletteSecondary[2] = AdvancedSettings[17];
        std::copy_n(AdvancedSettings.begin(), 4, state.visualizerAdvanced1);
        std::copy_n(AdvancedSettings.begin() + 4, 4, state.visualizerAdvanced2);
        std::copy_n(AdvancedSettings.begin() + 8, 4, state.visualizerAdvanced3);
        std::copy_n(AdvancedSettings.begin() + 18, 4, state.atmosphereSettings);
        std::copy_n(AdvancedSettings.begin() + 22, 4, state.atmosphereGeometry);
        std::copy_n(AdvancedSettings.begin() + 27, 4, state.backgroundColorSettings);
        std::copy_n(AdvancedSettings.begin() + 31, 4, state.backgroundMotion);
        std::copy_n(AdvancedSettings.begin() + 35, 4, state.backgroundMotion2);
        std::copy_n(AdvancedSettings.begin() + 39, 2, state.backgroundMotion3);
        state.backgroundMotion3[2] = SubjectMaskView ? 1.0f : 0.0f;
        state.backgroundMotion3[3] = SecondarySubjectMaskView ? 1.0f : 0.0f;
        std::copy(BackgroundMotionTimeline.begin(), BackgroundMotionTimeline.end(), state.backgroundTimeline);
        state.visualizerKind = std::min(visualizerKind, 10u);
        state.bandCount = std::clamp(static_cast<UINT>(std::max(0, bandCount)), 1u, VisualizerBands);
        if (bands != nullptr)
        {
            for (UINT index = 0; index < state.bandCount; ++index)
                state.bands[index] = std::clamp(bands[index], 0.0f, 1.0f);
        }

        D3D11_MAPPED_SUBRESOURCE mapped{};
        auto result = Context->Map(ConstantBuffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
        if (FAILED(result)) return result;
        memcpy(mapped.pData, &state, sizeof(state));
        Context->Unmap(ConstantBuffer.Get(), 0);

        const float clearColor[4] = { 0, 0, 0, 1 };
        Context->ClearRenderTargetView(target, clearColor);
        D3D11_VIEWPORT viewport{};
        viewport.Width = static_cast<float>(width);
        viewport.Height = static_cast<float>(height);
        viewport.MinDepth = 0;
        viewport.MaxDepth = 1;
        Context->RSSetViewports(1, &viewport);
        Context->OMSetRenderTargets(1, &target, nullptr);
        const float blendFactor[4] = { 0, 0, 0, 0 };
        Context->OMSetBlendState(BlendState.Get(), blendFactor, 0xFFFFFFFF);
        Context->IASetInputLayout(nullptr);
        Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        Context->VSSetShader(VertexShader.Get(), nullptr, 0);
        Context->PSSetShader(PixelShader.Get(), nullptr, 0);
        Context->PSSetConstantBuffers(0, 1, ConstantBuffer.GetAddressOf());
        ID3D11ShaderResourceView* backgroundViews[] = {
            BackgroundView.Get(), SecondaryBackgroundView.Get(), SubjectMaskView.Get(), SecondarySubjectMaskView.Get()
        };
        Context->PSSetShaderResources(0, 4, backgroundViews);
        auto sampler = BackgroundSampler.Get();
        Context->PSSetSamplers(0, 1, &sampler);
        Context->Draw(3, 0);
        ID3D11ShaderResourceView* noBackground[] = { nullptr, nullptr, nullptr, nullptr };
        Context->PSSetShaderResources(0, 4, noBackground);
        Context->OMSetRenderTargets(0, nullptr, nullptr);
        return S_OK;
    }
}

int __cdecl SikaMTV_InitializeGpu(wchar_t* adapterName, int capacity, int* isNvidia)
{
    if (adapterName == nullptr || capacity <= 0 || isNvidia == nullptr) return E_INVALIDARG;
    adapterName[0] = L'\0';
    *isNvidia = 0;

    std::scoped_lock lock(DeviceMutex);
    if (Device && SelectedAdapter)
    {
        DXGI_ADAPTER_DESC1 description{};
        if (SUCCEEDED(SelectedAdapter->GetDesc1(&description)))
        {
            wcsncpy_s(adapterName, static_cast<size_t>(capacity), description.Description, _TRUNCATE);
            *isNvidia = SelectedNvidia ? 1 : 0;
            return S_OK;
        }
    }

    ComPtr<IDXGIFactory6> factory;
    auto result = CreateDXGIFactory2(0, IID_PPV_ARGS(factory.GetAddressOf()));
    if (FAILED(result)) return result;

    std::vector<ComPtr<IDXGIAdapter1>> adapters;
    for (UINT index = 0;; ++index)
    {
        ComPtr<IDXGIAdapter1> adapter;
        result = factory->EnumAdapterByGpuPreference(index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(adapter.GetAddressOf()));
        if (result == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(result)) continue;
        DXGI_ADAPTER_DESC1 description{};
        if (FAILED(adapter->GetDesc1(&description)) || (description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) continue;
        adapters.push_back(std::move(adapter));
    }

    std::stable_sort(adapters.begin(), adapters.end(), [](const auto& left, const auto& right)
    {
        DXGI_ADAPTER_DESC1 a{};
        DXGI_ADAPTER_DESC1 b{};
        left->GetDesc1(&a);
        right->GetDesc1(&b);
        return (a.VendorId == NvidiaVendorId) > (b.VendorId == NvidiaVendorId);
    });

    HRESULT lastError = DXGI_ERROR_NOT_FOUND;
    for (auto& adapter : adapters)
    {
        ComPtr<ID3D11Device> candidateDevice;
        ComPtr<ID3D11DeviceContext> candidateContext;
        result = CreateDeviceForAdapter(adapter.Get(), candidateDevice, candidateContext);
        if (FAILED(result))
        {
            lastError = result;
            continue;
        }
        DXGI_ADAPTER_DESC1 description{};
        if (FAILED(adapter->GetDesc1(&description))) continue;
        Device = std::move(candidateDevice);
        Context = std::move(candidateContext);
        SelectedAdapter = adapter;
        SelectedNvidia = description.VendorId == NvidiaVendorId;
        wcsncpy_s(adapterName, static_cast<size_t>(capacity), description.Description, _TRUNCATE);
        *isNvidia = SelectedNvidia ? 1 : 0;
        return S_OK;
    }

    return lastError;
}

int __cdecl SikaMTV_AttachSwapChainPanel(IUnknown* panel, unsigned int width, unsigned int height)
{
    if (panel == nullptr || width == 0 || height == 0) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    if (!Device) return E_UNEXPECTED;

    auto result = CreateRenderResources();
    if (FAILED(result)) return result;

    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    result = Device.As(&dxgiDevice);
    if (FAILED(result)) return result;
    result = dxgiDevice->GetAdapter(adapter.GetAddressOf());
    if (FAILED(result)) return result;
    result = adapter->GetParent(IID_PPV_ARGS(factory.GetAddressOf()));
    if (FAILED(result)) return result;

    DXGI_SWAP_CHAIN_DESC1 description{};
    description.Width = width;
    description.Height = height;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    description.BufferCount = 2;
    description.Scaling = DXGI_SCALING_STRETCH;
    description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    description.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    result = factory->CreateSwapChainForComposition(Device.Get(), &description, nullptr, SwapChain.GetAddressOf());
    if (FAILED(result)) return result;

    ComPtr<ISwapChainPanelNative> nativePanel;
    result = panel->QueryInterface(IID_PPV_ARGS(nativePanel.GetAddressOf()));
    if (FAILED(result)) return result;
    result = nativePanel->SetSwapChain(SwapChain.Get());
    if (FAILED(result)) return result;

    SurfaceWidth = width;
    SurfaceHeight = height;
    return CreateRenderTarget();
}

int __cdecl SikaMTV_ResizeSwapChainPanel(unsigned int width, unsigned int height)
{
    if (width == 0 || height == 0) return S_FALSE;
    std::scoped_lock lock(DeviceMutex);
    if (!SwapChain) return E_UNEXPECTED;
    Context->OMSetRenderTargets(0, nullptr, nullptr);
    RenderTarget.Reset();
    auto result = SwapChain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0);
    if (FAILED(result)) return result;
    SurfaceWidth = width;
    SurfaceHeight = height;
    return CreateRenderTarget();
}

int __cdecl SikaMTV_SetBackgroundImage(const unsigned char* pixels, unsigned int width, unsigned int height, unsigned int stride)
{
    if (pixels == nullptr || width == 0 || height == 0 || stride < width * 4) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    if (!Device) return E_UNEXPECTED;
    if (BackgroundTexture && BackgroundWidth == width && BackgroundHeight == height)
    {
        Context->UpdateSubresource(BackgroundTexture.Get(), 0, nullptr, pixels, stride, 0);
        return S_OK;
    }
    BackgroundView.Reset();
    BackgroundTexture.Reset();
    D3D11_TEXTURE2D_DESC description{};
    description.Width = width;
    description.Height = height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA initial{};
    initial.pSysMem = pixels;
    initial.SysMemPitch = stride;
    auto result = Device->CreateTexture2D(&description, &initial, BackgroundTexture.GetAddressOf());
    if (FAILED(result)) return result;
    result = Device->CreateShaderResourceView(BackgroundTexture.Get(), nullptr, BackgroundView.GetAddressOf());
    if (FAILED(result)) BackgroundTexture.Reset();
    else
    {
        BackgroundWidth = width;
        BackgroundHeight = height;
    }
    return result;
}

int __cdecl SikaMTV_SetBackgroundImageSecondary(const unsigned char* pixels, unsigned int width, unsigned int height, unsigned int stride)
{
    if (pixels == nullptr || width == 0 || height == 0 || stride < width * 4) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    if (!Device) return E_UNEXPECTED;
    if (SecondaryBackgroundTexture && SecondaryBackgroundWidth == width && SecondaryBackgroundHeight == height)
    {
        Context->UpdateSubresource(SecondaryBackgroundTexture.Get(), 0, nullptr, pixels, stride, 0);
        return S_OK;
    }
    SecondaryBackgroundView.Reset();
    SecondaryBackgroundTexture.Reset();
    D3D11_TEXTURE2D_DESC description{};
    description.Width = width;
    description.Height = height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA initial{};
    initial.pSysMem = pixels;
    initial.SysMemPitch = stride;
    auto result = Device->CreateTexture2D(&description, &initial, SecondaryBackgroundTexture.GetAddressOf());
    if (FAILED(result)) return result;
    result = Device->CreateShaderResourceView(SecondaryBackgroundTexture.Get(), nullptr, SecondaryBackgroundView.GetAddressOf());
    if (FAILED(result)) SecondaryBackgroundTexture.Reset();
    else
    {
        SecondaryBackgroundWidth = width;
        SecondaryBackgroundHeight = height;
    }
    return result;
}

int __cdecl SikaMTV_SetSubjectMask(const unsigned char* pixels, unsigned int width, unsigned int height, unsigned int stride, int secondary)
{
    if (secondary != 0 && secondary != 1) return E_INVALIDARG;
    if (pixels == nullptr || width == 0 || height == 0)
    {
        std::scoped_lock lock(DeviceMutex);
        auto& texture = secondary ? SecondarySubjectMaskTexture : SubjectMaskTexture;
        auto& view = secondary ? SecondarySubjectMaskView : SubjectMaskView;
        view.Reset();
        texture.Reset();
        return S_OK;
    }
    if (stride < width || static_cast<std::uint64_t>(stride) * height > MAXDWORD) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    if (!Device) return E_UNEXPECTED;
    auto& texture = secondary ? SecondarySubjectMaskTexture : SubjectMaskTexture;
    auto& view = secondary ? SecondarySubjectMaskView : SubjectMaskView;
    if (texture && view)
    {
        D3D11_TEXTURE2D_DESC existing{};
        texture->GetDesc(&existing);
        if (existing.Width == width && existing.Height == height)
        {
            Context->UpdateSubresource(texture.Get(), 0, nullptr, pixels, stride, 0);
            return S_OK;
        }
    }
    D3D11_TEXTURE2D_DESC description{};
    description.Width = width;
    description.Height = height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_R8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA initial{};
    initial.pSysMem = pixels;
    initial.SysMemPitch = stride;
    auto result = Device->CreateTexture2D(&description, &initial, texture.ReleaseAndGetAddressOf());
    if (FAILED(result)) return result;
    result = Device->CreateShaderResourceView(texture.Get(), nullptr, view.ReleaseAndGetAddressOf());
    if (FAILED(result)) texture.Reset();
    return result;
}

int __cdecl SikaMTV_SetBackgroundTransition(float progress, int transitionKind)
{
    if (!std::isfinite(progress) || transitionKind < 0 || transitionKind > 4) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    BackgroundTransitionProgress = std::clamp(progress, 0.0f, 1.0f);
    BackgroundTransitionKind = transitionKind;
    return S_OK;
}

int __cdecl SikaMTV_SetBackgroundMotionTimeline(float currentProgress, float currentReactivity,
    float nextProgress, float nextReactivity)
{
    const float values[] = { currentProgress, currentReactivity, nextProgress, nextReactivity };
    if (!std::all_of(std::begin(values), std::end(values), [](float value) { return std::isfinite(value); })) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    for (size_t index = 0; index < BackgroundMotionTimeline.size(); ++index)
        BackgroundMotionTimeline[index] = std::clamp(values[index], 0.0f, 1.0f);
    return S_OK;
}

int __cdecl SikaMTV_SetScenePalette(float primaryRed, float primaryGreen, float primaryBlue,
    float secondaryRed, float secondaryGreen, float secondaryBlue)
{
    const float values[] = { primaryRed, primaryGreen, primaryBlue, secondaryRed, secondaryGreen, secondaryBlue };
    if (!std::all_of(std::begin(values), std::end(values), [](float value) { return std::isfinite(value); })) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    for (size_t index = 0; index < 3; ++index)
    {
        AdvancedSettings[12 + index] = std::clamp(values[index], 0.0f, 1.0f);
        AdvancedSettings[15 + index] = std::clamp(values[index + 3], 0.0f, 1.0f);
    }
    return S_OK;
}

void __cdecl SikaMTV_ClearBackgroundImage()
{
    std::scoped_lock lock(DeviceMutex);
    BackgroundView.Reset();
    BackgroundTexture.Reset();
    SecondaryBackgroundView.Reset();
    SecondaryBackgroundTexture.Reset();
    SubjectMaskView.Reset();
    SubjectMaskTexture.Reset();
    SecondarySubjectMaskView.Reset();
    SecondarySubjectMaskTexture.Reset();
    BackgroundTransitionProgress = 0;
    BackgroundTransitionKind = 0;
    BackgroundMotionTimeline.fill(0);
    BackgroundWidth = 0;
    BackgroundHeight = 0;
    SecondaryBackgroundWidth = 0;
    SecondaryBackgroundHeight = 0;
}

int __cdecl SikaMTV_SetAdvancedVisualSettings(const float* settings, int count)
{
    if (settings == nullptr || count < static_cast<int>(AdvancedSettingCount)) return E_INVALIDARG;
    std::scoped_lock lock(DeviceMutex);
    for (size_t index = 0; index < AdvancedSettingCount; ++index)
        AdvancedSettings[index] = std::isfinite(settings[index]) ? settings[index] : AdvancedSettings[index];
    AdvancedSettings[18] = std::clamp(AdvancedSettings[18], 0.0f, 16.0f);
    AdvancedSettings[19] = std::clamp(AdvancedSettings[19], 0.0f, 1.0f);
    AdvancedSettings[20] = std::clamp(AdvancedSettings[20], 0.0f, 1.0f);
    AdvancedSettings[21] = std::clamp(AdvancedSettings[21], 0.0f, 1.0f);
    AdvancedSettings[22] = std::clamp(AdvancedSettings[22], 0.48f, 0.88f);
    return S_OK;
}

int __cdecl SikaMTV_RenderVisualizer(float timeSeconds, unsigned int visualizerKind, float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow, const float* bands, int bandCount)
{
    std::scoped_lock lock(DeviceMutex);
    if (!SwapChain || !RenderTarget || !ConstantBuffer || !VertexShader || !PixelShader) return E_UNEXPECTED;
    const auto result = RenderVisualizerFrame(RenderTarget.Get(), SurfaceWidth, SurfaceHeight, timeSeconds, visualizerKind,
        intensity, blur, vignette, saturation, slowZoom, visualizerScale, rainbow, bands, bandCount);
    if (FAILED(result)) return result;
    return SwapChain->Present(1, 0);
}

int __cdecl SikaMTV_RenderExportFrame(unsigned int width, unsigned int height, float timeSeconds, unsigned int visualizerKind,
    float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow,
    const float* bands, int bandCount, unsigned char* bgra, int capacity)
{
    if (width == 0 || height == 0 || bgra == nullptr || capacity < 0) return E_INVALIDARG;
    const auto required = static_cast<std::uint64_t>(width) * height * 4;
    if (required > static_cast<std::uint64_t>(capacity)) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);

    std::scoped_lock lock(DeviceMutex);
    if (!Device) return E_UNEXPECTED;
    auto result = CreateRenderResources();
    if (FAILED(result)) return result;
    if (!ExportTexture || ExportWidth != width || ExportHeight != height)
    {
        result = CreateExportTarget(width, height);
        if (FAILED(result)) return result;
    }

    result = RenderVisualizerFrame(ExportRenderTarget.Get(), width, height, timeSeconds, visualizerKind,
        intensity, blur, vignette, saturation, slowZoom, visualizerScale, rainbow, bands, bandCount);
    if (FAILED(result)) return result;
    Context->CopyResource(ExportStagingTexture.Get(), ExportTexture.Get());

    D3D11_MAPPED_SUBRESOURCE mapped{};
    result = Context->Map(ExportStagingTexture.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result)) return result;
    const auto destinationStride = static_cast<size_t>(width) * 4;
    for (UINT row = 0; row < height; ++row)
    {
        memcpy(bgra + static_cast<size_t>(row) * destinationStride,
            static_cast<const unsigned char*>(mapped.pData) + static_cast<size_t>(row) * mapped.RowPitch,
            destinationStride);
    }
    Context->Unmap(ExportStagingTexture.Get(), 0);
    return S_OK;
}

int __cdecl SikaMTV_GetExportD3DDevice(IUnknown** device)
{
    if (device == nullptr) return E_POINTER;
    *device = nullptr;
    std::scoped_lock lock(DeviceMutex);
    if (!Device) return E_UNEXPECTED;
    return Device->QueryInterface(IID_PPV_ARGS(device));
}

void __cdecl SikaMTV_DetachSwapChainPanel()
{
    std::scoped_lock lock(DeviceMutex);
    Context.Reset();
    RenderTarget.Reset();
    SwapChain.Reset();
    VertexShader.Reset();
    PixelShader.Reset();
    ConstantBuffer.Reset();
    BlendState.Reset();
    BackgroundSampler.Reset();
    SurfaceWidth = 0;
    SurfaceHeight = 0;
}

void __cdecl SikaMTV_ShutdownGpu()
{
    SikaMTV_DetachSwapChainPanel();
    std::scoped_lock lock(DeviceMutex);
    Device.Reset();
    SelectedAdapter.Reset();
    SelectedNvidia = false;
    BackgroundView.Reset();
    BackgroundTexture.Reset();
    SecondaryBackgroundView.Reset();
    SecondaryBackgroundTexture.Reset();
    SubjectMaskView.Reset();
    SubjectMaskTexture.Reset();
    SecondarySubjectMaskView.Reset();
    SecondarySubjectMaskTexture.Reset();
    ExportRenderTarget.Reset();
    ExportStagingTexture.Reset();
    ExportTexture.Reset();
    BackgroundWidth = 0;
    BackgroundHeight = 0;
    SecondaryBackgroundWidth = 0;
    SecondaryBackgroundHeight = 0;
    BackgroundTransitionProgress = 0;
    BackgroundTransitionKind = 0;
    BackgroundMotionTimeline.fill(0);
    ExportWidth = 0;
    ExportHeight = 0;
}

int __cdecl SikaMTV_GetFontFamily(const wchar_t* path, wchar_t* familyName, int capacity)
{
    if (path == nullptr || familyName == nullptr || capacity <= 0) return E_INVALIDARG;
    familyName[0] = L'\0';

    ComPtr<IDWriteFactory> factory;
    auto result = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(factory.GetAddressOf()));
    if (FAILED(result)) return result;
    ComPtr<IDWriteFontFile> fontFile;
    result = factory->CreateFontFileReference(path, nullptr, fontFile.GetAddressOf());
    if (FAILED(result)) return result;
    BOOL supported = FALSE;
    DWRITE_FONT_FILE_TYPE fileType{};
    DWRITE_FONT_FACE_TYPE faceType{};
    UINT32 faceCount = 0;
    result = fontFile->Analyze(&supported, &fileType, &faceType, &faceCount);
    if (FAILED(result) || !supported || faceCount == 0) return FAILED(result) ? result : E_FAIL;
    IDWriteFontFile* fontFiles[] = { fontFile.Get() };
    ComPtr<IDWriteFontFace> baseFace;
    result = factory->CreateFontFace(faceType, 1, fontFiles, 0, DWRITE_FONT_SIMULATIONS_NONE, baseFace.GetAddressOf());
    if (FAILED(result)) return result;

    ComPtr<IDWriteFontFace6> face;
    result = baseFace.As(&face);
    if (FAILED(result)) return result;
    ComPtr<IDWriteLocalizedStrings> names;
    result = face->GetFamilyNames(DWRITE_FONT_FAMILY_MODEL_TYPOGRAPHIC, names.GetAddressOf());
    if (FAILED(result) || !names) return FAILED(result) ? result : E_FAIL;

    UINT32 localeIndex = 0;
    BOOL localeFound = FALSE;
    names->FindLocaleName(L"zh-cn", &localeIndex, &localeFound);
    if (!localeFound) names->FindLocaleName(L"en-us", &localeIndex, &localeFound);
    if (!localeFound) localeIndex = 0;
    UINT32 length = 0;
    result = names->GetStringLength(localeIndex, &length);
    if (FAILED(result)) return result;
    if (length + 1 > static_cast<UINT32>(capacity)) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    std::vector<wchar_t> name(length + 1);
    result = names->GetString(localeIndex, name.data(), static_cast<UINT32>(name.size()));
    if (FAILED(result)) return result;
    wcsncpy_s(familyName, static_cast<size_t>(capacity), name.data(), _TRUNCATE);
    return S_OK;
}
