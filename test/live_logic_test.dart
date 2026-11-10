import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/core/models/catalog.dart';
import 'package:ziptop/core/stores/settings_store.dart';
import 'package:ziptop/features/live/channel_panel.dart';

void main() {
  group('SettingsStore', () {
    late SettingsStore settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsStore.load();
    });

    test('defaults match the Android app', () {
      expect(settings.playLastOnStart, isTrue);
      expect(settings.recentsEnabled, isTrue);
      expect(settings.recentIds, isEmpty);
      expect(settings.lastChannelId, isNull);
      expect(settings.volume, 100);
      expect(settings.panelOpen, isTrue);
      expect(settings.categoriesOpen, isTrue);
    });

    test('panel visibility is remembered', () async {
      settings.panelOpen = false;
      settings.categoriesOpen = false;

      final reloaded = await SettingsStore.load();
      expect(reloaded.panelOpen, isFalse);
      expect(reloaded.categoriesOpen, isFalse);
    });

    test('recents are most-recent-first, de-duplicated and capped at 10', () {
      for (var i = 0; i < 12; i++) {
        settings.rememberChannel('c$i');
      }
      settings.rememberChannel('c5');

      expect(settings.recentIds, hasLength(SettingsStore.maxRecents));
      expect(settings.recentIds.first, 'c5');
      expect(settings.recentIds.where((id) => id == 'c5'), hasLength(1));
      expect(settings.recentIds[1], 'c11');
      expect(settings.lastChannelId, 'c5');
    });

    test('sign-out clears history but keeps preferences', () {
      settings.rememberChannel('a');
      settings.playLastOnStart = false;
      settings.volume = 40;

      settings.clearHistory();
      expect(settings.recentIds, isEmpty);
      expect(settings.lastChannelId, isNull);
      expect(settings.playLastOnStart, isFalse);
      expect(settings.volume, 40);
    });

    test('volume is clamped to 0–100', () {
      settings.volume = 250;
      expect(settings.volume, 100);
      settings.volume = -5;
      expect(settings.volume, 0);
    });
  });

  test('now-playing progress', () {
    final now = NowPlaying(
      start: DateTime.utc(2026, 1, 1, 12),
      stop: DateTime.utc(2026, 1, 1, 13),
    );
    expect(nowPlayingProgress(now, DateTime.utc(2026, 1, 1, 12, 15)), 0.25);
    expect(nowPlayingProgress(now, DateTime.utc(2026, 1, 1, 11)), isNull);
    expect(nowPlayingProgress(now, DateTime.utc(2026, 1, 1, 14)), isNull);
    expect(nowPlayingProgress(const NowPlaying(title: 'x')), isNull);
    expect(nowPlayingProgress(null), isNull);
  });
}
