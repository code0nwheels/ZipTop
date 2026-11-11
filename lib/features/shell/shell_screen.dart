import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/models/catalog.dart';
import '../../core/platform/app_channel.dart';
import '../../core/platform/tray.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/guide_repository.dart';
import '../../core/stores/settings_store.dart';
import '../../dvr/dvr_service.dart';
import '../../dvr/models.dart';
import '../../player/mpv_player.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../ui/typing.dart';
import '../guide/guide_view.dart';
import '../live/channel_panel.dart';
import '../live/live_controller.dart';
import '../live/video_pane.dart';
import '../multiview/multiview_controller.dart';
import '../multiview/multiview_view.dart';
import '../recordings/record_actions.dart';
import '../recordings/recording_player.dart';
import '../recordings/recordings_view.dart';
import '../settings/settings_dialog.dart';
import '../update/update_dialog.dart';
import '../update/update_service.dart';

/// The signed-in app: a slim navigation rail, the channel panel and the video.
///
/// In full screen only the video shows; moving the mouse brings the controls
/// back, and the left edge slides the channel panel over the picture.
class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key, required this.onSignedOut});

  final VoidCallback onSignedOut;

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

enum _View { live, guide, multiview, recordings }

class _ShellScreenState extends ConsumerState<ShellScreen> with WindowListener, TrayListener {
  static const _categoriesWidth = 190.0;
  static const _channelsWidth = 350.0;
  static const _controlsLinger = Duration(seconds: 3);

  late final CatalogStore _catalog;
  late final SettingsStore _settings;
  late final GuideRepository _guide;
  late final PlaybackSession _session;
  late final MpvPlayer _player;
  late final LiveController _live;
  late final MultiviewController _multi;
  late final DvrService _dvr;
  late final UpdateService _updates;

  final _focus = FocusNode(debugLabel: 'shell');
  final _searchFocus = FocusNode(debugLabel: 'search');
  final _search = TextEditingController();

  String? _categoryId;
  String? _bootError;
  bool _booting = true;
  bool _closing = false;
  bool _inTray = false;

  /// Minimized in place of hiding, on a Linux desktop with no tray to hide in.
  bool _minimizedNoTray = false;

  /// Out of sight with live playback stopped, in the tray or minimized.
  bool get _hiddenAway => _inTray || _minimizedNoTray;
  bool _startedHidden = false;
  Timer? _bootRetry;
  bool _liveSuspended = false;
  Recording? _playing;
  bool _playingFromStart = false;
  _View _view = _View.live;
  bool _fullscreen = false;
  bool _maximizedBeforeFullscreen = false;
  bool _edgePanel = false;
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _catalog = ref.read(catalogStoreProvider);
    _settings = ref.read(settingsStoreProvider);
    _guide = ref.read(guideRepositoryProvider);
    final slots = ref.read(streamSlotsProvider);
    _dvr = ref.read(dvrServiceProvider);
    _updates = ref.read(updateServiceProvider);
    _session = PlaybackSession(ref.read(streamsApiProvider), slots: slots);
    _player = MpvPlayer(config: ref.read(apiConfigProvider));
    _live = LiveController(
      catalog: _catalog,
      settings: _settings,
      session: _session,
      player: _player,
    );
    _multi = MultiviewController(
      catalog: _catalog,
      settings: _settings,
      api: ref.read(streamsApiProvider),
      config: ref.read(apiConfigProvider),
      slots: slots,
    );
    // Volume changes reach whichever multiview tile has the audio.
    _settings.addListener(_multi.refreshAudio);
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    // macOS: Cmd+Q, the app menu's Quit, or logging out. With the window
    // showing, the same as closing it; from the menu bar nobody would see the
    // keep-running question, so just quit.
    AppChannel.listen(onQuitRequested: () async => _hiddenAway ? _quit() : onWindowClose());
    unawaited(_boot());
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _bootError = null;
    });
    // Recordings do not need the channel list, so the recorder starts first:
    // at sign-in the network may not be up yet.
    _dvr.start();
    final startHidden = ref.read(startHiddenProvider) && !_startedHidden;
    if (startHidden) {
      // Started at sign-in: go straight to the notification area (menu bar).
      _startedHidden = true;
      await _hideToTray();
    }
    _bootRetry?.cancel();
    try {
      await _live.boot(autoplay: !_hiddenAway);
      if (!_hiddenAway) unawaited(_autoCheckForUpdate());
      // Open on Favorites when the viewer has some, like the Android guide.
      final favorites = _catalog.category(CategoryIds.favorites);
      if (_categoryId == null && favorites != null && !favorites.hidden) {
        if (_catalog.channelsIn(favorites).isNotEmpty) _categoryId = favorites.id;
      }
    } catch (e) {
      _bootError = "Couldn't load channels. $e";
      // Nobody is looking at the Retry button while hidden; keep trying.
      if (_hiddenAway && mounted) _bootRetry = Timer(const Duration(seconds: 30), _boot);
    }
    if (mounted) setState(() => _booting = false);
    // Debug builds only: open straight into a view, for testing from scripts.
    final startView = Platform.environment['ZIPTOP_START_VIEW'];
    if (kDebugMode && mounted && startView != null) {
      for (final view in _View.values) {
        if (view.name == startView && view != _View.live) _showView(view);
      }
    }
    // Debug builds only: record the current channel for this many seconds.
    final debugRecord = int.tryParse(Platform.environment['ZIPTOP_DEBUG_RECORD'] ?? '');
    final current = _live.current;
    if (kDebugMode && mounted && debugRecord != null && current != null) {
      _dvr.scheduleFromNow(recordTargetOf(current), length: Duration(seconds: debugRecord));
    }
  }

  /// With recordings scheduled or running, closing the window (or quitting
  /// on macOS) offers to keep ZipTop in the notification area or menu bar so
  /// they still happen.
  @override
  void onWindowClose() async {
    if (_closing) return;
    if (_dvr.hasPendingWork) {
      final keep = await _askKeepRunning();
      if (keep == null) return;
      if (keep) {
        await _hideToTray();
        return;
      }
    }
    await _quit();
  }

  Future<bool?> _askKeepRunning() {
    final recording = _dvr.store.active.length;
    final scheduled = _dvr.store.scheduled.length;
    final what = [
      if (recording > 0) '$recording recording${recording == 1 ? '' : 's'} in progress',
      if (scheduled > 0) '$scheduled scheduled',
    ].join(' and ');
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep ZipTop running?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(
            'You have $what. Recordings only happen while ZipTop is running.\n\n'
            'Keep it in the $trayPlaceName, or quit and '
            '${recording > 0 ? 'stop recording' : 'miss them'}?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Quit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Keep running'),
          ),
        ],
      ),
    );
  }

  /// Releases every server slot, closes any recording file, then exits. The
  /// window goes at once; the rest happens behind it.
  Future<void> _quit() async {
    if (_closing) return;
    _closing = true;
    await windowManager.hide();
    try {
      await Future.wait([_live.shutdown(), _multi.closeAll(), _dvr.stopAll()])
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Closing regardless.
    }
    if (_inTray) {
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
    await AppChannel.allowTerminate();
    await windowManager.destroy();
  }

  /// Hides the window and stops what was being watched; recordings carry on.
  Future<void> _hideToTray() async {
    if (_fullscreen) await _setFullscreen(false);
    if (!await hasTrayHost()) {
      // No tray on this Linux desktop: an icon would be invisible, so
      // minimize instead and stay reachable from the taskbar or dock.
      // Started at sign-in, the window has never been shown: iconify first
      // so it maps straight onto the taskbar, then make sure it is mapped.
      await windowManager.minimize();
      if (!await windowManager.isVisible()) {
        await windowManager.show();
        await windowManager.minimize();
      }
      _minimizedNoTray = true;
      await _leaveForBackground();
      return;
    }
    await windowManager.hide();
    _inTray = true;
    try {
      // macOS: no Dock icon while in the menu bar, like other menu bar apps.
      if (Platform.isMacOS) await windowManager.setSkipTaskbar(true);
      await trayManager.setIcon(trayIconAsset, isTemplate: trayIconIsTemplate);
      await trayManager.setToolTip('ZipTop');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open ZipTop'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit ZipTop'),
          ],
        ),
      );
    } catch (_) {
      // No tray icon: bring the window back rather than leave no way in.
      _inTray = false;
      if (Platform.isMacOS) await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      return;
    }
    await _leaveForBackground();
  }

  /// Stops what was being watched once the window is out of sight.
  Future<void> _leaveForBackground() async {
    if (!mounted) return;
    final wasMultiview = _view == _View.multiview;
    setState(() {
      _view = _View.live;
      _playing = null;
    });
    if (wasMultiview) await _multi.closeAll();
    await _suspendLive();
  }

  Future<void> _restoreFromTray() async {
    if (!_inTray) return;
    _inTray = false;
    try {
      await trayManager.destroy();
    } catch (_) {}
    if (Platform.isMacOS) await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    await _resumeFromBackground();
  }

  Future<void> _resumeFromBackground() async {
    if (mounted && _liveSuspended && _view == _View.live) {
      _liveSuspended = false;
      await _live.resume();
    }
  }

  /// Brought back from the taskbar after minimizing in place of the tray.
  void _restoreFromMinimized() {
    if (!_minimizedNoTray) return;
    _minimizedNoTray = false;
    unawaited(_resumeFromBackground());
  }

  @override
  void onWindowRestore() => _restoreFromMinimized();

  @override
  void onTrayIconMouseDown() => unawaited(_restoreFromTray());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') {
      unawaited(_restoreFromTray());
    } else if (menuItem.key == 'quit') {
      unawaited(_quit());
    }
  }

  @override
  void onWindowEnterFullScreen() => _syncFullscreen(true);

  @override
  void onWindowLeaveFullScreen() => _syncFullscreen(false);

  void _syncFullscreen(bool value) {
    if (!mounted || _fullscreen == value) return;
    setState(() {
      _fullscreen = value;
      _edgePanel = false;
    });
    // Only the video, multiview and a playing recording have a full-screen form.
    if (value &&
        (_view == _View.guide || (_view == _View.recordings && _playing == null))) {
      _showView(_View.live);
    }
    _touchControls();
  }

  Future<void> _setFullscreen(bool value) async {
    // Windows: window_manager leaves the title bar showing when it goes full
    // screen from a maximized window (it only drops the frame for a normal
    // one). Restore the window first and maximize it again on the way out.
    if (Platform.isWindows && value && !_fullscreen && await windowManager.isMaximized()) {
      _maximizedBeforeFullscreen = true;
      // unmaximize() only posts the restore; wait until it has happened.
      await windowManager.unmaximize();
      for (var i = 0; i < 40 && await windowManager.isMaximized(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    await windowManager.setFullScreen(value);
    if (!value && _maximizedBeforeFullscreen) {
      _maximizedBeforeFullscreen = false;
      await windowManager.maximize();
    }
    _syncFullscreen(value);
    _focus.requestFocus();
  }

  /// Shows the video controls and restarts their hide timer.
  void _touchControls() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(_controlsLinger, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
  }

  Future<void> _signOut() async {
    if (_fullscreen) await _setFullscreen(false);
    await _live.shutdown();
    await _multi.closeAll();
    await _dvr.stopAll();
    await ref.read(tokenStoreProvider).clear();
    _catalog.clear();
    _guide.clear();
    _settings.clearHistory();
    widget.onSignedOut();
  }

  void _tune(Channel channel, List<Channel> scope, String scopeName) {
    _focus.requestFocus();
    if (_edgePanel) setState(() => _edgePanel = false);
    unawaited(_live.tune(channel, scope: scope, scopeName: scopeName));
  }

  /// Shows or hides the channel panel. In full screen that is the slide-over.
  void _togglePanel() {
    if (_fullscreen) {
      setState(() => _edgePanel = !_edgePanel);
    } else if (_view != _View.live) {
      _showView(_View.live);
      _settings.panelOpen = true;
    } else {
      _settings.panelOpen = !_settings.panelOpen;
    }
    _focus.requestFocus();
  }

  void _showView(_View view) {
    if (_view == view) return;
    final from = _view;
    setState(() {
      _view = view;
      _playing = null;
    });
    unawaited(_transition(from, view));
    _focus.requestFocus();
    _touchControls();
  }

  /// Hands the stream slot between the single player and whatever replaces
  /// it. The single player stops for multiview and for recording playback,
  /// and comes back with the video or the guide (which previews it).
  Future<void> _transition(_View from, _View to) async {
    if (from == _View.multiview) await _multi.closeAll();
    if (to == _View.multiview) {
      final seed = _live.current;
      await _suspendLive();
      if (!mounted || _view != _View.multiview) return;
      _multi.enter(seed: seed);
      return;
    }
    if ((to == _View.live || to == _View.guide) && _liveSuspended && mounted && _view == to) {
      _liveSuspended = false;
      await _live.resume();
    }
  }

  Future<void> _suspendLive() async {
    _liveSuspended = true;
    await _live.suspend();
  }

  void _playRecording(Recording recording, {bool fromStart = false}) {
    setState(() {
      _playing = recording;
      _playingFromStart = fromStart;
    });
    unawaited(_suspendLive());
  }

  void _closeRecording() {
    if (_fullscreen) unawaited(_setFullscreen(false));
    setState(() => _playing = null);
    _focus.requestFocus();
  }

  /// R: stop a recording of this channel, or record what is on.
  void _quickRecord() {
    final channel = _live.current;
    if (channel == null) return;
    final active = _dvr.activeOn(channel.id);
    if (active != null) {
      _dvr.cancel(active.id);
      return;
    }
    final target = recordTargetOf(channel);
    final programme = currentProgrammeOf(channel);
    if (programme != null) {
      unawaited(recordProgramme(context, _dvr, target, programme));
    } else {
      unawaited(recordNextHour(context, _dvr, target));
    }
  }

  KeyEventResult _onRecordingsKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.escape) {
      if (_playing != null) {
        _closeRecording();
      } else {
        _showView(_View.live);
      }
    } else if (key == LogicalKeyboardKey.keyG && !_fullscreen) {
      _showView(_View.guide);
    } else if (key == LogicalKeyboardKey.keyV && !_fullscreen) {
      _showView(_View.multiview);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onMultiviewKey(LogicalKeyboardKey key) {
    final digit = _digitKeys[key];
    final tiles = _multi.tiles;
    final selected = _multi.selected;
    if (digit != null) {
      if (digit >= 1 && digit <= tiles.length) _multi.select(tiles[digit - 1]);
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp) {
      _multi.selectRelative(-1);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown) {
      _multi.selectRelative(1);
    } else if (key == LogicalKeyboardKey.keyM) {
      unawaited(_live.toggleMute());
    } else if (key == LogicalKeyboardKey.space) {
      if (selected != null) _multi.togglePause(selected);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (selected != null && tiles.length > 1) _multi.toggleFullTile(selected);
    } else if (key == LogicalKeyboardKey.delete) {
      if (selected != null) _multi.remove(selected);
    } else if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      unawaited(_setFullscreen(!_fullscreen));
    } else if (key == LogicalKeyboardKey.escape) {
      if (_multi.fullTile != null) {
        _multi.exitFullTile();
      } else if (_fullscreen) {
        unawaited(_setFullscreen(false));
      } else {
        _showView(_View.live);
      }
    } else if (key == LogicalKeyboardKey.keyV) {
      if (_fullscreen) return KeyEventResult.ignored;
      _showView(_View.live);
    } else if (key == LogicalKeyboardKey.keyG) {
      if (_fullscreen) return KeyEventResult.ignored;
      _showView(_View.guide);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// From the guide: tune and go back to the video.
  void _tuneFromGuide(Channel channel) {
    _showView(_View.live);
    unawaited(_live.tune(channel));
  }

  void _focusSearch() {
    _showView(_View.live);
    if (_fullscreen) {
      setState(() => _edgePanel = true);
    } else if (!_settings.panelOpen) {
      _settings.panelOpen = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
    });
  }

  Future<void> _autoCheckForUpdate() async {
    final update = await _updates.autoCheck();
    if (update != null && mounted && !_hiddenAway) await _offerUpdate(update);
  }

  Future<void> _offerUpdate(UpdateInfo update) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(
        service: _updates,
        update: update,
        onInstall: _quit,
      ),
    );
    _focus.requestFocus();
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        settings: _settings,
        catalog: _catalog,
        authApi: ref.read(authApiProvider),
        updates: _updates,
        startup: ref.read(startupRegistrationProvider),
        onUpdate: (update) {
          Navigator.of(context).pop();
          unawaited(_offerUpdate(update));
        },
        onSignOut: () {
          Navigator.of(context).pop();
          unawaited(_signOut());
        },
      ),
    );
    _focus.requestFocus();
  }

  static final _digitKeys = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.digit0: 0,
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad0: 0,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;

    if (keyboard.isControlPressed && key == LogicalKeyboardKey.keyF) {
      _focusSearch();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.keyB) {
      _togglePanel();
      return KeyEventResult.handled;
    }

    // While typing in a text field only Escape is ours: it hands focus back.
    if (isTypingInTextField()) {
      if (key == LogicalKeyboardKey.escape) {
        _focus.requestFocus();
        if (_edgePanel) setState(() => _edgePanel = false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    if (_view == _View.multiview) return _onMultiviewKey(key);
    if (_view == _View.recordings) return _onRecordingsKey(key);

    final digit = _digitKeys[key];
    if (digit != null) {
      _live.typeDigit(digit);
      return KeyEventResult.handled;
    }

    if (_live.numberEntry.isNotEmpty) {
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
        _live.commitNumber();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
        _live.cancelNumber();
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp) {
      unawaited(_live.zap(-1));
    } else if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.pageDown) {
      unawaited(_live.zap(1));
    } else if (key == LogicalKeyboardKey.backspace) {
      unawaited(_live.tunePrevious());
    } else if (key == LogicalKeyboardKey.space) {
      unawaited(_player.player.playOrPause());
    } else if (key == LogicalKeyboardKey.keyM) {
      unawaited(_live.toggleMute());
    } else if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      unawaited(_setFullscreen(!_fullscreen));
    } else if (key == LogicalKeyboardKey.escape) {
      if (_edgePanel) {
        setState(() => _edgePanel = false);
      } else if (_fullscreen) {
        unawaited(_setFullscreen(false));
      } else if (_view == _View.guide) {
        _showView(_View.live);
      } else {
        return KeyEventResult.ignored;
      }
    } else if (key == LogicalKeyboardKey.keyG) {
      if (_fullscreen) return KeyEventResult.ignored;
      _showView(_view == _View.guide ? _View.live : _View.guide);
    } else if (key == LogicalKeyboardKey.keyV) {
      if (_fullscreen) return KeyEventResult.ignored;
      _showView(_View.multiview);
    } else if (key == LogicalKeyboardKey.keyR) {
      _quickRecord();
    } else if (key == LogicalKeyboardKey.keyI) {
      // Info: show the controls with what's on.
    } else {
      return KeyEventResult.ignored;
    }
    _touchControls();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    AppChannel.stopListening();
    unawaited(windowManager.setPreventClose(false));
    _controlsTimer?.cancel();
    _bootRetry?.cancel();
    _settings.removeListener(_multi.refreshAudio);
    _multi.dispose();
    _focus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _live.dispose();
    _session.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: ListenableBuilder(
          listenable: Listenable.merge([_live, _catalog, _settings, _dvr, _updates.available]),
          builder: (context, _) {
            if (_booting && !_catalog.isLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            if (_bootError != null && !_catalog.isLoaded) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_bootError!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _boot, child: const Text('Retry')),
                  ],
                ),
              );
            }

            final video = VideoPane(
              live: _live,
              dvr: _dvr,
              guide: _guide,
              fullscreen: _fullscreen,
              controlsVisible: _controlsVisible,
              onActivity: _touchControls,
              onToggleFullscreen: () => _setFullscreen(!_fullscreen),
            );
            final panel = ChannelPanel(
              live: _live,
              selectedCategoryId: _categoryId,
              onSelectCategory: (id) => setState(() => _categoryId = id),
              searchController: _search,
              searchFocus: _searchFocus,
              onTune: _tune,
              showCategories: _settings.categoriesOpen,
              categoriesWidth: _categoriesWidth,
              onToggleCategories: () =>
                  _settings.categoriesOpen = !_settings.categoriesOpen,
              onHide: _togglePanel,
            );
            final panelWidth =
                _channelsWidth + (_settings.categoriesOpen ? _categoriesWidth : 0);
            final panelOpen = _settings.panelOpen;

            final multiview = MultiviewView(
              controller: _multi,
              fullscreen: _fullscreen,
              onToggleFullscreen: () => _setFullscreen(!_fullscreen),
              onInteraction: _focus.requestFocus,
            );

            final playing = _playing;
            final recordings = playing != null
                ? RecordingPlayerView(
                    key: ValueKey('${playing.id}:$_playingFromStart'),
                    recording: playing,
                    fromStart: _playingFromStart,
                    dvr: _dvr,
                    settings: _settings,
                    config: ref.read(apiConfigProvider),
                    fullscreen: _fullscreen,
                    onToggleFullscreen: () => _setFullscreen(!_fullscreen),
                    onClose: _closeRecording,
                  )
                : RecordingsView(dvr: _dvr, onPlay: _playRecording);

            if (_fullscreen && _view == _View.multiview) return multiview;
            if (_fullscreen && _view == _View.recordings) return recordings;

            if (_fullscreen) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  video,
                  // A sliver at the left edge that slides the channel panel in.
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 6,
                    child: MouseRegion(
                      opaque: false,
                      onEnter: (_) => setState(() => _edgePanel = true),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    left: _edgePanel ? 0 : -panelWidth,
                    top: 0,
                    bottom: 0,
                    width: panelWidth,
                    child: MouseRegion(
                      onExit: (_) {
                        if (!_searchFocus.hasFocus) setState(() => _edgePanel = false);
                      },
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          border: Border(right: BorderSide(color: ZipColors.lineHi)),
                          boxShadow: ZipShadow.lg,
                        ),
                        child: Material(color: ZipColors.surface, child: panel),
                      ),
                    ),
                  ),
                ],
              );
            }

            return Row(
              children: [
                _NavRail(
                  guideOpen: _view == _View.guide,
                  multiviewOpen: _view == _View.multiview,
                  onMultiview: () =>
                      _showView(_view == _View.multiview ? _View.live : _View.multiview),
                  panelOpen: _view == _View.live && panelOpen,
                  onTogglePanel: _togglePanel,
                  onGuide: () => _showView(_view == _View.guide ? _View.live : _View.guide),
                  recordingsOpen: _view == _View.recordings,
                  recordingNow: _dvr.store.active.isNotEmpty,
                  onRecordings: () =>
                      _showView(_view == _View.recordings ? _View.live : _View.recordings),
                  onSearch: _focusSearch,
                  onSettings: _openSettings,
                  update: _updates.available.value,
                  onUpdate: (update) => unawaited(_offerUpdate(update)),
                ),
                if (_view == _View.multiview)
                  Expanded(child: multiview)
                else if (_view == _View.recordings)
                  Expanded(child: recordings)
                else if (_view == _View.guide)
                  Expanded(
                    child: GuideView(
                      repository: _guide,
                      dvr: _dvr,
                      live: _live,
                      onTune: _tuneFromGuide,
                      onBackToVideo: () => _showView(_View.live),
                    ),
                  )
                else ...[
                  if (panelOpen) SizedBox(width: panelWidth, child: panel),
                  Expanded(child: video),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.guideOpen,
    required this.multiviewOpen,
    required this.onMultiview,
    required this.panelOpen,
    required this.onTogglePanel,
    required this.onGuide,
    required this.recordingsOpen,
    required this.recordingNow,
    required this.onRecordings,
    required this.onSearch,
    required this.onSettings,
    required this.update,
    required this.onUpdate,
  });

  final bool guideOpen;
  final bool multiviewOpen;
  final VoidCallback onMultiview;
  final bool panelOpen;
  final VoidCallback onTogglePanel;
  final VoidCallback onGuide;
  final bool recordingsOpen;

  /// Something is being recorded right now.
  final bool recordingNow;
  final VoidCallback onRecordings;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

  /// A newer ZipTop waiting to be installed, if any.
  final UpdateInfo? update;
  final ValueChanged<UpdateInfo> onUpdate;

  @override
  Widget build(BuildContext context) {
    final update = this.update;
    return Container(
      width: 64,
      decoration: const BoxDecoration(
        color: ZipColors.surface,
        border: Border(right: BorderSide(color: ZipColors.line)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          Image.asset('assets/icon.png', width: 34, height: 34),
          const SizedBox(height: 18),
          _RailButton(
            tooltip: panelOpen ? 'Hide channels (Ctrl+B)' : 'Show channels (Ctrl+B)',
            selected: panelOpen,
            onPressed: onTogglePanel,
            icon: Icons.live_tv_outlined,
            selectedIcon: Icons.live_tv,
          ),
          _RailButton(
            tooltip: 'Guide (G)',
            selected: guideOpen,
            onPressed: onGuide,
            icon: Icons.calendar_view_week_outlined,
            selectedIcon: Icons.calendar_view_week,
          ),
          _RailButton(
            tooltip: 'Multi-view (V)',
            selected: multiviewOpen,
            onPressed: onMultiview,
            icon: Icons.grid_view_outlined,
            selectedIcon: Icons.grid_view,
          ),
          _RailButton(
            tooltip: recordingNow ? 'Recordings (recording now)' : 'Recordings',
            selected: recordingsOpen,
            onPressed: onRecordings,
            icon: Icons.video_library_outlined,
            selectedIcon: Icons.video_library,
            dot: recordingNow,
          ),
          _RailButton(
            tooltip: 'Search (Ctrl+F)',
            onPressed: onSearch,
            icon: Icons.search,
          ),
          const Spacer(),
          if (update != null) ...[
            _UpdateButton(update: update, onPressed: () => onUpdate(update)),
            const SizedBox(height: 8),
          ],
          _RailButton(
            tooltip: 'Settings',
            onPressed: onSettings,
            icon: Icons.settings_outlined,
          ),
        ],
      ),
    );
  }
}

/// Stays in the rail while a newer ZipTop is waiting, even after "Later":
/// a green tile with a label and a gently pulsing glow, so it is noticed
/// without getting in the way.
class _UpdateButton extends StatefulWidget {
  const _UpdateButton({required this.update, required this.onPressed});

  final UpdateInfo update;
  final VoidCallback onPressed;

  @override
  State<_UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<_UpdateButton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Update to ZipTop ${widget.update.version}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: ZipRadius.mdAll,
          hoverColor: ZipColors.successDim,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: ZipColors.success,
                      borderRadius: ZipRadius.mdAll,
                      boxShadow: [
                        BoxShadow(
                          color: ZipColors.success.withValues(alpha: 0.15 + 0.35 * _pulse.value),
                          blurRadius: 4 + 8 * _pulse.value,
                          spreadRadius: 1 + 2 * _pulse.value,
                        ),
                      ],
                    ),
                    child: child,
                  ),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.download_rounded, size: 24, color: ZipColors.page),
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Update',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ZipColors.successText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A rail destination: quiet icon that fills with the accent when selected.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.selectedIcon,
    this.selected = false,
    this.dot = false,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final IconData? selectedIcon;
  final bool selected;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      selected ? (selectedIcon ?? icon) : icon,
      size: 22,
      color: selected ? ZipColors.onAccent : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          fixedSize: const Size(44, 44),
          backgroundColor: selected ? ZipColors.accent : Colors.transparent,
          hoverColor: selected ? ZipColors.accentHi : ZipColors.hover,
        ),
        icon: Badge(
          isLabelVisible: dot,
          backgroundColor: ZipColors.danger,
          smallSize: 9,
          child: glyph,
        ),
      ),
    );
  }
}
