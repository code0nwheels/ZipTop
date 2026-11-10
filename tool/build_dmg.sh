#!/usr/bin/env bash
# Builds the ZipTop release for macOS (Apple Silicon) and packs it as a DMG.
#
# 1. macos/third_party/build_libmpv.sh (pinned libmpv 0.42; skipped when built)
# 2. flutter build macos --release, stamped with --version and --build-number
# 3. Makes sure ZipTop.app/Contents/Frameworks/Mpv.framework holds the 0.42
#    build. The Xcode build step that macos/Podfile adds has already swapped
#    it in; install_libmpv.sh is run again without --optional so a missing
#    libmpv fails the release instead of shipping media_kit's older one.
# 4. Checks that every library the app loads is inside the bundle, signs it
#    ad hoc (there is no Developer ID; see README.md) and packs a DMG with an
#    Applications shortcut.
#
# The DMG lands in build/dmg/ZipTop-<version>-macos-arm64.dmg. Installed
# copies find it by that name in GitHub Releases; see
# lib/features/update/update_service.dart.
#
# Usage: tool/build_dmg.sh [--version 1.2.0] [--build-number 7]
#                          [--flutter /path/to/flutter]
# The version defaults to pubspec.yaml's. CI passes both; see
# .github/workflows/build-installer.yml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version=""
build_number=0
flutter="$(command -v flutter || true)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --build-number) build_number="$2"; shift 2 ;;
    --flutter) flutter="$2"; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -x "$flutter" ]] || { echo "Flutter not found. Put it on PATH or pass --flutter." >&2; exit 1; }

if [[ -z "$version" ]]; then
  version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml | head -1)"
  [[ -n "$version" ]] || { echo "No --version given and none found in pubspec.yaml." >&2; exit 1; }
fi
version="${version#v}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Version '$version' is not of the form 1.2.3 or 1.2.3-dev.4." >&2
  exit 1
fi
echo "Building ZipTop $version (build $build_number)"

macos/third_party/build_libmpv.sh

"$flutter" build macos --release --build-name="$version" --build-number="$build_number"
app="$root/build/macos/Build/Products/Release/ZipTop.app"
[[ -x "$app/Contents/MacOS/ZipTop" ]] || { echo "No ZipTop.app in $(dirname "$app")." >&2; exit 1; }

macos/third_party/install_libmpv.sh "$app"

frameworks="$app/Contents/Frameworks"
mpv="$frameworks/Mpv.framework/Versions/A/Mpv"
[[ -f "$mpv" ]] || { echo "No Mpv.framework in $frameworks." >&2; exit 1; }

# Let Mpv find the libraries beside it in Frameworks by itself, not only
# through the app's own rpath, so tool/mpv_probe.dart can load it outside
# the app.
if ! otool -l "$mpv" | grep -A2 LC_RPATH | grep -q '@loader_path/../../..'; then
  install_name_tool -add_rpath '@loader_path/../../..' "$mpv"
fi

# Every Mach-O in the bundle may only load system libraries (/usr/lib,
# /System) or libraries inside the bundle. A reference to Homebrew or to the
# build folder would work here and fail on everyone else's Mac.
machos=()
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then machos+=("$f"); fi
done < <(find "$app/Contents" -type f -print0)
bad=0
for f in "${machos[@]}"; do
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*) ;;
      # The Swift runtime, part of macOS 13 and later (in the dyld shared
      # cache, so not on disk to check).
      @rpath/libswift*) ;;
      @rpath/*)
        leaf="${dep#@rpath/}"
        if [[ ! -e "$frameworks/$leaf" ]]; then
          echo "${f#"$app"/}: $dep is not in Contents/Frameworks" >&2
          bad=1
        fi
        ;;
      @loader_path/*|@executable_path/*) ;;
      *)
        echo "${f#"$app"/}: loads $dep from outside the app" >&2
        bad=1
        ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{ print $1 }')
done
[[ $bad -eq 0 ]] || { echo "The app depends on libraries it does not ship." >&2; exit 1; }
echo "Checked ${#machos[@]} Mach-O files: every library is in the bundle or the system."

# Ad-hoc signature over the whole bundle, after every change above.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

out="$root/build/dmg"
stage="$out/stage"
rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/ZipTop.app"
ln -s /Applications "$stage/Applications"
target="$out/ZipTop-$version-macos-arm64.dmg"
rm -f "$target"
hdiutil create -volname ZipTop -srcfolder "$stage" -ov -format UDZO "$target"
rm -rf "$stage"
echo "DMG: $target ($(du -h "$target" | cut -f1))"
