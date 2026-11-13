import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../player/player_preferences.dart';

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
  static const _maxBitrateKey = 'max_bitrate';
  static const _panelOpenKey = 'channel_panel_open';
  static const _categoriesOpenKey = 'categories_open';
  static const _multiviewIdsKey = 'multiview_stream_ids';
  static const _multiviewLayoutKey = 'multiview_layout';
  static const _lastUpdateCheckKey = 'update_last_check_ms';
  static const _dismissedUpdateKey = 'update_dismissed_version';
  static const _knownUpdateVersionKey = 'update_known_version';
  static const _knownUpdateUrlKey = 'update_known_url';
  static const _knownUpdateSha256Key = 'update_known_sha256';
  static const _miniPlayerBoundsKey = 'mini_player_bounds';
  static const _windowBoundsKey = 'window_bounds';
  static const _windowMaximizedKey = 'window_maximized';
  static const _hwdecKey = 'player_hardware_decoding';
  static const _deinterlaceKey = 'player_deinterlace';
  static const _surroundKey = 'player_surround';
  static const _fillKey = 'player_fill';
  static const _captionsDefaultKey = 'player_captions_by_default';
  static const _captionLanguageKey = 'player_caption_language';
  static const _audioLanguageKey = 'player_audio_language';
  static const _bufferSecondsKey = 'player_buffer_seconds';
  static const _bufferMegabytesKey = 'player_buffer_megabytes';
  static const _tileBufferSecondsKey = 'player_tile_buffer_seconds';
  static const _networkTimeoutKey = 'player_network_timeout_seconds';
  static const _stallReloadKey = 'player_stall_reload_seconds';
  static const _tileMaxBitrateKey = 'player_tile_max_bitrate';

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
  List<String> get recentIds => _idList(_recentsKey);

  List<String> _idList(String key) {
    final raw = _prefs.getString(key);
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

  /// The most bits per second the viewer wants a stream to use, or null for
  /// the best each channel offers. Each channel plays its best variant at or
  /// under this.
  int? get maxBitrate {
    final value = _prefs.getInt(_maxBitrateKey);
    return value == null || value <= 0 ? null : value;
  }

  set maxBitrate(int? value) {
    if (value == null || value <= 0) {
      _prefs.remove(_maxBitrateKey);
    } else {
      _prefs.setInt(_maxBitrateKey, value);
    }
    notifyListeners();
  }

  /// How the players decode, look, sound and buffer.
  PlayerPreferences get playerPreferences {
    const d = PlayerPreferences.defaults;
    int choice(String key, List<int> choices, int fallback) {
      final value = _prefs.getInt(key);
      return value != null && choices.contains(value) ? value : fallback;
    }

    String? language(String key) {
      final code = _prefs.getString(key);
      return code != null && trackLanguages.containsKey(code) ? code : null;
    }

    final tileRate = _prefs.getInt(_tileMaxBitrateKey);
    return PlayerPreferences(
      hardwareDecoding: HardwareDecoding.byName(_prefs.getString(_hwdecKey)),
      deinterlace: _prefs.getBool(_deinterlaceKey) ?? d.deinterlace,
      surround: _prefs.getBool(_surroundKey) ?? d.surround,
      fill: _prefs.getBool(_fillKey) ?? d.fill,
      captionsByDefault: _prefs.getBool(_captionsDefaultKey) ?? d.captionsByDefault,
      captionLanguage: language(_captionLanguageKey),
      audioLanguage: language(_audioLanguageKey),
      bufferSeconds:
          choice(_bufferSecondsKey, PlayerPreferences.bufferSecondsChoices, d.bufferSeconds),
      bufferMegabytes:
          choice(_bufferMegabytesKey, PlayerPreferences.bufferMegabytesChoices, d.bufferMegabytes),
      tileBufferSeconds: choice(
          _tileBufferSecondsKey, PlayerPreferences.tileBufferSecondsChoices, d.tileBufferSeconds),
      networkTimeoutSeconds: choice(
          _networkTimeoutKey, PlayerPreferences.networkTimeoutChoices, d.networkTimeoutSeconds),
      stallReloadSeconds:
          choice(_stallReloadKey, PlayerPreferences.stallReloadChoices, d.stallReloadSeconds),
      // Saved as 0 for no limit; missing or unknown is the default.
      tileMaxBitrate: tileRate == 0
          ? null
          : tileRate != null && PlayerPreferences.tileMaxBitrateChoices.contains(tileRate)
              ? tileRate
              : d.tileMaxBitrate,
    );
  }

  set playerPreferences(PlayerPreferences value) {
    if (value == playerPreferences) return;
    void setString(String key, String? text) =>
        text == null ? _prefs.remove(key) : _prefs.setString(key, text);
    _prefs.setString(_hwdecKey, value.hardwareDecoding.name);
    _prefs.setBool(_deinterlaceKey, value.deinterlace);
    _prefs.setBool(_surroundKey, value.surround);
    _prefs.setBool(_fillKey, value.fill);
    _prefs.setBool(_captionsDefaultKey, value.captionsByDefault);
    setString(_captionLanguageKey, value.captionLanguage);
    setString(_audioLanguageKey, value.audioLanguage);
    _prefs.setInt(_bufferSecondsKey, value.bufferSeconds);
    _prefs.setInt(_bufferMegabytesKey, value.bufferMegabytes);
    _prefs.setInt(_tileBufferSecondsKey, value.tileBufferSeconds);
    _prefs.setInt(_networkTimeoutKey, value.networkTimeoutSeconds);
    _prefs.setInt(_stallReloadKey, value.stallReloadSeconds);
    _prefs.setInt(_tileMaxBitrateKey, value.tileMaxBitrate ?? 0);
    notifyListeners();
  }

  /// Changes some of the player settings.
  void updatePlayerPreferences(PlayerPreferences Function(PlayerPreferences) change) =>
      playerPreferences = change(playerPreferences);

  /// Puts the Advanced page's buffer settings back to their defaults.
  void resetAdvancedPlayback() =>
      playerPreferences = playerPreferences.withAdvancedDefaults();

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

  /// The channels last shown in multiview, in tile order.
  List<String> get multiviewIds => _idList(_multiviewIdsKey);
  set multiviewIds(List<String> ids) {
    _prefs.setString(_multiviewIdsKey, jsonEncode(ids));
    notifyListeners();
  }

  String? get multiviewLayout => _prefs.getString(_multiviewLayoutKey);
  set multiviewLayout(String? name) {
    if (name == null) {
      _prefs.remove(_multiviewLayoutKey);
    } else {
      _prefs.setString(_multiviewLayoutKey, name);
    }
    notifyListeners();
  }

  /// When the server was last asked about updates.
  DateTime? get lastUpdateCheck {
    final ms = _prefs.getInt(_lastUpdateCheckKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set lastUpdateCheck(DateTime? value) {
    if (value == null) {
      _prefs.remove(_lastUpdateCheckKey);
    } else {
      _prefs.setInt(_lastUpdateCheckKey, value.millisecondsSinceEpoch);
    }
  }

  /// A version the viewer chose "Later" for; not offered again by itself.
  String? get dismissedUpdateVersion => _prefs.getString(_dismissedUpdateKey);
  set dismissedUpdateVersion(String? value) {
    if (value == null) {
      _prefs.remove(_dismissedUpdateKey);
    } else {
      _prefs.setString(_dismissedUpdateKey, value);
    }
  }

  /// The newer release the last check found, so the update button survives
  /// a restart between checks. [sha256] is null for one found before the
  /// server gave hashes (a GitHub release).
  ({String version, String url, String? sha256})? get knownUpdate {
    final version = _prefs.getString(_knownUpdateVersionKey);
    final url = _prefs.getString(_knownUpdateUrlKey);
    if (version == null || url == null || url.isEmpty) return null;
    return (version: version, url: url, sha256: _prefs.getString(_knownUpdateSha256Key));
  }

  set knownUpdate(({String version, String url, String? sha256})? value) {
    if (value == null) {
      _prefs.remove(_knownUpdateVersionKey);
      _prefs.remove(_knownUpdateUrlKey);
      _prefs.remove(_knownUpdateSha256Key);
    } else {
      _prefs.setString(_knownUpdateVersionKey, value.version);
      _prefs.setString(_knownUpdateUrlKey, value.url);
      final sha256 = value.sha256;
      if (sha256 == null) {
        _prefs.remove(_knownUpdateSha256Key);
      } else {
        _prefs.setString(_knownUpdateSha256Key, sha256);
      }
    }
  }

  /// Where the pop-out mini player last sat (x, y, width, height in logical
  /// pixels), or null to use the default corner.
  Rect? get miniPlayerBounds => _rect(_miniPlayerBoundsKey);
  set miniPlayerBounds(Rect? value) => _setRect(_miniPlayerBoundsKey, value);

  /// Where the main window last sat when neither maximized nor full screen
  /// (logical pixels), or null to centre it at the default size.
  Rect? get windowBounds => _rect(_windowBoundsKey);
  set windowBounds(Rect? value) => _setRect(_windowBoundsKey, value);

  /// Whether the main window was maximized when last left.
  bool get windowMaximized => _prefs.getBool(_windowMaximizedKey) ?? false;
  set windowMaximized(bool value) => _prefs.setBool(_windowMaximizedKey, value);

  Rect? _rect(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.length == 4 && decoded.every((v) => v is num)) {
        final [x, y, w, h] = [for (final v in decoded) (v as num).toDouble()];
        if (w > 0 && h > 0) return Rect.fromLTWH(x, y, w, h);
      }
    } catch (_) {
      // Corrupt value; use the default.
    }
    return null;
  }

  void _setRect(String key, Rect? value) {
    if (value == null) {
      _prefs.remove(key);
    } else {
      _prefs.setString(key, jsonEncode([value.left, value.top, value.width, value.height]));
    }
  }

  /// Forgets what was watched here (sign-out). Preferences stay.
  void clearHistory() {
    _prefs.remove(_recentsKey);
    _prefs.remove(_lastChannelKey);
    _prefs.remove(_multiviewIdsKey);
    notifyListeners();
  }
}
