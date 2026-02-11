param(
    [string]$FfmpegZipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
    [switch]$SkipFfmpegDownload
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $scriptRoot "..")
Set-Location $projectRoot

Write-Host "[1/7] Checking toolchain..."
Require-Command "flutter"

Write-Host "[2/7] Enabling Windows desktop support..."
flutter config --enable-windows-desktop | Out-Host

Write-Host "[3/7] Restoring Dart dependencies..."
flutter pub get | Out-Host

Write-Host "[4/7] Building Windows release..."
flutter build windows --release | Out-Host

$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$nameMatch = Select-String -Path $pubspecPath -Pattern "^\s*name:\s*([a-zA-Z0-9_]+)\s*$" | Select-Object -First 1
$appName = if ($nameMatch) { $nameMatch.Matches[0].Groups[1].Value } else { "myapp" }
$appExe = "$appName.exe"

$buildOutput = Join-Path $projectRoot "build\windows\x64\runner\Release"
if (-not (Test-Path $buildOutput)) {
    throw "Build output not found: $buildOutput"
}
if (-not (Test-Path (Join-Path $buildOutput $appExe))) {
    throw "App executable not found after build: $appExe"
}

$distRoot = Join-Path $projectRoot "dist"
$bundleName = "CaptureVisionTransfer"
$bundlePath = Join-Path $distRoot $bundleName
$zipPath = Join-Path $distRoot "$bundleName-portable-windows.zip"

Write-Host "[5/7] Preparing bundle directory..."
if (Test-Path $bundlePath) {
    Remove-Item -Recurse -Force $bundlePath
}
New-Item -ItemType Directory -Path $bundlePath | Out-Null
Copy-Item -Recurse -Force (Join-Path $buildOutput "*") $bundlePath

if (-not $SkipFfmpegDownload) {
    Write-Host "[6/7] Downloading and bundling ffmpeg..."
    $tempRoot = Join-Path $env:TEMP ("capture_vision_ffmpeg_" + [guid]::NewGuid().ToString("N"))
    $zipDownload = Join-Path $tempRoot "ffmpeg.zip"
    $extractPath = Join-Path $tempRoot "extract"
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    Invoke-WebRequest -Uri $FfmpegZipUrl -OutFile $zipDownload
    Expand-Archive -Path $zipDownload -DestinationPath $extractPath -Force

    $ffmpegExePath = Get-ChildItem -Path $extractPath -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    if (-not $ffmpegExePath) {
        throw "Could not find ffmpeg.exe in downloaded archive."
    }
    $ffmpegBinSource = Split-Path -Parent $ffmpegExePath.FullName
    $ffmpegBinTarget = Join-Path $bundlePath "ffmpeg\bin"
    New-Item -ItemType Directory -Path $ffmpegBinTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $ffmpegBinSource "*.exe") -Destination $ffmpegBinTarget -Force

    Remove-Item -Recurse -Force $tempRoot
} else {
    Write-Host "[6/7] Skipping ffmpeg download as requested."
}

$launcher = @"
@echo off
setlocal
cd /d %~dp0
start "" ".\$appExe"
"@
$launcherPath = Join-Path $bundlePath "run_app.bat"
$launcher | Set-Content -Path $launcherPath -Encoding ascii

$guideSource = Join-Path $projectRoot "tools\WINDOWS_PORTABLE_README_CN.txt"
if (Test-Path $guideSource) {
    Copy-Item -Path $guideSource -Destination (Join-Path $bundlePath "README_CN.txt") -Force
}

Write-Host "[7/7] Creating portable zip..."
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}
Compress-Archive -Path $bundlePath -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Done."
Write-Host "Bundle folder: $bundlePath"
Write-Host "Portable zip : $zipPath"
