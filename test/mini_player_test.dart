import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/features/shell/mini_player.dart';

void main() {
  // Two displays side by side, each with a 48 px taskbar along the bottom.
  const left = Rect.fromLTWH(0, 0, 1920, 1032);
  const right = Rect.fromLTWH(1920, 0, 1920, 1032);
  const window = Rect.fromLTWH(200, 100, 1280, 760);

  group('placeMiniPlayer', () {
    test('goes to the bottom-right of the display the window is on', () {
      expect(
        placeMiniPlayer(saved: null, workAreas: const [left, right], window: window),
        const Rect.fromLTWH(1920 - 480 - 16, 1032 - 270 - 16, 480, 270),
      );
      expect(
        placeMiniPlayer(
          saved: null,
          workAreas: const [left, right],
          window: window.shift(const Offset(1920, 0)),
        ),
        const Rect.fromLTWH(3840 - 480 - 16, 1032 - 270 - 16, 480, 270),
      );
    });

    test('goes back where it was last', () {
      const saved = Rect.fromLTWH(2000, 40, 640, 360);
      expect(placeMiniPlayer(saved: saved, workAreas: const [left, right], window: window), saved);
      // Hanging mostly off an edge is fine while enough is left to drag.
      const edge = Rect.fromLTWH(1840, 900, 640, 360);
      expect(placeMiniPlayer(saved: edge, workAreas: const [left], window: window), edge);
    });

    test('ignores a saved place that is off screen', () {
      // The right-hand display has been unplugged.
      const saved = Rect.fromLTWH(2000, 40, 640, 360);
      expect(
        placeMiniPlayer(saved: saved, workAreas: const [left], window: window),
        const Rect.fromLTWH(1920 - 480 - 16, 1032 - 270 - 16, 480, 270),
      );
      // Only a sliver still showing.
      const sliver = Rect.fromLTWH(1900, 500, 640, 360);
      expect(
        placeMiniPlayer(saved: sliver, workAreas: const [left], window: window),
        isNot(sliver),
      );
    });

    test('uses the window corner when the displays are unknown', () {
      expect(
        placeMiniPlayer(saved: null, workAreas: const [], window: window),
        const Rect.fromLTWH(1480 - 480 - 16, 860 - 270 - 16, 480, 270),
      );
    });
  });
}
