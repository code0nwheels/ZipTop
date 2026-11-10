#!/usr/bin/env bash
# Builds the ZipTop release for Linux and packs it as an AppImage.
#
# 1. linux/third_party/build_libmpv.sh (pinned libmpv 0.42; skipped when built)
# 2. flutter build linux --release, stamped with --version and --build-number
# 3. Copies the bundle into an AppDir, adds the libraries it needs that a
#    desktop cannot be relied on to have (tray, keyring, X extensions...),
#    and packs it with a pinned appimagetool and AppImage runtime.
#
# The AppImage lands in build/appimage/ZipTop-<version>-x86_64.AppImage.
# Installed copies find it by that name in GitHub Releases; see
# lib/features/update/update_service.dart.
#
# Usage: tool/build_appimage.sh [--version 1.2.0] [--build-number 7]
#                               [--flutter /path/to/flutter]
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

# Pinned packaging tools, checked by SHA-256.
APPIMAGETOOL_URL=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
APPIMAGETOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
RUNTIME_URL=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

out="$root/build/appimage"
tools="$out/tools"
mkdir -p "$tools"
fetch() { # url sha256 file
  if [[ ! -f "$3" ]]; then
    curl -fsSL --retry 3 -o "$3.download" "$1"
    mv "$3.download" "$3"
  fi
  echo "$2  $3" | sha256sum --check --status || { echo "$3 does not match the pinned SHA-256." >&2; exit 1; }
}
fetch "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256" "$tools/appimagetool"
fetch "$RUNTIME_URL" "$RUNTIME_SHA256" "$tools/runtime-x86_64"
chmod +x "$tools/appimagetool"

linux/third_party/build_libmpv.sh

export ZIPTOP_REQUIRE_BUNDLED_LIBMPV=1
"$flutter" build linux --release --build-name="$version" --build-number="$build_number"
bundle="$root/build/linux/x64/release/bundle"
[[ -x "$bundle/ziptop" && -f "$bundle/lib/libmpv.so.2" ]] || { echo "No ziptop with bundled libmpv in $bundle." >&2; exit 1; }

appdir="$out/ZipTop.AppDir"
rm -rf "$appdir"
cp -a "$bundle" "$appdir"
install -m 755 linux/packaging/AppRun "$appdir/AppRun"
install -m 644 linux/packaging/ziptop.desktop "$appdir/com.zipstreams.ziptop.desktop"
install -m 644 assets/icon.png "$appdir/com.zipstreams.ziptop.png"
ln -sf com.zipstreams.ziptop.png "$appdir/.DirIcon"

# Libraries every desktop this targets has, matched by soname. They are
# never bundled: glibc, the GPU and VA-API drivers' libraries, X11 and
# Wayland, the GTK stack, audio servers' clients, and OpenSSL (so the
# system's certificate store is used). Everything else the app and its
# plugins load is copied into lib/. (The newer libdrm built with libmpv is
# already in lib/ and stays there.)
system_libs='^(ld-linux(-x86-64)?|libc|libm|libdl|libpthread|librt|libresolv|libutil|libanl|libstdc\+\+|libgcc_s|libGL|libEGL|libGLX|libGLdispatch|libOpenGL|libgbm|libdrm|libva|libva-drm|libva-x11|libvdpau|libvulkan|libX11|libX11-xcb|libxcb[a-z0-9-]*|libXau|libXdmcp|libXext|libXrender|libXrandr|libXi|libXfixes|libXcursor|libXinerama|libXcomposite|libXdamage|libxkbcommon|libwayland-[a-z]+|libgtk-3|libgdk-3|libglib-2\.0|libgobject-2\.0|libgio-2\.0|libgmodule-2\.0|libgthread-2\.0|libpango-1\.0|libpangocairo-1\.0|libpangoft2-1\.0|libcairo|libcairo-gobject|libgdk_pixbuf-2\.0|libatk-1\.0|libatk-bridge-2\.0|libatspi|libepoxy|libharfbuzz|libfreetype|libfontconfig|libfribidi|libpng16|libz|libexpat|libdbus-1|libsystemd|libselinux|libmount|libblkid|libffi|libpcre2-8|libuuid|libpulse|libpulse-simple|libpulse-mainloop-glib|libasound|libssl|libcrypto|libgcrypt|libgpg-error|liblzma|libzstd|libbz2|libbrotli[a-z]*|libjpeg|libtiff|libwebp|libjbig|libdeflate|libLerc|libthai|libdatrie|libgraphite2|libpixman-1|libxml2|libicu[a-z]+|libsndfile|libFLAC|libvorbis|libvorbisenc|libogg|libopus|libmp3lame|libmpg123|libasyncns|libapparmor|liblz4|libcap|libgmp|libnettle|libhogweed|libgnutls|libtasn1|libidn2|libunistring|libp11-kit|libkeyutils|libkrb5|libk5crypto|libcom_err|libgssapi_krb5|libkrb5support)\.so'

lib="$appdir/lib"
declare -A seen=()
queue=("$appdir/ziptop" "$lib"/*.so*)
bundled=()
while [[ ${#queue[@]} -gt 0 ]]; do
  elf="${queue[0]}"; queue=("${queue[@]:1}")
  [[ -f "$elf" && ! -L "$elf" ]] || continue
  [[ -z "${seen[$elf]:-}" ]] || continue
  seen[$elf]=1
  # Where each library resolves: "libfoo.so.1 => /usr/lib/.../libfoo.so.1 (0x...)"
  declare -A where=()
  while read -r name path; do where[$name]="$path"; done \
    < <(LD_LIBRARY_PATH="$lib" ldd "$elf" | awk '/=>/ { print $1, $3 }')
  # Only direct dependencies, so a system library's own private ones (which
  # come with it on the user's machine) are not dragged in.
  while read -r name; do
    [[ "$name" =~ $system_libs ]] && continue
    [[ -e "$lib/$name" ]] && continue
    path="${where[$name]:-}"
    [[ "$path" == /* ]] || { echo "Missing dependency $name of $elf" >&2; exit 1; }
    cp -L "$path" "$lib/$name"
    chmod 644 "$lib/$name"
    bundled+=("$name")
    queue+=("$lib/$name")
  done < <(readelf -d "$elf" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p')
  unset where
done
echo "Bundled system libraries: ${bundled[*]:-none}"

# Every library looks next to itself, and nowhere else. The plugins come out
# of the build with the build machine's absolute paths (for libmpv in
# linux/third_party), which on a user's machine would let a system libmpv in.
for so in "$lib"/*.so*; do
  [[ -L "$so" ]] || patchelf --set-rpath '$ORIGIN' "$so"
done
if readelf -d "$appdir/ziptop" "$lib"/*.so* 2>/dev/null | grep -E 'R(UN)?PATH' | grep -v -E '\[\$ORIGIN(/lib)?\]'; then
  echo "A library still has a RUNPATH outside the AppImage." >&2
  exit 1
fi

target="$out/ZipTop-$version-x86_64.AppImage"
rm -f "$target"
ARCH=x86_64 VERSION="$version" "$tools/appimagetool" --appimage-extract-and-run \
  --runtime-file "$tools/runtime-x86_64" --no-appstream "$appdir" "$target"
echo "AppImage: $target ($(du -h "$target" | cut -f1))"
