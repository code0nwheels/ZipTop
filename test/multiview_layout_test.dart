import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/features/multiview/multiview_layout.dart';

void main() {
  const size = Size(1200, 600);

  /// Total overlap between any two rectangles.
  double overlap(List<Rect> rects) {
    var total = 0.0;
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final hit = rects[i].intersect(rects[j]);
        if (hit.width > 0.001 && hit.height > 0.001) total += hit.width * hit.height;
      }
    }
    return total;
  }

  test('grid shapes match the Android app', () {
    expect(
      [for (var n = 1; n <= 8; n++) gridShape(n)],
      [
        [1],
        [2],
        [2, 1],
        [2, 2],
        [3, 2],
        [3, 3],
        [4, 3],
        [4, 4],
      ],
    );
  });

  test('every layout places every tile inside the area without overlap', () {
    for (final layout in MultiLayout.values) {
      for (var n = 1; n <= maxMultiviewTiles; n++) {
        final rects = layoutTiles(layout, n, size);
        expect(rects, hasLength(n), reason: '$layout $n');
        expect(overlap(rects), 0, reason: '$layout $n');
        for (final r in rects) {
          expect(r.left >= -0.001 && r.top >= -0.001, isTrue, reason: '$layout $n');
          expect(r.right <= size.width + 0.001, isTrue, reason: '$layout $n');
          expect(r.bottom <= size.height + 0.001, isTrue, reason: '$layout $n');
          expect(r.width > 0 && r.height > 0, isTrue, reason: '$layout $n');
        }
      }
    }
  });

  test('one tile fills the area in every layout', () {
    for (final layout in MultiLayout.values) {
      expect(layoutTiles(layout, 1, size), [Offset.zero & size]);
    }
  });

  test('a short last grid row is centred', () {
    final rects = layoutTiles(MultiLayout.grid, 3, size);
    expect(rects[0], const Rect.fromLTWH(0, 0, 600, 300));
    expect(rects[1], const Rect.fromLTWH(600, 0, 600, 300));
    expect(rects[2], const Rect.fromLTWH(300, 300, 600, 300));
  });

  test('hero layouts give tile 0 two thirds', () {
    final left = layoutTiles(MultiLayout.heroLeft, 3, size);
    expect(left[0], const Rect.fromLTWH(0, 0, 800, 600));
    expect(left[1], const Rect.fromLTWH(800, 0, 400, 300));
    expect(left[2], const Rect.fromLTWH(800, 300, 400, 300));

    final right = layoutTiles(MultiLayout.heroRight, 2, size);
    expect(right[0], const Rect.fromLTWH(400, 0, 800, 600));
    expect(right[1], const Rect.fromLTWH(0, 0, 400, 600));

    final top = layoutTiles(MultiLayout.heroTop, 4, size);
    expect(top[0], const Rect.fromLTWH(0, 0, 1200, 400));
    expect(top[3], const Rect.fromLTWH(800, 400, 400, 200));
  });

  test('dual hero needs three tiles and otherwise falls back to the grid', () {
    expect(MultiLayout.dualHero.availableFor(2), isFalse);
    expect(MultiLayout.dualHero.availableFor(3), isTrue);
    expect(layoutTiles(MultiLayout.dualHero, 2, size), layoutTiles(MultiLayout.grid, 2, size));

    final rects = layoutTiles(MultiLayout.dualHero, 4, size);
    expect(rects[0].width, 600);
    expect(rects[1].left, 600);
    expect(rects[0].height, closeTo(372, 0.001));
    expect(rects[2].top, closeTo(372, 0.001));
  });

  test('layout names survive a round trip, unknown names mean grid', () {
    for (final layout in MultiLayout.values) {
      expect(MultiLayout.byName(layout.name), layout);
    }
    expect(MultiLayout.byName(null), MultiLayout.grid);
    expect(MultiLayout.byName('nonsense'), MultiLayout.grid);
  });
}
