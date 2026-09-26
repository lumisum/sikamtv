param([switch]$NoBuild)

$ErrorActionPreference = "Stop"
$winRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$source = Join-Path $winRoot "artifacts\publish\win-x64"
$target = Join-Path $env:LOCALAPPDATA "Programs\SikaMTV"

if (-not $NoBuild -or -not (Test-Path (Join-Path $source "SikaMTV.exe"))) {
    & (Join-Path $PSScriptRoot "build.ps1")
}
if (-not (Test-Path (Join-Path $source "SikaMTV.exe"))) { throw "发布目录中没有 SikaMTV.exe。" }

New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
$shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\SikaMTV.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $target "SikaMTV.exe"
$shortcut.WorkingDirectory = $target
$shortcut.Description = "SikaMTV 音乐可视化视频生成器"
$shortcut.Save()
Write-Host "已安装到：$target" -ForegroundColor Green
Write-Host "开始菜单中已创建 SikaMTV 快捷方式。"
