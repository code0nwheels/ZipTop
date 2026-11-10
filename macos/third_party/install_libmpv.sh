#!/usr/bin/env bash
# Puts the libmpv 0.42 built by macos/third_party/build_libmpv.sh into a built
# ZipTop.app, in place of the older mpv that media_kit_libs_macos_video
# bundles (which crashes on the backend's DASH manifests; see
# lib/player/mpv_player.dart, mpvPlaysDash).
#
# media_kit_video links Mpv.framework and Dart opens Mpv.framework/Mpv, so
# libmpv.2.dylib replaces the framework's binary (the libmpv ABI is stable)
# and its FFmpeg, libplacebo and libass dylibs go into Contents/Frameworks.
# The frameworks the old Mpv needed (media_kit's FFmpeg and the rest) are
# then removed, once otool shows that nothing in the bundle links them.
# Changed binaries are re-signed ad hoc (the project's CODE_SIGN_IDENTITY is
# "-"); tool/build_dmg.sh signs the whole app afterwards.
#
# It runs in two places:
# - tool/build_dmg.sh, after `flutter build macos`. A missing libmpv build is
#   an error there.
# - The "Swap in libmpv 0.42" Run Script step that macos/Podfile adds after
#   "[CP] Embed Pods Frameworks", with --optional, so `flutter run -d macos`
#   gets mpv 0.42 too. Without a libmpv build that only warns, and the app
#   keeps media_kit's mpv (DASH channels are then refused).
# It must be an Xcode step after the embed phase, not before, as that phase
# copies media_kit's Mpv back over it. Every incremental build runs it again
# on an app it may already have swapped, so each part is skipped when it is
# already done.
#
# Usage: macos/third_party/install_libmpv.sh [--optional] path/to/ZipTop.app
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
optional=0
if [[ "${1:-}" == --optional ]]; then
  optional=1
  shift
fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--optional] path/to/ZipTop.app" >&2
  exit 2
fi
app="${1%/}"

# Same tag, and so the same folder, as the build script.
tag="$(sed -n 's/^ZIPTOP_LIBMPV_TAG=//p' "$here/build_libmpv.sh")"
lib="$here/libmpv/$tag/lib"
if [[ -z "$tag" || ! -f "$lib/libmpv.2.dylib" ]]; then
  if ((optional)); then
    echo "warning: libmpv 0.42 is not built (run macos/third_party/build_libmpv.sh); DASH channels will be refused"
    exit 0
  fi
  echo "No libmpv in $lib. Run macos/third_party/build_libmpv.sh first." >&2
  exit 1
fi

fw="$app/Contents/Frameworks"
mpv="$fw/Mpv.framework/Versions/A/Mpv"
if [[ ! -f "$mpv" || -L "$mpv" ]]; then
  echo "$mpv not found; is $app a ZipTop.app built with media_kit_libs_macos_video?" >&2
  exit 1
fi

# What the last swap left, for the next run on the same app: the signed Mpv
# it installed, and the media_kit frameworks the replaced Mpv needed.
state="$here/libmpv/$tag/installed"
mkdir -p "$state"

# Libraries a Mach-O file links, without its own install name.
deps() {
  local id
  id="$(otool -D "$1" | sed -n 2p)"
  otool -L "$1" | awk -v id="$id" '/^\t/ && $1 != id {print $1}'
}

# The framework a reference points into ("Avcodec.framework"), if any.
framework_of() {
  case "$1" in
    /System/* | /usr/lib/*) return 1 ;;
  esac
  [[ "$1" =~ ([^/]+\.framework)/(.+)$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

machos() { # every Mach-O file in the app
  find "$app" -type f -print | while IFS= read -r f; do
    case "$(file -b "$f")" in
      Mach-O*) echo "$f" ;;
    esac
  done
}

has() { # list word: is word a line of list?
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

# --- What media_kit's Mpv brought ----------------------------------------
# Every framework the current Mpv binary needs, directly or through another
# one. Once it is ours that is none, so the list from the swap that replaced
# media_kit's is added (the embed phase may have copied them back).
candidates=""
if [[ -f "$state/frameworks" ]]; then
  candidates="$(cat "$state/frameworks")"
fi
queue="$mpv"
while [[ -n "$queue" ]]; do
  bin="${queue%%$'\n'*}"
  if [[ "$queue" == *$'\n'* ]]; then queue="${queue#*$'\n'}"; else queue=""; fi
  while IFS= read -r dep; do
    name="$(framework_of "$dep")" || continue
    [[ "$name" != Mpv.framework && -d "$fw/$name" ]] || continue
    has "$candidates" "$name" && continue
    candidates="${candidates:+$candidates$'\n'}$name"
    target="$fw/$name/${dep#*"$name"/}"
    if [[ -f "$target" ]]; then
      queue="${queue:+$queue$'\n'}$target"
    fi
  done < <(deps "$bin")
done

# --- Swap in libmpv 0.42 --------------------------------------------------
installed=()
if [[ -f "$state/Mpv" ]] && cmp -s "$state/Mpv" "$mpv"; then
  echo "Mpv.framework already has libmpv ($tag)"
  swapped=0
else
  cp -f "$lib/libmpv.2.dylib" "$mpv"
  install_name_tool -id @rpath/Mpv.framework/Versions/A/Mpv "$mpv"
  # From Mpv.framework/Versions/A, the dylibs beside it are three levels up.
  install_name_tool -add_rpath @loader_path/../../.. "$mpv"
  swapped=1
fi
installed+=("$mpv")

# These are copied unchanged, still signed by build_libmpv.sh.
for f in "$lib"/*.dylib; do
  [[ -L "$f" ]] && continue
  id="$(otool -D "$f" | sed -n 2p)"
  name="${id##*/}"
  [[ "$name" == libmpv.2.dylib ]] && continue
  if ! cmp -s "$f" "$fw/$name"; then
    cp -f "$f" "$fw/$name"
  fi
  installed+=("$fw/$name")
done

# Each installed binary links only the system and what is now in Frameworks.
bad=0
for f in "${installed[@]}"; do
  while IFS= read -r dep; do
    case "$dep" in
      @rpath/*) [[ -e "$fw/${dep#@rpath/}" ]] || { echo "${f#"$app"/}: $dep is not in $fw" >&2; bad=1; } ;;
      /usr/lib/* | /System/Library/*) ;;
      *) echo "${f#"$app"/}: references $dep" >&2; bad=1 ;;
    esac
  done < <(deps "$f")
done
if ((bad)); then
  exit 1
fi

# install_name_tool invalidated the signature, and arm64 macOS loads nothing
# unsigned. The framework is signed as a bundle so its seal stays valid for
# the app's own signing. Keep the signed result to recognise it next time.
if ((swapped)); then
  codesign --force --sign - "$fw/Mpv.framework"
  cp -f "$mpv" "$state/Mpv"
fi
if [[ -n "$candidates" ]]; then
  printf '%s\n' "$candidates" >"$state/frameworks"
fi

# --- Drop what nothing links any more -------------------------------------
# Only frameworks still in the app; any already removed are fine.
present=""
if [[ -n "$candidates" ]]; then
  while IFS= read -r name; do
    if [[ -d "$fw/$name" ]]; then
      present="${present:+$present$'\n'}$name"
    fi
  done <<<"$candidates"
fi

if [[ -n "$present" ]]; then
  # A candidate stays if any Mach-O outside the candidates still being
  # removed links it; repeat until nothing changes, as candidates link one
  # another.
  refs="$(mktemp)"
  trap 'rm -f "$refs"' EXIT
  while IFS= read -r f; do
    owner=""
    case "$f" in
      "$fw"/*.framework/*) owner="${f#"$fw"/}"; owner="${owner%%/*}" ;;
    esac
    while IFS= read -r dep; do
      name="$(framework_of "$dep")" || continue
      printf '%s\t%s\n' "$owner" "$name"
    done < <(deps "$f")
  done < <(machos) >"$refs"

  removable="$present"
  changed=1
  while ((changed)); do
    changed=0
    while IFS=$'\t' read -r owner name; do
      if has "$removable" "$name" && ! { [[ -n "$owner" ]] && has "$removable" "$owner"; }; then
        echo "Keeping $name: ${owner:-the app} links it"
        removable="$(printf '%s\n' "$removable" | grep -vxF "$name" || true)"
        changed=1
      fi
    done <"$refs"
  done

  if [[ -n "$removable" ]]; then
    while IFS= read -r name; do
      echo "Removing $name"
      rm -rf "${fw:?}/$name"
    done <<<"$removable"

    # Nothing left may point at what was removed.
    while IFS= read -r f; do
      while IFS= read -r dep; do
        name="$(framework_of "$dep")" || continue
        if [[ ! -d "$fw/$name" ]] && has "$removable" "$name"; then
          echo "${f#"$app"/} still links the removed $dep" >&2
          bad=1
        fi
      done < <(deps "$f")
    done < <(machos)
    if ((bad)); then
      exit 1
    fi
  fi
fi

echo "Installed libmpv ($tag) into $app"
