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
| `UPDATE_REPO` | `code0nwheels/ZipTop` | GitHub repository whose releases are offered as updates |

Debug builds also read two environment variables, for testing from scripts:
`ZIPTOP_START_VIEW=multiview` and `ZIPTOP_DEBUG_RECORD=<seconds>`.

## Versions and releases

Versions come from git tags, not from `pubspec.yaml`.

- **Test builds:** every merge to `main` builds an installer numbered as the
  next patch after the latest release, e.g. `1.2.4-dev.57` (57 is the CI run
  number). It is attached to the run under *Artifacts* for 30 days and is
  never offered as an update.
- **Releases:** either push a tag, or run *Build Windows installer* from the
  Actions tab on `main` and type the version:

  ```
  git tag v1.3.0
  git push origin v1.3.0
  ```

  CI builds `1.3.0`, then publishes a GitHub Release `v1.3.0` with
  `ZipTop-Setup-1.3.0.exe` and notes generated from the merged pull requests.
  A version that is already released is refused.

`pubspec.yaml`'s version is only the starting number before the first tag,
and the default for local builds.

To build locally (needs Inno Setup 6):

```
powershell -File tool\build_installer.ps1 -Version 1.3.0
```

The installer lands in `installer/output/ZipTop-Setup-<version>.exe`. It is
per-user and needs no administrator rights. `tool/resolve_version.ps1` is
the version logic CI uses.

### Updates

Installed copies ask GitHub for the latest release
(`api.github.com/repos/<UPDATE_REPO>/releases/latest`) at start-up, at most
every six hours, and from Settings. When its tag is newer than the running
version and it has a `ZipTop-Setup-*.exe` asset, ZipTop offers it,
downloads the installer and runs it. Drafts and pre-releases are skipped; a
test build is offered the release it leads up to.

GitHub only answers this without a sign-in for **public** repositories. While
the repository is private, update checks find nothing.

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
