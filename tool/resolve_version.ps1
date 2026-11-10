<#
.SYNOPSIS
  Works out which version a CI build is, and whether it is a release.

.DESCRIPTION
  - A pushed tag v1.2.3 is release 1.2.3.
  - A manual run with a version typed in is that release; the tag is made
    when the release is published.
  - Anything else (a merge to main) is a test build: the next patch after
    the newest v* tag, as a pre-release, e.g. 1.2.4-dev.57. With no tags
    yet it is the pubspec.yaml version, e.g. 1.0.0-dev.57.

  Writes version, release and build_number to $env:GITHUB_OUTPUT when set,
  and always prints them.

.EXAMPLE
  ./tool/resolve_version.ps1 -RefType branch -RefName main -RunNumber 57
#>
param(
  [string]$RefType = 'branch',
  [string]$RefName = '',
  [string]$InputVersion = '',
  [int]$RunNumber = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$plain = '^(\d+)\.(\d+)\.(\d+)$'

function Test-Plain([string]$v, [string]$from) {
  if ($v -notmatch $plain) { throw "$from '$v' is not a version like 1.2.3." }
}

$release = $false
if ($RefType -eq 'tag') {
  $version = $RefName -replace '^v', ''
  Test-Plain $version 'Tag'
  $release = $true
} elseif ($InputVersion.Trim()) {
  $version = $InputVersion.Trim() -replace '^v', ''
  Test-Plain $version 'Version'
  if ($RefName -ne 'main') { throw "Releases are made from main, not '$RefName'." }
  $existing = git -C $root tag --list "v$version"
  if ($existing) { throw "v$version has already been released." }
  $release = $true
} else {
  $tags = @(git -C $root tag --list 'v*' | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
    Sort-Object { [version]($_ -replace '^v', '') } -Descending)
  if ($tags.Count -gt 0) {
    $last = [version]($tags[0] -replace '^v', '')
    $base = "$($last.Major).$($last.Minor).$($last.Build + 1)"
  } else {
    $line = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
    if (-not $line) { throw 'No v* tags and no version in pubspec.yaml.' }
    $base = $line.Matches[0].Groups[1].Value
  }
  $version = "$base-dev.$RunNumber"
}

# The Windows file version's last part is limited to 65535.
$buildNumber = $RunNumber % 65536

"version=$version"
"release=$($release.ToString().ToLower())"
"build_number=$buildNumber"
if ($env:GITHUB_OUTPUT) {
  "version=$version" >> $env:GITHUB_OUTPUT
  "release=$($release.ToString().ToLower())" >> $env:GITHUB_OUTPUT
  "build_number=$buildNumber" >> $env:GITHUB_OUTPUT
}
