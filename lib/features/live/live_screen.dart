import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../player/mpv_player.dart';
import '../../providers.dart';
import '../../theme.dart';
import 'live_controller.dart';

/// Phase 1 player: the channel list beside the video. The full desktop shell
/// (sidebar, categories, guide, fullscreen OSD) replaces this in Phase 2.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key, required this.onSignedOut});

  final VoidCallback onSignedOut;

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> with WindowListener {
  late final CatalogStore _catalog;
  late final PlaybackSession _session;
  late final MpvPlayer _player;
  late final LiveController _live;
  final _focus = FocusNode(debugLabel: 'live');
  String? _bootError;
  bool _booting = true;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _catalog = ref.read(catalogStoreProvider);
    _session = PlaybackSession(ref.read(streamsApiProvider));
    _player = MpvPlayer(config: ref.read(apiConfigProvider));
    _live = LiveController(catalog: _catalog, session: _session, player: _player);
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

  Future<void> _signOut() async {
    await _live.shutdown();
    await ref.read(tokenStoreProvider).clear();
    _catalog.clear();
    widget.onSignedOut();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp) {
      unawaited(_live.zap(-1));
    } else if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.pageDown) {
      unawaited(_live.zap(1));
    } else if (key == LogicalKeyboardKey.backspace) {
      unawaited(_live.tunePrevious());
    } else if (key == LogicalKeyboardKey.space) {
      unawaited(_player.player.playOrPause());
    } else if (key == LogicalKeyboardKey.keyM) {
      final muted = _player.player.state.volume == 0;
      unawaited(_player.player.setVolume(muted ? 100 : 0));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    unawaited(windowManager.setPreventClose(false));
    _focus.dispose();
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
          listenable: Listenable.merge([_live, _catalog]),
          builder: (context, _) {
            if (_booting && !_catalog.isLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            if (_bootError != null && !_catalog.isLoaded) {
              return _Notice(
                message: _bootError!,
                action: 'Retry',
                onAction: _boot,
              );
            }
            return Row(
              children: [
                SizedBox(
                  width: 320,
                  child: _ChannelPanel(
                    catalog: _catalog,
                    current: _live.current,
                    onTune: (c) {
                      _focus.requestFocus();
                      unawaited(_live.tune(c));
                    },
                    onSignOut: _signOut,
                  ),
                ),
                Expanded(child: _VideoPane(live: _live, player: _player)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ChannelPanel extends StatelessWidget {
  const _ChannelPanel({
    required this.catalog,
    required this.current,
    required this.onTune,
    required this.onSignOut,
  });

  final CatalogStore catalog;
  final Channel? current;
  final ValueChanged<Channel> onTune;
  final VoidCallback onSignOut;

  Color _stateColor(String state) => switch (state) {
        'running' || 'paused' => ZipColors.live,
        'retrying' => ZipColors.retrying,
        'unavailable' => ZipColors.offline,
        _ => ZipColors.textMuted,
      };

  @override
  Widget build(BuildContext context) {
    final channels = catalog.allChannels;
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: ZipColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: [
                Image.asset('assets/logo.png', height: 26),
                const Spacer(),
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: onSignOut,
                  icon: const Icon(Icons.logout, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: channels.length,
              itemExtent: 58,
              itemBuilder: (context, index) {
                final channel = channels[index];
                final selected = channel.id == current?.id;
                final title = channel.nowPlaying?.title;
                return Material(
                  color: selected ? ZipColors.surfaceHigh : Colors.transparent,
                  child: InkWell(
                    onTap: () => onTune(channel),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              channel.number?.toString() ?? '',
                              style: text.bodyMedium?.copyWith(color: ZipColors.textMuted),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  channel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyLarge?.copyWith(
                                    color: selected ? ZipColors.accent : ZipColors.text,
                                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                                if (title != null && title.isNotEmpty)
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall
                                        ?.copyWith(color: ZipColors.textSecondary),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: catalog.stateOf(channel),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _stateColor(catalog.stateOf(channel)),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoPane extends StatelessWidget {
  const _VideoPane({required this.live, required this.player});

  final LiveController live;
  final MpvPlayer player;

  @override
  Widget build(BuildContext context) {
    final session = live.session;
    final channel = live.current;
    final warning = session.warningSeconds;

    Widget? overlay;
    if (live.failure != null) {
      overlay = _Notice(message: live.failure!, action: 'Retry', onAction: live.retryNow);
    } else {
      overlay = switch (session.phase) {
        SessionPhase.preparing => const Center(child: CircularProgressIndicator()),
        SessionPhase.failed => _Notice(
            message: session.message ?? 'Could not start this channel.',
            action: 'Retry',
            onAction: live.retryNow,
          ),
        SessionPhase.streamLimit => _Notice(
            message: session.message ?? 'Stream limit reached.',
            action: 'Try again',
            onAction: live.retryNow,
          ),
        SessionPhase.watchTimeUp => _Notice(
            message: session.message ?? 'Watch time limit reached.',
            action: 'Keep watching',
            onAction: () {
              session.extendWatch();
              unawaited(live.retryNow());
            },
          ),
        SessionPhase.idle => channel == null
            ? const _Notice(message: 'Pick a channel to start watching.')
            : null,
        SessionPhase.playing => null,
      };
    }

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: player.controller, controls: NoVideoControls),
          if (channel != null)
            Positioned(
              left: 16,
              top: 12,
              child: Text(
                [
                  if (channel.number != null) '${channel.number}',
                  channel.name,
                ].join('  ·  '),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                ),
              ),
            ),
          if (overlay != null) ColoredBox(color: Colors.black54, child: overlay),
          if (warning != null)
            Center(
              child: Card(
                color: ZipColors.surface,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Are you still watching?',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text('Playback stops in $warning s'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: session.extendWatch,
                        child: const Text('Keep watching'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.action, this.onAction});

  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
