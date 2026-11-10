import 'dart:ui';

/// How multiview tiles are arranged. Names follow the Android app.
enum MultiLayout {
  grid('Grid'),
  heroTop('Hero top'),
  heroLeft('Hero left'),
  heroRight('Hero right'),
  dualHero('Dual hero');

  const MultiLayout(this.label);
  final String label;

  /// Dual hero needs two big tiles and at least one small one.
  bool availableFor(int tiles) => this != dualHero || tiles >= 3;

  static MultiLayout byName(String? name) {
    for (final layout in values) {
      if (layout.name == name) return layout;
    }
    return grid;
  }
}

const maxMultiviewTiles = 8;

/// Tiles per row in the grid, top row first.
List<int> gridShape(int tiles) => switch (tiles) {
      <= 0 => const [],
      1 => const [1],
      2 => const [2],
      3 => const [2, 1],
      4 => const [2, 2],
      5 => const [3, 2],
      6 => const [3, 3],
      7 => const [4, 3],
      _ => const [4, 4],
    };

/// Where each of [tiles] tiles goes inside [size]. Tile 0 is the hero in the
/// hero layouts; tiles 0 and 1 are the heroes in dual hero.
List<Rect> layoutTiles(MultiLayout layout, int tiles, Size size) {
  if (tiles <= 0) return const [];
  final count = tiles > maxMultiviewTiles ? maxMultiviewTiles : tiles;
  final w = size.width;
  final h = size.height;
  if (count == 1) return [Offset.zero & size];

  final effective = layout.availableFor(count) ? layout : MultiLayout.grid;
  switch (effective) {
    case MultiLayout.grid:
      final shape = gridShape(count);
      final rowHeight = h / shape.length;
      final widest = shape.reduce((a, b) => a > b ? a : b);
      final tileWidth = w / widest;
      final rects = <Rect>[];
      for (var row = 0; row < shape.length; row++) {
        // A shorter last row is centred rather than stretched.
        final inset = (w - tileWidth * shape[row]) / 2;
        for (var col = 0; col < shape[row]; col++) {
          rects.add(Rect.fromLTWH(inset + col * tileWidth, row * rowHeight, tileWidth, rowHeight));
        }
      }
      return rects;

    case MultiLayout.heroTop:
      final heroHeight = h * 2 / 3;
      final others = count - 1;
      final width = w / others;
      return [
        Rect.fromLTWH(0, 0, w, heroHeight),
        for (var i = 0; i < others; i++)
          Rect.fromLTWH(i * width, heroHeight, width, h - heroHeight),
      ];

    case MultiLayout.heroLeft:
    case MultiLayout.heroRight:
      final heroWidth = w * 2 / 3;
      final others = count - 1;
      final height = h / others;
      final left = effective == MultiLayout.heroLeft;
      return [
        Rect.fromLTWH(left ? 0 : w - heroWidth, 0, heroWidth, h),
        for (var i = 0; i < others; i++)
          Rect.fromLTWH(left ? heroWidth : 0, i * height, w - heroWidth, height),
      ];

    case MultiLayout.dualHero:
      final heroHeight = h * 0.62;
      final others = count - 2;
      final width = w / others;
      return [
        Rect.fromLTWH(0, 0, w / 2, heroHeight),
        Rect.fromLTWH(w / 2, 0, w / 2, heroHeight),
        for (var i = 0; i < others; i++)
          Rect.fromLTWH(i * width, heroHeight, width, h - heroHeight),
      ];
  }
}
