<#
.SYNOPSIS
  Works out which version a CI build is, and whether it is a release.

.DESCRIPTION
  - A merge to main is released automatically: the newest v* tag bumped by
    -Bump (patch, minor or major), e.g. v1.2.3 -> 1.2.4. CI takes -Bump from
    the merged pull request's release:minor / release:major label and
    defaults to patch. With no tags yet it is the pubspec.yaml version.
  - -Bump none (the release:skip label, or any branch other than main) is a
    test build: the next patch as a pre-release, e.g. 1.2.4-dev.57.
  - A pushed tag v1.2.3 is release 1.2.3.
  - A manual run with a version typed in is that release.
  For every release the tag is made when the release is published.

  Writes version, release and build_number to $env:GITHUB_OUTPUT when set,
  and always prints them.

.EXAMPLE
  ./tool/resolve_version.ps1 -RefType branch -RefName main -RunNumber 57 -Bump minor
#>
param(
  [string]$RefType = 'branch',
  [string]$RefName = '',
  [string]$InputVersion = '',
  [int]$RunNumber = 0,
  [ValidateSet('patch', 'minor', 'major', 'none')]
  [string]$Bump = 'none'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$plain = '^(\d+)\.(\d+)\.(\d+)$'

function Test-Plain([string]$v, [string]$from) {
  if ($v -notmatch $plain) { throw "$from '$v' is not a version like 1.2.3." }
}

function Test-Unreleased([string]$v) {
  $existing = git -C $root tag --list "v$v"
  if ($existing) { throw "v$v has already been released." }
}

# The newest v1.2.3 tag as a [version], or $null when there is none.
function Get-LatestRelease {
  $tags = @(git -C $root tag --list 'v*' | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
    ForEach-Object { [version]($_ -replace '^v', '') } | Sort-Object -Descending)
  if ($tags.Count -gt 0) { return $tags[0] } else { return $null }
}

function Get-PubspecVersion {
  $line = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
  if (-not $line) { throw 'No v* tags and no version in pubspec.yaml.' }
  return $line.Matches[0].Groups[1].Value
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
  Test-Unreleased $version
  $release = $true
} else {
  $last = Get-LatestRelease
  if ($Bump -ne 'none' -and $RefName -eq 'main') {
    $version = if (-not $last) {
      Get-PubspecVersion
    } else {
      switch ($Bump) {
        'major' { "$($last.Major + 1).0.0" }
        'minor' { "$($last.Major).$($last.Minor + 1).0" }
        'patch' { "$($last.Major).$($last.Minor).$($last.Build + 1)" }
      }
    }
    Test-Unreleased $version
    $release = $true
  } else {
    $base = if ($last) { "$($last.Major).$($last.Minor).$($last.Build + 1)" } else { Get-PubspecVersion }
    $version = "$base-dev.$RunNumber"
  }
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
