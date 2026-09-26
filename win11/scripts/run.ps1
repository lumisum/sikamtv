param([switch]$NoBuild)

$ErrorActionPreference = "Stop"
$winRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$app = Join-Path $winRoot "artifacts\publish\win-x64\SikaMTV.exe"
if (-not $NoBuild -or -not (Test-Path $app)) {
    & (Join-Path $PSScriptRoot "build.ps1")
}
if (-not (Test-Path $app)) { throw "没有找到应用程序：$app" }
Start-Process -FilePath $app -WorkingDirectory (Split-Path $app)
