# ZipTop

The ZipStreams desktop client for Windows, Linux and macOS: live TV, TV
guide, multiview and DVR. Built with Flutter. Live TV plays through mpv
(libmpv via media_kit) on Windows and Linux and through AVPlayer on macOS, so
it can go to an Apple TV over AirPlay. Recordings play through mpv everywhere.
Any of them can cast the channel to a Chromecast or Google TV.

It is the desktop counterpart of the Android TV app and talks to the same
backend with the same device-code pairing.

**Just want to use it?** See [How to install ZipTop](docs/INSTALL.md), a
step-by-step guide for Windows, Mac and Linux. The rest of this page is for
developers.

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

Builds on Debian 13 or newer (CI builds in a Debian 13 container, so the
AppImage runs on glibc 2.41 and later: Debian 13, Ubuntu 25.04, Fedora 42 and
newer). Install Flutter (stable) and the packages listed in the *Install build
dependencies* step of
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

### macOS

> macOS support is new and has not yet been tried on a real Mac. CI builds
> it, checks the bundled libmpv and launches the app, but nobody has watched
> a channel on it yet. Reports welcome.

Apple Silicon only (arm64), macOS 13 or later. Requirements: Xcode,
CocoaPods, Homebrew's `pkgconf` (`brew install pkgconf`) and Flutter (stable). Then:

```
macos/third_party/build_libmpv.sh
flutter pub get
flutter run -d macos
```

Live TV and multiview play through AVPlayer, in the local plugin
`packages/ziptop_avplayer` (Swift, drawn into a Flutter texture), which also
shows the AirPlay menu. AVPlayer can't open the MPEG-TS files recordings are
saved as, so recordings still play through mpv, hence libmpv below.

`build_libmpv.sh` builds mpv 0.42 with FFmpeg, libplacebo and libass from
pinned, checksummed sources into `macos/third_party/libmpv/` (several
minutes, once). Every build then puts it into the app in place of
media_kit's own, older Mpv.framework. That is done by a "Swap in libmpv 0.42"
build step, which `macos/Podfile` adds after CocoaPods' own steps. Without
`build_libmpv.sh` the step only warns, and DASH channels are refused.

The project uses CocoaPods, not Swift Package Manager (media_kit's macOS
plugins only support CocoaPods; see `flutter: config:` in `pubspec.yaml`).
The first `pod install`, which `flutter run` does by itself, adds its build
steps and the libmpv step to `macos/Runner.xcodeproj`. Commit that change.

#### Installing an unsigned build

ZipTop is not signed with an Apple Developer ID or notarized, so macOS
blocks it the first time:

1. Open the DMG and drag ZipTop into Applications.
2. Open ZipTop. macOS says it can't check it for malicious software. Click
   **Done**.
3. Open **System Settings > Privacy & Security**, scroll down to
   "ZipTop was blocked…" and click **Open Anyway**, then confirm.

This is needed once. Updates installed from inside ZipTop aren't blocked
again. macOS may ask whether ZipTop may use the keychain item holding its
pairing token. Click **Always Allow**. Release builds are all signed with the
same self-signed certificate, so later updates don't ask again (builds from
before that certificate was used ask once more, on the first update that
carries it).

Build-time options, passed as `--dart-define=NAME=value`:

| Name | Default | Purpose |
|---|---|---|
| `BASE_URL` | `https://al.zipstreams.live/` | Primary API host |
| `FALLBACK_URL` | `https://al.zipstreams.net/` | Used when the primary can't be reached |
| `MEDIA_USER_AGENT` | `ZipStreams-AndroidTV/2.0` | Sent on stream requests |

Debug builds also read two environment variables, for testing from scripts:
`ZIPTOP_START_VIEW=guide|multiview|recordings` and `ZIPTOP_DEBUG_RECORD=<seconds>`.

## Versions and releases

Versions come from git tags, not from `pubspec.yaml`.

- **Every merge to `main` is a release.** CI takes the latest `v*` tag and
  bumps it according to the merged pull request's label:

  | Label | Example |
  |---|---|
  | none (or a direct push) | `v1.2.3` → `1.2.4` |
  | `release:minor` | `v1.2.3` → `1.3.0` |
  | `release:major` | `v1.2.3` → `2.0.0` |
  | `release:skip` | no release, only a test build |

  It builds that version and publishes GitHub Release `v1.2.4` with
  `ZipTop-Setup-1.2.4.exe`, `ZipTop-1.2.4-x86_64.AppImage`,
  `ZipTop-1.2.4-macos-arm64.dmg` and notes generated from the merged pull
  requests. Publishing creates the tag. A separate job then uploads the
  three builds to the ZipStreams server (`tool/upload_to_webapp.sh`, with
  the `ZIPSTREAMS_URL` and `ZIPSTREAMS_UPLOAD_TOKEN` repository secrets);
  that is where installed copies find updates.
  Builds run one at a time and are never cancelled. If several merges land
  while one is building, only the newest waits, and its release includes
  the others.
- **Test builds:** a `release:skip` merge builds all three, numbered as the next
  patch with the CI run number, e.g. `1.2.4-dev.57`. They are attached to
  the run under *Artifacts* for 30 days and are never offered as updates.
- **A specific version:** push a tag, or run *Build and release* from the
  Actions tab on `main` and type the version:

  ```
  git tag v1.3.0
  git push origin v1.3.0
  ```

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

On macOS:

```
tool/build_dmg.sh --version 1.3.0
```

The DMG lands in `build/dmg/ZipTop-<version>-macos-arm64.dmg`. The script
builds libmpv if needed, makes sure it is in the app's `Mpv.framework`, checks
that nothing in the app loads a library from outside it or macOS, signs it
and packs the DMG. Locally it is signed ad hoc. CI signs with ZipTop's
self-signed certificate, from the `MACOS_SIGNING_CERT_P12` (base64 .p12) and
`MACOS_SIGNING_CERT_PASSWORD` repository secrets; a release fails without
them. `tool/make_macos_signing_cert.sh` makes the certificate. It is made once
and kept: a new one means every Mac asks for the keychain again. CI also
loads the bundled libmpv with
`tool/mpv_probe.dart` and launches the app from the DMG for 20 seconds,
saving a screenshot with the run's artifacts.

### Updates

Installed copies ask the ZipStreams server which release is published
(`GET api/ziptop/version` on the API host, with the pairing token) at
start-up, at most every six hours, and from Settings. Only a signed-in
copy asks: the server serves releases to signed-in viewers only. When the
published version is newer than the running one and has this platform's
build, ZipTop offers it. The build is downloaded from the same host with
the same token and checked against the SHA-256 the server gave; a
mismatch is thrown away. On Windows it
downloads `ZipTop-Setup-*.exe` and runs it silently (`/VERYSILENT`, no
wizard), which closes ZipTop, installs over it and starts it again. On Linux it downloads
`ZipTop-*-x86_64.AppImage` next to the running AppImage, renames it over it
and restarts; a Linux build not run as an AppImage, or one in a folder it
can't write to, is not offered updates. On macOS it downloads
`ZipTop-*-macos-arm64.dmg`, copies the app out of it beside the running
one, swaps the two and restarts. A copy run from the DMG itself, one macOS
has not let out of quarantine yet, or one in a folder it can't write to,
is not offered updates. The server only ever holds releases, never test
builds; a test build is offered the release it leads up to.

Copies older than this change still ask GitHub's latest release, which CI
keeps publishing, so they update onto a version that asks the server.

## Where things are kept

- Pairing token: Windows Credential Manager; on Linux the Secret Service
  keyring; on macOS the login keychain.

## Signing in

Sign-in is the backend's device-code pairing (`POST api/auth/tv/generate-code`,
then `GET api/auth/tv/check-code/<code>` every 2.5 s), shared with the Android
TV app. ZipTop adds to it:

- The code request describes this computer (`client: ziptop`, its host name,
  OS and version), so the approval page asks "Sign in ZipTop on
  DESKTOP-ABC?" and the account page can list it.
- **Sign in with your browser** opens `<host>/link?code=<code>` in the default
  browser (`rundll32 url.dll` on Windows, `open` on macOS, `xdg-open` on
  Linux; no plugin). The code and QR code stay for signing in from a phone.
  Once approved, ZipTop raises its window over the browser.
- At start-up, a signed-in copy sends `PUT api/auth/device` with its
  name and version. A token from before the server kept a device list comes
  back replaced by one that puts this computer on it.
- Sign out sends `POST api/auth/logout` with the token before forgetting it,
  which signs the device out on the server too. A device removed from the
  account page gets a 401 on its next request and returns to sign-in.
- A 403 with `not_entitled` (the plan doesn't include the channel) shows
  "Your plan doesn't include this channel" with **See plans**. Settings shows
  the plan, season plans from the catalogue's `viewer.plan_status` and the
  email, with **Manage account** and, near expiry, **Renew**, which open the
  website.
- Settings and the recordings list: `%APPDATA%\com.zipstreams\ziptop\` on
  Windows, `~/.local/share/com.zipstreams.ziptop/` on Linux,
  `~/Library/Application Support/com.zipstreams.ziptop/` on macOS. The
  folder names come from CompanyName and ProductName in
  `windows/runner/Runner.rc`, from `APPLICATION_ID` in
  `linux/CMakeLists.txt` and from `PRODUCT_BUNDLE_IDENTIFIER` in
  `macos/Runner/Configs/AppInfo.xcconfig`; changing them orphans existing
  users' data.
- Recordings: `Videos\ZipTop` by default (on Linux, the XDG Videos folder;
  on macOS, `~/Movies/ZipTop`), changeable in the app.
- Start at sign-in: the current user's Run key on Windows,
  `~/.config/autostart/ziptop.desktop` on Linux,
  `~/Library/LaunchAgents/com.zipstreams.ziptop.plist` on macOS.

## Layout

```
lib/core        API client, models, playback session, stores
lib/player      mpv wrapper
lib/dvr         capture, scheduling and the recordings store
lib/features    login, shell, live, guide, multiview, recordings, settings, update
installer       Inno Setup script
linux           GTK runner, libmpv build script, AppImage files
macos           Cocoa runner, libmpv build and install scripts
tool            build and version scripts
```
