import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../stores/settings_store.dart';

/// The main window's size the first time ZipTop opens.
const defaultWindowSize = Size(1280, 760);

/// The smallest the main window can be dragged to.
const minimumWindowSize = Size(900, 560);

/// How much of the title bar has to land on a display for a saved place to
/// be used: enough to grab and drag the window back.
const _titleBarHeight = 32.0;
const _grabWidth = 64.0;
const _grabHeight = 16.0;

/// Each display's area minus its taskbar or dock, or none if they can't be
/// listed.
Future<List<Rect>> displayWorkAreas() async {
  try {
    return [
      for (final display in await screenRetriever.getAllDisplays())
        (display.visiblePosition ?? Offset.zero) & (display.visibleSize ?? display.size),
    ];
  } catch (_) {
    return const [];
  }
}

/// Where the main window goes back to: [saved] when enough of its title bar
/// is on one of the [workAreas] to drag it by, shrunk to fit that display if
/// it has become too big for it. Null (centre it at the default size) when
/// there is no saved place, it is off every display (a monitor unplugged or
/// rearranged), or the displays can't be listed.
Rect? restoreWindowBounds(Rect? saved, List<Rect> workAreas) {
  if (saved == null) return null;
  final titleBar = Rect.fromLTWH(saved.left, saved.top, saved.width, _titleBarHeight);
  for (final area in workAreas) {
    final overlap = area.intersect(titleBar);
    if (overlap.width < _grabWidth || overlap.height < _grabHeight) continue;
    final width = math.min(saved.width, area.width);
    final height = math.min(saved.height, area.height);
    if (width == saved.width && height == saved.height) return saved;
    return Rect.fromLTWH(
      saved.left.clamp(area.left, area.right - width).toDouble(),
      saved.top.clamp(area.top, area.bottom - height).toDouble(),
      width,
      height,
    );
  }
  return null;
}

/// Remembers where the main window is and whether it is maximized, so the
/// next start opens it the same way. Full screen, minimized and the mini
/// player are not remembered: those leave the last normal place alone.
class WindowPlacement with WindowListener {
  WindowPlacement(this._settings);

  final SettingsStore _settings;

  static const _settle = Duration(milliseconds: 500);

  Timer? _pending;
  bool _maximizeOnShow = false;

  /// Set while the window is popped out into the mini player, whose place
  /// is kept separately.
  bool _suspended = false;
  bool get suspended => _suspended;
  set suspended(bool value) {
    _suspended = value;
    if (value) {
      _pending?.cancel();
      _pending = null;
    } else {
      _schedule();
    }
  }

  /// Puts the window where it was last, before it is first shown. When
  /// [show] is false (started at sign-in) a maximized window is only
  /// maximized by [show], since maximizing on Windows also shows it.
  Future<void> restore({required Rect? bounds, required bool show}) async {
    if (bounds != null) await windowManager.setBounds(bounds);
    if (_settings.windowMaximized) {
      if (show) {
        await windowManager.maximize();
      } else {
        _maximizeOnShow = true;
      }
    }
    windowManager.addListener(this);
  }

  /// Shows a window that started hidden, maximized if it was last time.
  Future<void> show() async {
    if (_maximizeOnShow) {
      _maximizeOnShow = false;
      await windowManager.maximize();
    }
    await windowManager.show();
  }

  /// Saves now if a move or resize is still waiting to settle (quitting).
  Future<void> flush() async {
    if (_pending == null) return;
    _pending!.cancel();
    _pending = null;
    await _save();
  }

  void _schedule() {
    if (_suspended) return;
    _pending?.cancel();
    _pending = Timer(_settle, () {
      _pending = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      if (_suspended ||
          await windowManager.isFullScreen() ||
          await windowManager.isMinimized()) {
        return;
      }
      if (await windowManager.isMaximized()) {
        // Keep the normal place to come back to when unmaximized.
        _settings.windowMaximized = true;
        return;
      }
      final bounds = await windowManager.getBounds();
      if (_suspended || bounds.width <= 0 || bounds.height <= 0) return;
      _settings.windowBounds = bounds;
      _settings.windowMaximized = false;
    } catch (_) {
      // The window is going away; keep what was saved before.
    }
  }

  @override
  void onWindowMove() => _schedule();

  @override
  void onWindowResize() => _schedule();

  @override
  void onWindowMaximize() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();

  void dispose() {
    _pending?.cancel();
    windowManager.removeListener(this);
  }
}
