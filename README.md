# ZipTop

The ZipStreams desktop client for Windows: live TV, TV guide, multiview and
DVR. Built with Flutter, playing through mpv (libmpv via media_kit).

It is the desktop counterpart of the Android TV app and talks to the same
backend with the same device-code pairing.

## Building

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

Build-time options, passed as `--dart-define=NAME=value`:

| Name | Default | Purpose |
|---|---|---|
| `BASE_URL` | `https://al.zipstreams.live/` | Primary API host |
| `FALLBACK_URL` | `https://al.zipstreams.net/` | Used when the primary can't be reached |
| `MEDIA_USER_AGENT` | `ZipStreams-AndroidTV/2.0` | Sent on stream requests |
| `UPDATE_PATH` | `desktop/version` | Where the app asks for updates |

Debug builds also read two environment variables, for testing from scripts:
`ZIPTOP_START_VIEW=multiview` and `ZIPTOP_DEBUG_RECORD=<seconds>`.

## Releasing

```
powershell -File tool\build_installer.ps1
```

This makes the release build, bundles the Visual C++ runtime and compiles
`installer/ziptop.iss` with Inno Setup 6 into
`installer/output/ZipTop-Setup-<version>.exe`. The version comes from
`pubspec.yaml`. The installer is per-user and needs no administrator rights.

### Updates

ZipTop asks `GET <api host>/desktop/version` and expects the same shape the
Android app gets from `atv/version`:

```json
{ "version": "1.2.0", "download_url": "/downloads/ZipTop-Setup-1.2.0.exe", "available": true }
```

`download_url` may be absolute or relative to the API host. When the version
is newer than the running one, ZipTop offers it, downloads the installer and
runs it. Until the backend serves this endpoint, update checks find nothing.

## Where things are kept

- Pairing token: Windows Credential Manager.
- Settings and the recordings list: `%APPDATA%\com.zipstreams\ziptop\`. The
  folder name comes from the executable's CompanyName and ProductName in
  `windows/runner/Runner.rc`; changing them orphans existing users' data.
- Recordings: `Videos\ZipTop` by default, changeable in the app.

## Layout

```
lib/core        API client, models, playback session, stores
lib/player      mpv wrapper
lib/dvr         capture, scheduling and the recordings store
lib/features    login, shell, live, guide, multiview, recordings, settings, update
installer       Inno Setup script
tool            build script
```
