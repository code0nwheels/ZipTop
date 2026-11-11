import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// The pop-out mini player's size when it has no saved place yet.
const miniPlayerDefaultSize = Size(480, 270);

/// The smallest the mini player can be dragged to.
const miniPlayerMinimumSize = Size(320, 180);

/// Gap between the default mini player and the screen corner.
const _cornerMargin = 16.0;

/// Where the mini player goes: [saved] when enough of it is on one of the
/// [workAreas] (each display minus its taskbar or dock) to grab, otherwise
/// [miniPlayerDefaultSize] in the bottom-right corner of the work area under
/// the middle of [window], the full window it pops out of.
Rect placeMiniPlayer({
  required Rect? saved,
  required List<Rect> workAreas,
  required Rect window,
}) {
  if (saved != null && _reachable(saved, workAreas)) return saved;
  // No display list: the corner of the full window, which is on screen.
  final area = workAreas.isEmpty
      ? window
      : workAreas.firstWhere(
          (area) => area.contains(window.center),
          orElse: () => workAreas.first,
        );
  return Offset(
        area.right - miniPlayerDefaultSize.width - _cornerMargin,
        area.bottom - miniPlayerDefaultSize.height - _cornerMargin,
      ) &
      miniPlayerDefaultSize;
}

/// At least a thumb's worth of the window lies on some display, enough to
/// drag it back (the whole mini player is a drag handle). A monitor that was
/// unplugged or rearranged would otherwise leave it out of reach.
bool _reachable(Rect bounds, List<Rect> workAreas) {
  const grab = 48.0;
  for (final area in workAreas) {
    final overlap = area.intersect(bounds);
    if (overlap.width >= grab && overlap.height >= grab) return true;
  }
  return false;
}

/// Drags the frameless mini player around. window_manager's DragToMoveArea
/// would also maximize it on a double-click, which the player keeps for
/// going back to the full window.
class MiniPlayerDragArea extends StatelessWidget {
  const MiniPlayerDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: child,
    );
  }
}
