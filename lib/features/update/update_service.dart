import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/api/api_client.dart';
import '../../core/api/api_config.dart';
import '../../core/models/json.dart';
import '../../core/stores/settings_store.dart';

/// A newer ZipTop the server is offering.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.downloadUrl});
  final String version;

  /// Absolute URL of the Windows installer.
  final String downloadUrl;
}

/// True when [remote] is a later version than [local]. Compares the dotted
/// numbers only, so `1.2.0+7` and `v1.2` are read as 1.2.0 and 1.2.
bool isNewerVersion(String remote, String local) {
  List<int> parts(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[+\-]')).first;
    return [for (final part in core.split('.')) int.tryParse(part) ?? 0];
  }

  final a = parts(remote);
  final b = parts(local);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Checks the server for a newer desktop build, downloads its installer and
/// hands over to it.
///
/// The endpoint mirrors the Android app's `atv/version` and answers
/// `{"version", "download_url", "available"}`.
class UpdateService {
  UpdateService({
    required this.client,
    required this.config,
    required this.settings,
    required this.currentVersion,
    Dio? downloader,
    this.clock = DateTime.now,
  }) : _downloader = downloader ?? Dio();

  /// Where the backend publishes the desktop release. Relative to the API host.
  static const versionPath = String.fromEnvironment(
    'UPDATE_PATH',
    defaultValue: 'desktop/version',
  );

  /// Automatic checks happen at most this often.
  static const autoCheckInterval = Duration(hours: 6);

  final ApiClient client;
  final ApiConfig config;
  final SettingsStore settings;
  final String currentVersion;
  final Dio _downloader;
  final DateTime Function() clock;

  /// Asks the server. Returns the update on offer, or null when this build
  /// is current. Throws when the server gave no usable answer.
  Future<UpdateInfo?> check() async {
    final res = await client.get(versionPath);
    final json = res.json;
    final version = asString(json?['version']);
    final url = asString(json?['download_url']);
    if (!res.ok || json == null || version == null) {
      throw StateError('No update information available (${res.statusCode})');
    }
    settings.lastUpdateCheck = clock();
    final available = asBool(json['available']) ?? true;
    if (!available || url == null || url.isEmpty) return null;
    if (!isNewerVersion(version, currentVersion)) return null;
    return UpdateInfo(version: version, downloadUrl: config.resolveDownloadUrl(url));
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

  /// Downloads the installer to the temp folder. [onProgress] gets 0–1, or
  /// null when the size is unknown.
  Future<File> download(
    UpdateInfo update, {
    void Function(double? fraction)? onProgress,
    CancelToken? cancel,
  }) async {
    final name = 'ZipTop-Setup-${update.version.replaceAll(RegExp(r'[^0-9A-Za-z.\-]'), '_')}.exe';
    final target = File(p.join(Directory.systemTemp.path, name));
    final partial = File('${target.path}.download');
    await _downloader.download(
      update.downloadUrl,
      partial.path,
      cancelToken: cancel,
      onReceiveProgress: (received, total) =>
          onProgress?.call(total > 0 ? received / total : null),
    );
    if (await target.exists()) await target.delete();
    return partial.rename(target.path);
  }

  /// Starts the installer on its own, so it outlives this app.
  @visibleForTesting
  static Future<void> Function(String path) launcher = (path) async {
    await Process.start(path, const [], mode: ProcessStartMode.detached);
  };

  Future<void> launchInstaller(File installer) => launcher(installer.path);
}
