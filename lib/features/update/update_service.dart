import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/models/json.dart';
import '../../core/stores/settings_store.dart';

/// A newer ZipTop on offer.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.downloadUrl});
  final String version;

  /// Absolute URL of the installer or AppImage for this platform.
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
enum UpdatePlatform { windows, linux }

/// Checks GitHub for a newer published release, downloads this platform's
/// build and hands over to it.
///
/// Releases are made by CI: each one is tagged `v<version>` and carries
/// `ZipTop-Setup-<version>.exe` for Windows and
/// `ZipTop-<version>-x86_64.AppImage` for Linux. Drafts and pre-releases are
/// never offered.
///
/// On Windows the installer is downloaded to the temp folder and started. On
/// Linux only the AppImage build can update itself: the new AppImage is
/// downloaded next to the running one (named by the `APPIMAGE` variable its
/// runtime sets), renamed over it and started.
class UpdateService {
  UpdateService({
    required this.settings,
    required this.currentVersion,
    Dio? http,
    this.clock = DateTime.now,
    UpdatePlatform? platform,
    Map<String, String>? environment,
  })  : _http = http ?? Dio(),
        platform = platform ?? _hostPlatform(),
        environment = environment ?? Platform.environment;

  static UpdatePlatform? _hostPlatform() {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
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

  final SettingsStore settings;
  final String currentVersion;
  final Dio _http;
  final DateTime Function() clock;

  /// The platform being updated, or null when this one can't be.
  final UpdatePlatform? platform;

  /// Where `APPIMAGE` is read from on Linux.
  final Map<String, String> environment;

  /// The running AppImage, or null when this build isn't one.
  String? get _appImage {
    final path = environment['APPIMAGE'];
    return path == null || path.isEmpty ? null : path;
  }

  RegExp? get _assetName => switch (platform) {
        UpdatePlatform.windows => _installerName,
        UpdatePlatform.linux => _appImageName,
        null => null,
      };

  /// Whether this copy can replace itself: always on Windows (the installer
  /// does it); on Linux only as an AppImage whose folder can be written to.
  Future<bool> _canUpdate() async {
    switch (platform) {
      case UpdatePlatform.windows:
        return true;
      case UpdatePlatform.linux:
        final appImage = _appImage;
        if (appImage == null) return false;
        final probe = File(p.join(p.dirname(appImage), '.ziptop-update-$pid'));
        try {
          await probe.writeAsBytes(const [], flush: true);
          await probe.delete();
          return true;
        } on FileSystemException {
          return false;
        }
      case null:
        return false;
    }
  }

  /// Asks GitHub. Returns the update on offer, or null when this build is
  /// current or can't update itself (an unsupported platform, or a Linux
  /// build not run as an AppImage in a writable folder). Throws when there is
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
  /// [install] can rename it over it. [onProgress] gets 0–1, or null when the
  /// size is unknown.
  Future<File> download(
    UpdateInfo update, {
    void Function(double? fraction)? onProgress,
    CancelToken? cancel,
  }) async {
    final File target;
    switch (platform) {
      case UpdatePlatform.windows:
        final name =
            'ZipTop-Setup-${update.version.replaceAll(RegExp(r'[^0-9A-Za-z.\-]'), '_')}.exe';
        target = File(p.join(Directory.systemTemp.path, name));
      case UpdatePlatform.linux:
        target = File('${_requireAppImage()}.new');
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

  /// Starts a program on its own, so it outlives this app.
  @visibleForTesting
  static Future<void> Function(String path) launcher = (path) async {
    await Process.start(path, const [], mode: ProcessStartMode.detached);
  };

  /// Hands over to the [download]ed update; the caller quits afterwards. On
  /// Windows this starts the installer. On Linux it makes the new AppImage
  /// executable, renames it over the running one and starts it.
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
      case null:
        throw UnsupportedError('Updates are not supported on this platform');
    }
  }

  String _requireAppImage() =>
      _appImage ?? (throw StateError('ZipTop is not running as an AppImage'));
}
