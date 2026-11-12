import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/core/platform/window_placement.dart';
import 'package:ziptop/core/stores/settings_store.dart';

void main() {
  // Two displays side by side, each with a 48 px taskbar along the bottom.
  const left = Rect.fromLTWH(0, 0, 1920, 1032);
  const right = Rect.fromLTWH(1920, 0, 1920, 1032);

  group('restoreWindowBounds', () {
    test('nothing saved: centre at the default size', () {
      expect(restoreWindowBounds(null, const [left, right]), isNull);
    });

    test('goes back where it was last, on either display', () {
      const onLeft = Rect.fromLTWH(200, 100, 1280, 760);
      const onRight = Rect.fromLTWH(2100, 60, 1400, 900);
      expect(restoreWindowBounds(onLeft, const [left, right]), onLeft);
      expect(restoreWindowBounds(onRight, const [left, right]), onRight);
      // Straddling the two is fine too.
      const across = Rect.fromLTWH(1500, 100, 1280, 760);
      expect(restoreWindowBounds(across, const [left, right]), across);
    });

    test('ignores a place on a display that has gone', () {
      const onRight = Rect.fromLTWH(2100, 60, 1400, 900);
      expect(restoreWindowBounds(onRight, const [left]), isNull);
    });

    test('ignores a place with the title bar out of reach', () {
      // Above the top of the screen: only the bottom of the window shows.
      const above = Rect.fromLTWH(200, -700, 1280, 760);
      expect(restoreWindowBounds(above, const [left]), isNull);
      // Only a sliver of the title bar left at the edge.
      const sliver = Rect.fromLTWH(1900, 100, 1280, 760);
      expect(restoreWindowBounds(sliver, const [left]), isNull);
    });

    test('shrinks a window too big for its display to fit', () {
      const laptop = Rect.fromLTWH(0, 0, 1366, 720);
      const big = Rect.fromLTWH(100, 50, 1800, 1000);
      expect(restoreWindowBounds(big, const [laptop]), const Rect.fromLTWH(0, 0, 1366, 720));
      const wide = Rect.fromLTWH(100, 50, 1800, 600);
      expect(restoreWindowBounds(wide, const [laptop]), const Rect.fromLTWH(0, 50, 1366, 600));
    });

    test('no display list: centre at the default size', () {
      expect(restoreWindowBounds(const Rect.fromLTWH(200, 100, 1280, 760), const []), isNull);
    });
  });

  group('SettingsStore window place', () {
    test('round-trips bounds and maximized', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsStore.load();
      expect(settings.windowBounds, isNull);
      expect(settings.windowMaximized, isFalse);

      settings.windowBounds = const Rect.fromLTWH(-1500, 20, 1400, 900);
      settings.windowMaximized = true;
      final again = await SettingsStore.load();
      expect(again.windowBounds, const Rect.fromLTWH(-1500, 20, 1400, 900));
      expect(again.windowMaximized, isTrue);
    });

    test('a corrupt value reads as nothing saved', () async {
      SharedPreferences.setMockInitialValues({'window_bounds': '[1, 2, "x"]'});
      final settings = await SettingsStore.load();
      expect(settings.windowBounds, isNull);
    });
  });
}
