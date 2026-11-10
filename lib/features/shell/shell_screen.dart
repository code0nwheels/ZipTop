import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../player/mpv_player.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../live/channel_panel.dart';
import '../live/live_controller.dart';
import '../live/video_pane.dart';
import '../settings/settings_dialog.dart';

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

class _ShellScreenState extends ConsumerState<ShellScreen> with WindowListener {
  static const _panelWidth = 540.0;
  static const _controlsLinger = Duration(seconds: 3);

  late final CatalogStore _catalog;
  late final SettingsStore _settings;
  late final PlaybackSession _session;
  late final MpvPlayer _player;
  late final LiveController _live;

  final _focus = FocusNode(debugLabel: 'shell');
  final _searchFocus = FocusNode(debugLabel: 'search');
  final _search = TextEditingController();

  String? _categoryId;
  String? _bootError;
  bool _booting = true;
  bool _closing = false;
  bool _fullscreen = false;
  bool _panelOpen = true;
  bool _edgePanel = false;
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _catalog = ref.read(catalogStoreProvider);
    _settings = ref.read(settingsStoreProvider);
    _session = PlaybackSession(ref.read(streamsApiProvider));
    _player = MpvPlayer(config: ref.read(apiConfigProvider));
    _live = LiveController(
      catalog: _catalog,
      settings: _settings,
      session: _session,
      player: _player,
    );
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    unawaited(_boot());
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _bootError = null;
    });
    try {
      await _live.boot();
      // Open on Favorites when the viewer has some, like the Android guide.
      final favorites = _catalog.category(CategoryIds.favorites);
      if (_categoryId == null && favorites != null && !favorites.hidden) {
        if (_catalog.channelsIn(favorites).isNotEmpty) _categoryId = favorites.id;
      }
    } catch (e) {
      _bootError = "Couldn't load channels. $e";
    }
    if (mounted) setState(() => _booting = false);
  }

  /// Releases the server slot before the window goes away.
  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _live.shutdown().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Closing regardless.
    }
    await windowManager.destroy();
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
    _touchControls();
  }

  Future<void> _setFullscreen(bool value) async {
    await windowManager.setFullScreen(value);
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
    await ref.read(tokenStoreProvider).clear();
    _catalog.clear();
    _settings.clearHistory();
    widget.onSignedOut();
  }

  void _tune(Channel channel, List<Channel> scope, String scopeName) {
    _focus.requestFocus();
    if (_edgePanel) setState(() => _edgePanel = false);
    unawaited(_live.tune(channel, scope: scope, scopeName: scopeName));
  }

  void _focusSearch() {
    if (_fullscreen) {
      setState(() => _edgePanel = true);
    } else if (!_panelOpen) {
      setState(() => _panelOpen = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
    });
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        settings: _settings,
        catalog: _catalog,
        authApi: ref.read(authApiProvider),
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

    // While typing in a text field only Escape is ours: it hands focus back.
    final typing = FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    if (typing) {
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
      } else {
        return KeyEventResult.ignored;
      }
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
    unawaited(windowManager.setPreventClose(false));
    _controlsTimer?.cancel();
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
          listenable: Listenable.merge([_live, _catalog, _settings]),
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
            );

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
                    left: _edgePanel ? 0 : -_panelWidth,
                    top: 0,
                    bottom: 0,
                    width: _panelWidth,
                    child: MouseRegion(
                      onExit: (_) {
                        if (!_searchFocus.hasFocus) setState(() => _edgePanel = false);
                      },
                      child: Material(elevation: 12, child: panel),
                    ),
                  ),
                ],
              );
            }

            return Row(
              children: [
                _NavRail(
                  panelOpen: _panelOpen,
                  onTogglePanel: () => setState(() => _panelOpen = !_panelOpen),
                  onSearch: _focusSearch,
                  onSettings: _openSettings,
                ),
                if (_panelOpen) SizedBox(width: _panelWidth, child: panel),
                Expanded(child: video),
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
    required this.panelOpen,
    required this.onTogglePanel,
    required this.onSearch,
    required this.onSettings,
  });

  final bool panelOpen;
  final VoidCallback onTogglePanel;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      color: ZipColors.background,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Image.asset('assets/icon.png', width: 36, height: 36),
          ),
          const SizedBox(height: 16),
          IconButton(
            tooltip: panelOpen ? 'Hide channels' : 'Show channels',
            isSelected: panelOpen,
            onPressed: onTogglePanel,
            icon: const Icon(Icons.live_tv_outlined),
            selectedIcon: const Icon(Icons.live_tv, color: ZipColors.accent),
          ),
          IconButton(
            tooltip: 'Search (Ctrl+F)',
            onPressed: onSearch,
            icon: const Icon(Icons.search),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Settings',
            onPressed: onSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }
}
