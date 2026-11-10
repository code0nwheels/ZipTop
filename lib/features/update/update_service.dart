import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/models/json.dart';
import '../../core/platform/reveal.dart' show ProcessRunner;
import '../../core/stores/settings_store.dart';

/// A newer ZipTop on offer.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.downloadUrl});
  final String version;

  /// Absolute URL of the installer, AppImage or disk image for this platform.
  final String downloadUrl;
}

typedef _Parsed = ({List<int> core, bool preRelease});

_Parsed _parse(String v) {
  final text = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
  final dash = text.indexOf('-');
  final core = dash < 0 ? text : text.substring(0, dash);
  return (
    core: [for (final part in core.split('.')) int.tryParse(part) ?? 0],
    preRelease: dash >= 0,
  );
}

/// True when [remote] is a later version than [local]. Build metadata
/// (`+7`) is ignored. A test build such as `1.2.0-dev.5` comes before the
/// `1.2.0` release, so it is offered that release.
bool isNewerVersion(String remote, String local) {
  final a = _parse(remote);
  final b = _parse(local);
  for (var i = 0; i < a.core.length || i < b.core.length; i++) {
    final x = i < a.core.length ? a.core[i] : 0;
    final y = i < b.core.length ? b.core[i] : 0;
    if (x != y) return x > y;
  }
  return b.preRelease && !a.preRelease;
}

/// The platforms the updater knows how to update.
enum UpdatePlatform { windows, linux, macos }

/// Checks GitHub for a newer published release, downloads this platform's
/// build and hands over to it.
///
/// Releases are made by CI: each one is tagged `v<version>` and carries
/// `ZipTop-Setup-<version>.exe` for Windows,
/// `ZipTop-<version>-x86_64.AppImage` for Linux and
/// `ZipTop-<version>-macos-arm64.dmg` (holding `ZipTop.app`) for Apple
/// Silicon Macs. Drafts and pre-releases are never offered.
///
/// On Windows the installer is downloaded to the temp folder and started. On
/// Linux only the AppImage build can update itself: the new AppImage is
/// downloaded next to the running one (named by the `APPIMAGE` variable its
/// runtime sets), renamed over it and started. On macOS the disk image is
/// downloaded to the temp folder and mounted, and the new `ZipTop.app` is
/// copied in beside the running bundle and swapped with it; a small detached
/// script waits for this process to quit, removes the old bundle and opens
/// the new one. That needs an installed bundle in a folder that can be
/// written to, so a copy run straight from the disk image or translocated by
/// Gatekeeper is never offered an update.
class UpdateService {
  UpdateService({
    required this.settings,
    required this.currentVersion,
    Dio? http,
    this.clock = DateTime.now,
    UpdatePlatform? platform,
    Map<String, String>? environment,
    String? appBundle,
    this.run = Process.run,
  })  : _http = http ?? Dio(),
        platform = platform ?? _hostPlatform(),
        environment = environment ?? Platform.environment,
        _appBundleOverride = appBundle;

  static UpdatePlatform? _hostPlatform() {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    return null;
  }

  /// The GitHub repository whose releases are offered.
  static const repository = String.fromEnvironment(
    'UPDATE_REPO',
    defaultValue: 'code0nwheels/ZipTop',
  );

  static const latestReleaseUrl = 'https://api.github.com/repos/$repository/releases/latest';

  /// Automatic checks happen at most this often (GitHub allows 60 anonymous
  /// requests an hour per address).
  static const autoCheckInterval = Duration(hours: 6);

  static final _installerName = RegExp(r'^ZipTop-Setup-.*\.exe$', caseSensitive: false);
  static final _appImageName = RegExp(r'^ZipTop-.*-x86_64\.AppImage$', caseSensitive: false);
  static final _diskImageName = RegExp(r'^ZipTop-.*-macos-arm64\.dmg$', caseSensitive: false);

  /// Beside the running bundle on macOS: where the new one is copied, and
  /// what the running one is renamed to until the hand-over script removes it.
  static const stagedBundleName = '.ZipTop-update.app';
  static const oldBundleName = '.ZipTop-old.app';

  final SettingsStore settings;
  final String currentVersion;
  final Dio _http;
  final DateTime Function() clock;

  /// The platform being updated, or null when this one can't be.
  final UpdatePlatform? platform;

  /// Where `APPIMAGE` is read from on Linux.
  final Map<String, String> environment;

  /// Runs `hdiutil` and `ditto` on macOS.
  final ProcessRunner run;

  final String? _appBundleOverride;

  /// The running `.app` on macOS: three folders up from
  /// `ZipTop.app/Contents/MacOS/ZipTop`.
  String get _appBundle =>
      _appBundleOverride ?? p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable)));

  /// The running AppImage, or null when this build isn't one.
  String? get _appImage {
    final path = environment['APPIMAGE'];
    return path == null || path.isEmpty ? null : path;
  }

  RegExp? get _assetName => switch (platform) {
        UpdatePlatform.windows => _installerName,
        UpdatePlatform.linux => _appImageName,
        UpdatePlatform.macos => _diskImageName,
        null => null,
      };

  /// Whether this copy can replace itself: always on Windows (the installer
  /// does it); on Linux only as an AppImage whose folder can be written to;
  /// on macOS only as an installed `.app` whose folder can be written to (not
  /// run from a mounted disk image, nor from Gatekeeper's translocated
  /// read-only copy).
  Future<bool> _canUpdate() async {
    switch (platform) {
      case UpdatePlatform.windows:
        return true;
      case UpdatePlatform.linux:
        final appImage = _appImage;
        if (appImage == null) return false;
        return _canWriteTo(p.dirname(appImage));
      case UpdatePlatform.macos:
        final bundle = _appBundle;
        if (!bundle.endsWith('.app') ||
            bundle.startsWith('/Volumes/') ||
            bundle.contains('/AppTranslocation/')) {
          return false;
        }
        return _canWriteTo(p.dirname(bundle));
      case null:
        return false;
    }
  }

  static Future<bool> _canWriteTo(String folder) async {
    final probe = File(p.join(folder, '.ziptop-update-$pid'));
    try {
      await probe.writeAsBytes(const [], flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Asks GitHub. Returns the update on offer, or null when this build is
  /// current or can't update itself (an unsupported platform, or a Linux
  /// build not run as an AppImage in a writable folder, or a Mac build not
  /// installed in a writable folder). Throws when there is
  /// no usable answer, including when the repository is private or has no
  /// releases yet.
  Future<UpdateInfo?> check() async {
    final assetName = _assetName;
    if (assetName == null || !await _canUpdate()) return null;

    final Response<dynamic> res;
    try {
      res = await _http.get<dynamic>(
        latestReleaseUrl,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            // GitHub rejects API requests without one.
            'User-Agent': 'ZipTop/$currentVersion',
          },
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      throw StateError("Can't reach GitHub: ${e.message}");
    }
    final json = asJson(res.data);
    final tag = asString(json?['tag_name']);
    if (res.statusCode != 200 || json == null || tag == null) {
      throw StateError('No release information available (${res.statusCode})');
    }
    settings.lastUpdateCheck = clock();
    if (asBool(json['draft']) == true || asBool(json['prerelease']) == true) return null;

    final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
    if (!isNewerVersion(version, currentVersion)) return null;

    String? url;
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets) {
        final a = asJson(asset);
        final name = asString(a?['name']);
        if (name != null && assetName.hasMatch(name)) {
          url = asString(a?['browser_download_url']);
          break;
        }
      }
    }
    // A release without this platform's build (still uploading, or made by
    // hand).
    if (url == null || url.isEmpty) return null;
    return UpdateInfo(version: version, downloadUrl: url);
  }

  /// The check made by itself after start-up: at most every six hours, never
  /// for a version the viewer said "later" to, and silent on any failure.
  Future<UpdateInfo?> autoCheck() async {
    final last = settings.lastUpdateCheck;
    if (last != null && clock().difference(last) < autoCheckInterval) return null;
    try {
      final update = await check();
      if (update == null || update.version == settings.dismissedUpdateVersion) return null;
      return update;
    } catch (_) {
      return null;
    }
  }

  void dismiss(UpdateInfo update) => settings.dismissedUpdateVersion = update.version;

  /// Downloads the update: on Windows the installer, to the temp folder; on
  /// Linux the AppImage, to `<APPIMAGE>.new` beside the running one so that
  /// [install] can rename it over it; on macOS the disk image, to the temp
  /// folder. [onProgress] gets 0–1, or null when the size is unknown.
  Future<File> download(
    UpdateInfo update, {
    void Function(double? fraction)? onProgress,
    CancelToken? cancel,
  }) async {
    final File target;
    switch (platform) {
      case UpdatePlatform.windows:
        final name = 'ZipTop-Setup-${_fileSafe(update.version)}.exe';
        target = File(p.join(Directory.systemTemp.path, name));
      case UpdatePlatform.linux:
        target = File('${_requireAppImage()}.new');
      case UpdatePlatform.macos:
        final name = 'ZipTop-${_fileSafe(update.version)}-macos-arm64.dmg';
        target = File(p.join(Directory.systemTemp.path, name));
      case null:
        throw UnsupportedError('Updates are not supported on this platform');
    }
    final partial = File('${target.path}.download');
    await _http.download(
      update.downloadUrl,
      partial.path,
      cancelToken: cancel,
      options: Options(headers: {'User-Agent': 'ZipTop/$currentVersion'}),
      onReceiveProgress: (received, total) =>
          onProgress?.call(total > 0 ? received / total : null),
    );
    if (await target.exists()) await target.delete();
    return partial.rename(target.path);
  }

  static String _fileSafe(String version) => version.replaceAll(RegExp(r'[^0-9A-Za-z.\-]'), '_');

  /// Starts a program on its own, so it outlives this app.
  @visibleForTesting
  static Future<void> Function(String path) launcher = (path) async {
    await Process.start(path, const [], mode: ProcessStartMode.detached);
  };

  /// Starts a program with arguments on its own, so it outlives this app
  /// (the macOS hand-over script).
  @visibleForTesting
  static Future<void> Function(String executable, List<String> arguments) detachedLauncher =
      (executable, arguments) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  };

  /// Hands over to the [download]ed update; the caller quits afterwards. On
  /// Windows this starts the installer. On Linux it makes the new AppImage
  /// executable, renames it over the running one and starts it. On macOS it
  /// copies `ZipTop.app` out of the disk image beside the running bundle,
  /// swaps the two and starts a script that removes the old bundle and opens
  /// the new one once this process has quit.
  Future<void> install(File update) async {
    switch (platform) {
      case UpdatePlatform.windows:
        await launcher(update.path);
      case UpdatePlatform.linux:
        final appImage = _requireAppImage();
        // dart:io can't set permissions. A Windows host (only reached by
        // tests) has no chmod and no executable bit.
        if (!Platform.isWindows) {
          final result = await Process.run('chmod', ['+x', update.path]);
          if (result.exitCode != 0) {
            throw FileSystemException(
              "Couldn't make the update executable: ${result.stderr}".trim(),
              update.path,
            );
          }
        }
        // Same folder, so this swaps it in one step; the running copy keeps
        // its open file until it quits.
        await update.rename(appImage);
        await launcher(appImage);
      case UpdatePlatform.macos:
        await _installMac(update);
      case null:
        throw UnsupportedError('Updates are not supported on this platform');
    }
  }

  Future<void> _installMac(File diskImage) async {
    final bundle = _appBundle;
    final parent = p.dirname(bundle);
    final staged = p.join(parent, stagedBundleName);
    final old = p.join(parent, oldBundleName);
    // Leftovers of an update that didn't finish: ditto would merge into the
    // first, and the running bundle can't be renamed onto the second.
    for (final leftover in [staged, old]) {
      final dir = Directory(leftover);
      if (await dir.exists()) await dir.delete(recursive: true);
    }

    final mount = await Directory.systemTemp.createTemp('ziptop-dmg');
    try {
      final attach = await run('hdiutil', [
        'attach',
        '-nobrowse',
        '-readonly',
        '-noautoopen',
        '-mountpoint',
        mount.path,
        diskImage.path,
      ]);
      if (attach.exitCode != 0) {
        throw FileSystemException(
          "Couldn't open the update's disk image: ${attach.stderr}".trim(),
          diskImage.path,
        );
      }
      try {
        final copy = await run('ditto', [p.join(mount.path, 'ZipTop.app'), staged]);
        if (copy.exitCode != 0) {
          await _deleteQuietly(staged);
          throw FileSystemException(
            "Couldn't copy the update out of its disk image: ${copy.stderr}".trim(),
            staged,
          );
        }
      } finally {
        await run('hdiutil', ['detach', mount.path]);
      }
    } finally {
      // Not recursive: if the detach failed, the image is still mounted here.
      try {
        await mount.delete();
      } on FileSystemException {
        // Left for the system to clear out of the temp folder.
      }
    }
    try {
      await diskImage.delete();
    } on FileSystemException {
      // Only a stray download in the temp folder.
    }

    // Same folder, so both are plain renames. This process keeps running
    // from its moved bundle until it quits.
    try {
      await Directory(bundle).rename(old);
    } on FileSystemException catch (e) {
      await _deleteQuietly(staged);
      throw FileSystemException(
        "Couldn't move the running ZipTop aside: ${e.message}",
        bundle,
        e.osError,
      );
    }
    try {
      await Directory(staged).rename(bundle);
    } on FileSystemException catch (e) {
      try {
        await Directory(old).rename(bundle);
      } on FileSystemException {
        throw StateError(
          "Couldn't put the update in place (${e.message}) nor put ZipTop back; "
          'the current version is at $old',
        );
      }
      await _deleteQuietly(staged);
      throw FileSystemException(
        "Couldn't put the update in place: ${e.message}",
        bundle,
        e.osError,
      );
    }

    // The paths go in as positional arguments ($1, $2), never into the
    // script text, so no quoting can go wrong. The pid is a number.
    await detachedLauncher('/bin/sh', [
      '-c',
      'while kill -0 $pid 2>/dev/null; do sleep 0.5; done; rm -rf "\$1"; open "\$2"',
      'ziptop-update',
      old,
      bundle,
    ]);
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort; the next update clears it out first.
    }
  }

  String _requireAppImage() =>
      _appImage ?? (throw StateError('ZipTop is not running as an AppImage'));
}
