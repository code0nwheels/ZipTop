<#
.SYNOPSIS
  Builds the ZipTop release and its Windows installer.

.DESCRIPTION
  1. flutter build windows --release
  2. Copies the Visual C++ runtime DLLs next to ziptop.exe, so the app runs
     on a PC that does not have the redistributable installed.
  3. Compiles installer\ziptop.iss with Inno Setup 6, unless -SkipInstaller.

  The installer lands in installer\output\ZipTop-Setup-<version>.exe.

.PARAMETER Flutter
  Path to flutter.bat. Defaults to the one on PATH, then C:\src\flutter.

.PARAMETER SkipInstaller
  Stop after the release build; do not run Inno Setup.
#>
param(
  [string]$Flutter,
  [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $Flutter) {
  $onPath = Get-Command flutter -ErrorAction SilentlyContinue
  $Flutter = if ($onPath) { $onPath.Source } else { 'C:\src\flutter\bin\flutter.bat' }
}
if (-not (Test-Path $Flutter)) { throw "Flutter not found at $Flutter. Pass -Flutter <path to flutter.bat>." }

# The version comes from pubspec.yaml: "version: 1.2.3+4" -> 1.2.3
$versionLine = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
if (-not $versionLine) { throw 'Could not read the version from pubspec.yaml.' }
$version = $versionLine.Matches[0].Groups[1].Value
Write-Host "Building ZipTop $version"

& $Flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build failed.' }

$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'ziptop.exe'))) { throw "No ziptop.exe in $release." }

# Visual C++ runtime, from the newest Visual Studio redistributable folder.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = if (Test-Path $vswhere) { & $vswhere -latest -products * -property installationPath } else { $null }
$crt = if ($vs) {
  Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d' } | Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if ($crt) {
  foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    Copy-Item (Join-Path $crt $dll) $release -Force
  }
  Write-Host "Bundled the Visual C++ runtime from $crt"
} else {
  Write-Warning 'Visual C++ runtime DLLs not found; the app will need the redistributable installed.'
}

if ($SkipInstaller) { Write-Host "Release build is in $release"; return }

$iscc = @(
  (Get-Command iscc -ErrorAction SilentlyContinue | ForEach-Object Source),
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) is not installed. Install it, or run with -SkipInstaller.' }

& $iscc "/DAppVersion=$version" (Join-Path $root 'installer\ziptop.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed.' }

$setup = Join-Path $root "installer\output\ZipTop-Setup-$version.exe"
Write-Host "Installer: $setup ($([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB)"
