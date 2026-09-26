param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$winRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gpuProject = Join-Path $winRoot "native\SikaMTV.Gpu\SikaMTV.Gpu.vcxproj"
$appProject = Join-Path $winRoot "src\SikaMTV.App\SikaMTV.App.csproj"
$nativeOutput = Join-Path $winRoot "artifacts\x64\$Configuration"
$publishOutput = Join-Path $winRoot "artifacts\publish\win-x64"
$nativeIntermediate = Join-Path $winRoot "artifacts\obj\SikaMTV.Gpu\x64\$Configuration"
$msbuildCommand = Get-Command msbuild -ErrorAction SilentlyContinue

if (-not $msbuildCommand) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $candidate = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
        if ($candidate) { $msbuildCommand = @{ Source = $candidate } }
    }
}

if (-not $msbuildCommand) {
    throw "找不到 Visual Studio MSBuild。请安装 Visual Studio 2022/Build Tools，并勾选 C++ 桌面开发、Windows 11 SDK 和 .NET 桌面开发。"
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "找不到 dotnet SDK。请安装 .NET 10 SDK 后重试。"
}

New-Item -ItemType Directory -Force -Path $nativeOutput, $nativeIntermediate, $publishOutput | Out-Null
$nativeArgs = @(
    $gpuProject,
    "/m",
    "/nologo",
    "/p:Configuration=$Configuration",
    "/p:Platform=x64",
    "/p:OutDir=$nativeOutput\",
    "/p:IntDir=$nativeIntermediate\"
)
& $msbuildCommand.Source @nativeArgs
if ($LASTEXITCODE -ne 0) { throw "Direct3D GPU 模块构建失败，退出码：$LASTEXITCODE" }

& dotnet publish $appProject -c $Configuration -r win-x64 --self-contained true `
    -p:WindowsAppSDKSelfContained=true -p:WindowsPackageType=None -o $publishOutput
if ($LASTEXITCODE -ne 0) { throw "SikaMTV Windows 应用发布失败，退出码：$LASTEXITCODE" }

$gpuDll = Join-Path $nativeOutput "SikaMTV.Gpu.dll"
if (-not (Test-Path $gpuDll)) { throw "GPU DLL 未生成：$gpuDll" }
Copy-Item -Force $gpuDll (Join-Path $publishOutput "SikaMTV.Gpu.dll")
Write-Host "发布完成：$publishOutput\SikaMTV.exe" -ForegroundColor Green
