#!/usr/bin/env bash
# Builds the libmpv that ZipTop ships on macOS (Apple Silicon, macOS 13+).
#
# media_kit_libs_macos_video bundles an mpv older than 0.42, and older
# mpv/FFmpeg crash on the backend's live DASH manifests; see
# lib/player/mpv_player.dart (mpvPlaysDash). This is the macOS counterpart of
# linux/third_party/build_libmpv.sh and of the pinned libmpv download in
# windows/CMakeLists.txt. media_kit_video still links media_kit's
# Mpv.framework; macos/third_party/install_libmpv.sh swaps this build's
# libmpv.2.dylib into the built ZipTop.app in its place (the libmpv ABI is
# stable).
#
# Every source is pinned by SHA-256 (or commit, for libplacebo, which needs
# its git submodules). FFmpeg, libplacebo, libass and libmpv are shared
# libraries; FreeType, FriBidi and HarfBuzz are static and linked into
# libass. Each dylib's install name is @rpath/<name>, they find one another
# through @rpath (LC_RPATH @loader_path), and nothing references Homebrew,
# /usr/local or the build folder; the last step checks that with otool.
# TLS uses Secure Transport, so the system's certificate store is used.
#
# Output: macos/third_party/libmpv/<ZIPTOP_LIBMPV_TAG>/{lib,include}
# macos/third_party/install_libmpv.sh reads ZIPTOP_LIBMPV_TAG from this file,
# so bump it whenever a pin or a build option changes.
#
# Build dependencies: Xcode or the Command Line Tools (clang, make, git,
# python3, otool, install_name_tool, codesign) and curl, plus from Homebrew
# only the build tool pkgconf (`brew install pkgconf`, provides pkg-config).
# nasm is not needed: FFmpeg and libass assemble arm64 code with clang.
# meson and ninja come from pip. Homebrew's libraries are never used:
# PKG_CONFIG_LIBDIR is limited to this build's own .pc files.
#
# Usage: macos/third_party/build_libmpv.sh   (does nothing if already built)
set -euo pipefail

ZIPTOP_LIBMPV_TAG=mpv-0.42.0-ffmpeg-8.1.3-1

FREETYPE_VERSION=2.15.0
FREETYPE_SHA256=93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
FRIBIDI_VERSION=1.0.17
FRIBIDI_SHA256=6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2
HARFBUZZ_VERSION=15.0.0
HARFBUZZ_SHA256=968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df

FFMPEG_VERSION=8.1.3
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
LIBASS_VERSION=0.17.5
LIBASS_SHA256=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
LIBPLACEBO_TAG=v7.387.0
LIBPLACEBO_COMMIT=275f7dea27924cdd34ab2e6c20e448b6bc4fab65
MPV_VERSION=0.42.0
MPV_SHA256=bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd
MESON_VERSION=1.9.1
NINJA_VERSION=1.13.0

export MACOSX_DEPLOYMENT_TARGET=13.0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/libmpv"
prefix="$root/$ZIPTOP_LIBMPV_TAG"
src="$root/src"
jobs="$(sysctl -n hw.ncpu)"

if [[ -f "$prefix/lib/libmpv.2.dylib" ]]; then
  echo "libmpv already built in $prefix"
  exit 0
fi

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This builds libmpv for arm64 macOS and must run on an Apple Silicon Mac (not under Rosetta)." >&2
  exit 1
fi
if ! command -v pkg-config >/dev/null; then
  echo "pkg-config is missing: brew install pkgconf" >&2
  exit 1
fi

# Work in progress is installed here and moved to $prefix when complete.
# Finished steps leave a .built-<name>-<version> mark, so a run that failed
# picks up where it stopped.
stage="$prefix.partial"
mkdir -p "$src" "$stage"
built() { [[ -f "$stage/.built-$1" ]]; }
mark() { touch "$stage/.built-$1"; }

# Build tools, kept out of the system Python.
tools="$root/tools"
if [[ ! -x "$tools/bin/meson" ]]; then
  python3 -m venv "$tools"
  "$tools/bin/pip" install --quiet "meson==$MESON_VERSION" "ninja==$NINJA_VERSION"
fi
export PATH="$tools/bin:$PATH"

fetch() { # url sha256 file
  local url="$1" sha="$2" file="$src/$3"
  if [[ ! -f "$file" ]]; then
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$file.download" "$url"
    mv "$file.download" "$file"
  fi
  if ! echo "$sha  $file" | shasum -a 256 --check --status; then
    echo "$file does not match the pinned SHA-256. Delete it to download again." >&2
    exit 1
  fi
}

unpack() { # file dir
  rm -rf "$src/$2"
  mkdir -p "$src/$2"
  tar -xf "$src/$1" -C "$src/$2" --strip-components=1
}

# Only this build's .pc files are visible, so nothing installed by Homebrew
# (which has freetype, harfbuzz, libass and FFmpeg on GitHub's runners) is
# picked up. zlib and iconv come from the macOS SDK.
export PKG_CONFIG_LIBDIR="$stage/lib/pkgconfig"
unset PKG_CONFIG_PATH
# Room in the Mach-O headers for the install-name and rpath rewrites at the
# end.
export LDFLAGS="-Wl,-headerpad_max_install_names"
meson_common=(--prefix "$stage" --libdir lib --buildtype release --wrap-mode=nodownload)

# --- FreeType, FriBidi, HarfBuzz ------------------------------------------
# Static, for libass only. macOS has none of them, and Homebrew's must not
# end up referenced by the app.
if ! built "freetype-$FREETYPE_VERSION"; then
  fetch "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VERSION/freetype-$FREETYPE_VERSION.tar.xz" "$FREETYPE_SHA256" "freetype-$FREETYPE_VERSION.tar.xz"
  unpack "freetype-$FREETYPE_VERSION.tar.xz" freetype
  (
    cd "$src/freetype"
    meson setup build "${meson_common[@]}" -Ddefault_library=static \
      --auto-features=disabled \
      -Dharfbuzz=disabled -Dzlib=internal -Dmmap=enabled
    meson install -C build
  )
  mark "freetype-$FREETYPE_VERSION"
fi

if ! built "fribidi-$FRIBIDI_VERSION"; then
  fetch "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz" "$FRIBIDI_SHA256" "fribidi-$FRIBIDI_VERSION.tar.xz"
  unpack "fribidi-$FRIBIDI_VERSION.tar.xz" fribidi
  (
    cd "$src/fribidi"
    meson setup build "${meson_common[@]}" -Ddefault_library=static \
      -Ddocs=false -Dbin=false -Dtests=false
    meson install -C build
  )
  mark "fribidi-$FRIBIDI_VERSION"
fi

if ! built "harfbuzz-$HARFBUZZ_VERSION"; then
  fetch "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz" "$HARFBUZZ_SHA256" "harfbuzz-$HARFBUZZ_VERSION.tar.xz"
  unpack "harfbuzz-$HARFBUZZ_VERSION.tar.xz" harfbuzz
  (
    cd "$src/harfbuzz"
    # Only the shaping library, with FreeType font functions.
    meson setup build "${meson_common[@]}" -Ddefault_library=static \
      --auto-features=disabled \
      -Dfreetype=enabled \
      -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dsubset=disabled \
      -Dtests=disabled -Dutilities=disabled -Ddocs=disabled -Dintrospection=disabled
    meson install -C build
  )
  mark "harfbuzz-$HARFBUZZ_VERSION"
fi

# --- FFmpeg ---------------------------------------------------------------
if ! built "ffmpeg-$FFMPEG_VERSION"; then
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" "ffmpeg-$FFMPEG_VERSION.tar.xz"
  unpack "ffmpeg-$FFMPEG_VERSION.tar.xz" ffmpeg
  (
    cd "$src/ffmpeg"
    # Nothing is picked up by accident: every external library is named.
    # Secure Transport for TLS (no OpenSSL to bundle), VideoToolbox for
    # hardware decoding. No GPL or non-free parts. iconv is not in libSystem
    # on macOS but in /usr/lib/libiconv.2.dylib, and configure's check
    # passes without adding it, so libavcodec failed to link.
    ./configure \
      --prefix="$stage" \
      --install-name-dir='@rpath' \
      --enable-shared --disable-static --enable-pic \
      --disable-programs --disable-doc --disable-debug \
      --disable-autodetect \
      --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
      --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET $LDFLAGS" \
      --extra-libs=-liconv \
      --enable-securetransport \
      --enable-videotoolbox --enable-audiotoolbox \
      --enable-zlib --enable-iconv \
      --disable-indevs --disable-outdevs \
      --disable-encoders --enable-encoder=png,mjpeg
    # configure turns a feature off quietly when its check fails; without
    # TLS no channel plays, so make that an error.
    for feature in SECURETRANSPORT VIDEOTOOLBOX AUDIOTOOLBOX ZLIB ICONV; do
      if ! grep -q "^#define CONFIG_$feature 1" config.h; then
        echo "FFmpeg configure disabled $feature; see $src/ffmpeg/ffbuild/config.log" >&2
        exit 1
      fi
    done
    make -j"$jobs"
    make install
  )
  mark "ffmpeg-$FFMPEG_VERSION"
fi

# --- libplacebo -----------------------------------------------------------
if ! built "libplacebo-$LIBPLACEBO_COMMIT"; then
  if [[ -d "$src/libplacebo/.git" && "$(git -C "$src/libplacebo" rev-parse HEAD)" != "$LIBPLACEBO_COMMIT" ]]; then
    rm -rf "$src/libplacebo"
  fi
  if [[ ! -d "$src/libplacebo/.git" ]]; then
    git clone --quiet --recursive --depth 1 --branch "$LIBPLACEBO_TAG" \
      https://code.videolan.org/videolan/libplacebo.git "$src/libplacebo"
  fi
  actual="$(git -C "$src/libplacebo" rev-parse HEAD)"
  if [[ "$actual" != "$LIBPLACEBO_COMMIT" ]]; then
    echo "libplacebo $LIBPLACEBO_TAG is $actual, expected $LIBPLACEBO_COMMIT." >&2
    exit 1
  fi
  (
    cd "$src/libplacebo"
    rm -rf build
    meson setup build "${meson_common[@]}" -Ddefault_library=shared \
      -Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled \
      -Dshaderc=disabled -Dglslang=disabled -Dlcms=disabled \
      -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled \
      -Ddemos=false -Dtests=false
    meson install -C build
  )
  mark "libplacebo-$LIBPLACEBO_COMMIT"
fi

# --- libass ---------------------------------------------------------------
if ! built "libass-$LIBASS_VERSION"; then
  fetch "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz" "$LIBASS_SHA256" "libass-$LIBASS_VERSION.tar.xz"
  unpack "libass-$LIBASS_VERSION.tar.xz" libass
  (
    cd "$src/libass"
    # Fonts come from Core Text (configure fails if no system font provider
    # is found). Only static FreeType, FriBidi and HarfBuzz are in the stage,
    # so they are linked in; HarfBuzz is C++, hence libc++.
    LIBS="-lc++" ./configure --prefix="$stage" --enable-shared --disable-static \
      --disable-fontconfig --disable-libunibreak
    make -j"$jobs"
    make install
  )
  mark "libass-$LIBASS_VERSION"
fi

# --- mpv ------------------------------------------------------------------
if ! built "mpv-$MPV_VERSION"; then
  fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" "$MPV_SHA256" "mpv-$MPV_VERSION.tar.gz"
  unpack "mpv-$MPV_VERSION.tar.gz" mpv
  (
    cd "$src/mpv"
    # Only libmpv with the render API is used (media_kit_video draws through
    # OpenGL), so mpv's own windowing, scripting and players are left out.
    # videotoolbox-gl (zero-copy hardware decoding into GL textures) needs
    # gl-cocoa, which needs cocoa, and in mpv 0.42 cocoa needs the Swift
    # parts (osdep/mac/app_bridge.m and player/clipboard/clipboard-mac.m
    # include the generated osdep/mac/swift.h). Swift is built for the same
    # target as everything else and sees this build's headers. cocoa-cb
    # (mpv's own libmpv view), the media keys / Now Playing hook and the
    # Touch Bar stay off: media_kit has its own view, and ZipTop should not
    # take over the system's media controls. Auto features are off so the
    # build never depends on whatever happens to be installed. Option names
    # are from mpv 0.42's meson.options.
    meson setup build "${meson_common[@]}" -Ddefault_library=shared \
      --auto-features=disabled \
      -Dlibmpv=true -Dcplayer=false -Dtests=false \
      -Dgl=enabled -Dplain-gl=enabled \
      -Dcocoa=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled \
      -Dswift-build=enabled \
      -Dswift-flags="-target arm64-apple-macosx$MACOSX_DEPLOYMENT_TARGET -Xcc -I$stage/include" \
      -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled -Dmacos-touchbar=disabled \
      -Dcoreaudio=enabled \
      -Diconv=enabled -Dzlib=enabled
    meson install -C build
  )
  mark "mpv-$MPV_VERSION"
fi

# Only what linking and running need.
rm -rf "$stage/share" "$stage/bin" "$stage/lib"/*.a "$stage/lib"/*.la

# Install names and references go through @rpath, whatever meson, libtool or
# FFmpeg's make wrote; each library looks next to itself.
dylibs=()
for lib in "$stage"/lib/*.dylib; do
  [[ -L "$lib" ]] || dylibs+=("$lib")
done
for lib in "${dylibs[@]}"; do
  id="$(otool -D "$lib" | sed -n 2p)"
  install_name_tool -id "@rpath/${id##*/}" "$lib"
  while read -r dep; do
    name="${dep##*/}"
    if [[ "$dep" != "@rpath/$name" && -e "$stage/lib/$name" ]]; then
      install_name_tool -change "$dep" "@rpath/$name" "$lib"
    fi
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
  while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$lib"
  done < <(otool -l "$lib" | awk '$1 == "cmd" && $2 == "LC_RPATH" {r = 1} r && $1 == "path" {print $2; r = 0}')
  install_name_tool -add_rpath @loader_path "$lib"
  # install_name_tool invalidates the linker's ad-hoc signature, without
  # which arm64 macOS refuses to load the library.
  codesign --force --sign - "$lib"
done

# Nothing may point outside the bundle except the system's own libraries:
# not Homebrew, not /usr/local, not this build folder.
bad=0
for lib in "${dylibs[@]}"; do
  name="${lib##*/}"
  while read -r dep; do
    case "$dep" in
      @rpath/*)
        if [[ ! -e "$stage/lib/${dep#@rpath/}" ]]; then
          echo "$name: $dep is not in the build" >&2
          bad=1
        fi
        ;;
      /usr/lib/* | /System/Library/*) ;;
      *)
        echo "$name: references $dep" >&2
        bad=1
        ;;
    esac
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
  while read -r rpath; do
    if [[ "$rpath" != @loader_path* ]]; then
      echo "$name: has LC_RPATH $rpath" >&2
      bad=1
    fi
  done < <(otool -l "$lib" | awk '$1 == "cmd" && $2 == "LC_RPATH" {r = 1} r && $1 == "path" {print $2; r = 0}')
  if [[ "$(lipo -archs "$lib")" != arm64 ]]; then
    echo "$name: is $(lipo -archs "$lib"), not arm64 only" >&2
    bad=1
  fi
  minos="$(otool -l "$lib" | awk '$1 == "minos" {print $2; exit}')"
  if [[ "$minos" != "$MACOSX_DEPLOYMENT_TARGET" ]]; then
    echo "$name: targets macOS ${minos:-unknown}, not $MACOSX_DEPLOYMENT_TARGET" >&2
    bad=1
  fi
done
if ((bad)); then
  echo "The libraries in $stage/lib are not self-contained; see above." >&2
  exit 1
fi

# The pkg-config files name the folder they were installed to.
sed -i '' "s|$stage|$prefix|g" "$stage"/lib/pkgconfig/*.pc
rm -f "$stage"/.built-*
mv "$stage" "$prefix"
echo "Built $prefix/lib/libmpv.2.dylib"
