# ZipTop

The ZipStreams desktop client for Windows and Linux: live TV, TV guide,
multiview and DVR. Built with Flutter, playing through mpv (libmpv via media_kit).

It is the desktop counterpart of the Android TV app and talks to the same
backend with the same device-code pairing.

## Building

### Windows

Requirements: Flutter (stable), Visual Studio 2022 with "Desktop development
with C++", and Windows Developer Mode (Flutter needs symlinks for plugins).

```
flutter pub get
flutter run -d windows
flutter test
```

The first build downloads a pinned libmpv (mpv 0.42) into
`windows/third_party/` and checks its SHA-256; see `windows/CMakeLists.txt`
for why media_kit's bundled build is replaced.

### Linux

Builds on Ubuntu 22.04 or newer (22.04 is what CI uses, so the AppImage runs
on glibc 2.35 and later). Install Flutter (stable) and the packages listed in
the *Install build dependencies* step of
`.github/workflows/build-installer.yml`, then:

```
linux/third_party/build_libmpv.sh
flutter pub get
flutter run -d linux
```

`build_libmpv.sh` builds mpv 0.42 with FFmpeg, libplacebo, libass and libdrm
from pinned, checksummed sources into `linux/third_party/libmpv/` (several
minutes, once). Distributions ship older libmpv, which crashes on the
backend's DASH streams. Without it the build falls back to the system
`libmpv-dev` with a warning, and DASH channels are refused.

To run the AppImage, a desktop needs GTK 3, PulseAudio or PipeWire's Pulse
server, VA-API (`libva`), OpenSSL 3, and a Secret Service keyring (GNOME
Keyring or KWallet) for the pairing token. The tray icon needs a
StatusNotifier host; on stock GNOME (without the AppIndicator extension)
ZipTop minimizes instead of hiding to the tray.

Build-time options, passed as `--dart-define=NAME=value`:

| Name | Default | Purpose |
|---|---|---|
| `BASE_URL` | `https://al.zipstreams.live/` | Primary API host |
| `FALLBACK_URL` | `https://al.zipstreams.net/` | Used when the primary can't be reached |
| `MEDIA_USER_AGENT` | `ZipStreams-AndroidTV/2.0` | Sent on stream requests |
| `UPDATE_REPO` | `code0nwheels/ZipTop` | GitHub repository whose releases are offered as updates |

Debug builds also read two environment variables, for testing from scripts:
`ZIPTOP_START_VIEW=multiview` and `ZIPTOP_DEBUG_RECORD=<seconds>`.

## Versions and releases

Versions come from git tags, not from `pubspec.yaml`.

- **Test builds:** every merge to `main` builds a Windows installer and a
  Linux AppImage numbered as the next patch after the latest release, e.g.
  `1.2.4-dev.57` (57 is the CI run number). They are attached to the run
  under *Artifacts* for 30 days and are never offered as updates.
- **Releases:** either push a tag, or run *Build and release* from the
  Actions tab on `main` and type the version:

  ```
  git tag v1.3.0
  git push origin v1.3.0
  ```

  CI builds `1.3.0`, then publishes a GitHub Release `v1.3.0` with
  `ZipTop-Setup-1.3.0.exe`, `ZipTop-1.3.0-x86_64.AppImage` and notes
  generated from the merged pull requests.
  A version that is already released is refused.

`pubspec.yaml`'s version is only the starting number before the first tag,
and the default for local builds.

To build locally on Windows (needs Inno Setup 6):

```
powershell -File tool\build_installer.ps1 -Version 1.3.0
```

The installer lands in `installer/output/ZipTop-Setup-<version>.exe`. It is
per-user and needs no administrator rights. `tool/resolve_version.ps1` is
the version logic CI uses.

On Linux:

```
tool/build_appimage.sh --version 1.3.0
```

The AppImage lands in `build/appimage/ZipTop-<version>-x86_64.AppImage`. The
script builds libmpv if needed, bundles the libraries a desktop can't be
relied on to have (tray, keyring, mpv's), and packs it with a pinned
appimagetool and AppImage runtime.

### Updates

Installed copies ask GitHub for the latest release
(`api.github.com/repos/<UPDATE_REPO>/releases/latest`) at start-up, at most
every six hours, and from Settings. When its tag is newer than the running
version and it has this platform's asset, ZipTop offers it. On Windows it
downloads `ZipTop-Setup-*.exe` and runs it. On Linux it downloads
`ZipTop-*-x86_64.AppImage` next to the running AppImage, renames it over it
and restarts; a Linux build not run as an AppImage, or one in a folder it
can't write to, is not offered updates. Drafts and pre-releases are skipped; a
test build is offered the release it leads up to.

GitHub only answers this without a sign-in for **public** repositories. While
the repository is private, update checks find nothing.

## Where things are kept

- Pairing token: Windows Credential Manager; on Linux the Secret Service
  keyring.
- Settings and the recordings list: `%APPDATA%\com.zipstreams\ziptop\` on
  Windows, `~/.local/share/com.zipstreams.ziptop/` on Linux. The folder
  names come from CompanyName and ProductName in `windows/runner/Runner.rc`
  and from `APPLICATION_ID` in `linux/CMakeLists.txt`; changing them
  orphans existing users' data.
- Recordings: `Videos\ZipTop` by default (on Linux, the XDG Videos folder),
  changeable in the app.
- Start at sign-in: the current user's Run key on Windows,
  `~/.config/autostart/ziptop.desktop` on Linux.

## Layout

```
lib/core        API client, models, playback session, stores
lib/player      mpv wrapper
lib/dvr         capture, scheduling and the recordings store
lib/features    login, shell, live, guide, multiview, recordings, settings, update
installer       Inno Setup script
linux           GTK runner, libmpv build script, AppImage files
tool            build and version scripts
```
