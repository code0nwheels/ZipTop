#!/usr/bin/env bash
# Builds the libmpv that ZipTop ships on Linux.
#
# Distributions package libmpv older than 0.42 (Ubuntu 24.04 has 0.37), and
# older mpv/FFmpeg crash on the backend's live DASH manifests; see
# lib/player/mpv_player.dart (mpvPlaysDash). This is the Linux counterpart of
# the pinned libmpv download in windows/CMakeLists.txt.
#
# Every source is pinned by SHA-256 (or commit, for libplacebo, which needs
# its git submodules). FFmpeg, libplacebo, libass, libdrm and
# libdisplay-info are built as shared libraries next to libmpv.so.2, each
# with RUNPATH=$ORIGIN so they find one another. TLS uses the system's libssl.so.3, which is not bundled, so the
# system's certificate store is used.
#
# Output: linux/third_party/libmpv/<ZIPTOP_LIBMPV_TAG>/{lib,include}
# linux/CMakeLists.txt reads ZIPTOP_LIBMPV_TAG from this file, so bump it
# whenever a pin or a build option changes.
#
# Build dependencies (Ubuntu 22.04 names, as in CI):
#   build-essential nasm git curl python3-venv pkg-config patchelf hwdata
#   libfreetype-dev libfribidi-dev libharfbuzz-dev libfontconfig-dev
#   libva-dev libdrm-dev libpulse-dev libasound2-dev
#   libegl-dev libgl-dev libx11-dev libxext-dev libxpresent-dev
#   libxrandr-dev libxss-dev libxkbcommon-dev libxv-dev zlib1g-dev libssl-dev
# meson and ninja come from pip (22.04's meson is too old for mpv 0.42).
#
# Usage: linux/third_party/build_libmpv.sh   (does nothing if already built)
set -euo pipefail

ZIPTOP_LIBMPV_TAG=mpv-0.42.0-ffmpeg-8.1.3-1

LIBDRM_VERSION=2.4.134
LIBDRM_SHA256=ac5e74d157830eb8bee44c6a6bf3ad49774ef0dd2a72bdad74a8f20308b52a95
LIBDISPLAY_INFO_VERSION=0.3.0
LIBDISPLAY_INFO_SHA256=6ae77cd937f9cf7d1321d35c116062c4911e8447010a6a713ac4286f7a9d5987

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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/libmpv"
prefix="$root/$ZIPTOP_LIBMPV_TAG"
src="$root/src"
jobs="$(nproc)"

if [[ -f "$prefix/lib/libmpv.so.2" ]]; then
  echo "libmpv already built in $prefix"
  exit 0
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
  if ! echo "$sha  $file" | sha256sum --check --status; then
    echo "$file does not match the pinned SHA-256. Delete it to download again." >&2
    exit 1
  fi
}

unpack() { # file dir
  rm -rf "$src/$2"
  mkdir -p "$src/$2"
  tar -xf "$src/$1" -C "$src/$2" --strip-components=1
}

export PKG_CONFIG_PATH="$stage/lib/pkgconfig"
# The libraries find one another through RUNPATH=$ORIGIN, set with patchelf
# at the end (a literal $ORIGIN does not survive meson and make).
export LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
meson_common=(--prefix "$stage" --libdir lib --buildtype release -Ddefault_library=shared)

# --- libdrm ---------------------------------------------------------------
# mpv 0.42 needs libdrm 2.4.114 or newer for VA-API through the DRM render
# node (hardware decoding on X11 and Wayland alike); Ubuntu 22.04 has
# 2.4.113. Only the core library: the GPU-specific parts stay the system's.
if ! built "libdrm-$LIBDRM_VERSION"; then
  fetch "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VERSION.tar.xz" "$LIBDRM_SHA256" "libdrm-$LIBDRM_VERSION.tar.xz"
  unpack "libdrm-$LIBDRM_VERSION.tar.xz" libdrm
  (
    cd "$src/libdrm"
    meson setup build "${meson_common[@]}" --auto-features=disabled -Dtests=false -Dudev=false
    meson install -C build
  )
  mark "libdrm-$LIBDRM_VERSION"
fi

# --- libdisplay-info -------------------------------------------------------
# Also required by mpv's DRM support, and also newer than Ubuntu 22.04 has.
if ! built "libdisplay-info-$LIBDISPLAY_INFO_VERSION"; then
  fetch "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/$LIBDISPLAY_INFO_VERSION/downloads/libdisplay-info-$LIBDISPLAY_INFO_VERSION.tar.xz" "$LIBDISPLAY_INFO_SHA256" "libdisplay-info-$LIBDISPLAY_INFO_VERSION.tar.xz"
  unpack "libdisplay-info-$LIBDISPLAY_INFO_VERSION.tar.xz" libdisplay-info
  (
    cd "$src/libdisplay-info"
    meson setup build "${meson_common[@]}"
    meson install -C build
  )
  mark "libdisplay-info-$LIBDISPLAY_INFO_VERSION"
fi

# --- FFmpeg ---------------------------------------------------------------
if ! built "ffmpeg-$FFMPEG_VERSION"; then
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" "ffmpeg-$FFMPEG_VERSION.tar.xz"
  unpack "ffmpeg-$FFMPEG_VERSION.tar.xz" ffmpeg
  (
    cd "$src/ffmpeg"
    # Nothing is picked up by accident: every external library is named.
    # OpenSSL 3 needs version3 (LGPLv3); no GPL or non-free parts.
    ./configure \
      --prefix="$stage" \
      --enable-shared --disable-static --enable-pic \
      --disable-programs --disable-doc --disable-debug \
      --disable-autodetect \
      --enable-version3 --enable-openssl \
      --enable-zlib --enable-iconv \
      --enable-vaapi --enable-libdrm \
      --disable-indevs --disable-outdevs \
      --disable-encoders --enable-encoder=png,mjpeg
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
    meson setup build "${meson_common[@]}" \
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
    ./configure --prefix="$stage" --enable-shared --disable-static \
      --enable-fontconfig --disable-libunibreak
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
    # PipeWire systems are reached through their PulseAudio server, so mpv
    # does not need libpipewire, which not every distribution installs.
    # Auto features are off so the build never depends on whatever happens to
    # be installed.
    meson setup build "${meson_common[@]}" \
      --auto-features=disabled \
      -Dlibmpv=true -Dcplayer=false -Dtests=false \
      -Dgl=enabled -Dplain-gl=enabled -Degl=enabled \
      -Dx11=enabled -Degl-x11=enabled -Ddrm=enabled \
      -Dvaapi=enabled -Dvaapi-drm=enabled -Dvaapi-x11=enabled \
      -Dpulse=enabled -Dalsa=enabled \
      -Diconv=enabled -Dzlib=enabled
    meson install -C build
  )
  mark "mpv-$MPV_VERSION"
fi

# Only what linking and running need.
rm -rf "$stage/share" "$stage/bin" "$stage/lib"/*.a "$stage/lib"/*.la "$stage"/.built-*
for lib in "$stage"/lib/*.so.*; do
  [[ -L "$lib" ]] || patchelf --set-rpath '$ORIGIN' "$lib"
done
# The pkg-config files name the folder they were installed to.
sed -i "s|$stage|$prefix|g" "$stage"/lib/pkgconfig/*.pc
mv "$stage" "$prefix"
echo "Built $prefix/lib/libmpv.so.2"
