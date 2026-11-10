import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-machine preferences. Everything about categories and favorites
/// lives on the account instead; see `CatalogStore`.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  static const maxRecents = 10;

  static const _playLastKey = 'auto_play_last_stream';
  static const _recentsEnabledKey = 'recents_enabled';
  static const _recentsKey = 'recent_stream_ids';
  static const _lastChannelKey = 'last_stream_id';
  static const _volumeKey = 'volume';
  static const _panelOpenKey = 'channel_panel_open';
  static const _categoriesOpenKey = 'categories_open';

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

  /// Resume the last channel when the app starts.
  bool get playLastOnStart => _prefs.getBool(_playLastKey) ?? true;
  set playLastOnStart(bool value) {
    _prefs.setBool(_playLastKey, value);
    notifyListeners();
  }

  /// Keep and show the Recent row.
  bool get recentsEnabled => _prefs.getBool(_recentsEnabledKey) ?? true;
  set recentsEnabled(bool value) {
    _prefs.setBool(_recentsEnabledKey, value);
    notifyListeners();
  }

  /// Most recent first, at most [maxRecents].
  List<String> get recentIds {
    final raw = _prefs.getString(_recentsKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return [for (final id in decoded) id.toString()];
    } catch (_) {
      // Corrupt value; start over.
    }
    return const [];
  }

  String? get lastChannelId => _prefs.getString(_lastChannelKey);

  /// Records a tune: moves [streamId] to the front of the recents.
  void rememberChannel(String streamId) {
    final ids = [streamId, ...recentIds.where((id) => id != streamId)];
    _prefs.setString(_recentsKey, jsonEncode(ids.take(maxRecents).toList()));
    _prefs.setString(_lastChannelKey, streamId);
    notifyListeners();
  }

  /// 0–100.
  double get volume => (_prefs.getDouble(_volumeKey) ?? 100).clamp(0, 100).toDouble();
  set volume(double value) {
    _prefs.setDouble(_volumeKey, value.clamp(0, 100).toDouble());
    notifyListeners();
  }

  /// Whether the channel panel sits beside the video.
  bool get panelOpen => _prefs.getBool(_panelOpenKey) ?? true;
  set panelOpen(bool value) {
    _prefs.setBool(_panelOpenKey, value);
    notifyListeners();
  }

  /// Whether the channel panel shows its category column.
  bool get categoriesOpen => _prefs.getBool(_categoriesOpenKey) ?? true;
  set categoriesOpen(bool value) {
    _prefs.setBool(_categoriesOpenKey, value);
    notifyListeners();
  }

  /// Forgets what was watched here (sign-out). Preferences stay.
  void clearHistory() {
    _prefs.remove(_recentsKey);
    _prefs.remove(_lastChannelKey);
    notifyListeners();
  }
}
