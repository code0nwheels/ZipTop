import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/api/api_config.dart';
import '../../core/stores/settings_store.dart';
import '../../dvr/dvr_service.dart';
import '../../dvr/models.dart';
import '../../player/mpv_player.dart';
import '../../theme.dart';

String formatPosition(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Plays a recorded file with ordinary transport controls, and remembers
/// where the viewer stopped.
class RecordingPlayerView extends StatefulWidget {
  const RecordingPlayerView({
    super.key,
    required this.recording,
    required this.fromStart,
    required this.dvr,
    required this.settings,
    required this.config,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.mini,
    required this.onToggleMini,
    required this.onClose,
  });

  final Recording recording;
  final bool fromStart;
  final DvrService dvr;
  final SettingsStore settings;
  final ApiConfig config;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// Popped out into the small always-on-top window.
  final bool mini;
  final VoidCallback onToggleMini;
  final VoidCallback onClose;

  @override
  State<RecordingPlayerView> createState() => _RecordingPlayerViewState();
}

class _RecordingPlayerViewState extends State<RecordingPlayerView> {
  static const seekStep = Duration(seconds: 30);
  static const controlsLinger = Duration(seconds: 3);

  late final MpvPlayer _mpv = MpvPlayer(config: widget.config);
  final _focus = FocusNode(debugLabel: 'recording-player');
  final _subs = <StreamSubscription<dynamic>>[];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = true;
  bool _ended = false;
  bool _controls = true;
  double? _dragging;
  Timer? _controlsTimer;
  String? _error;

  Player get _player => _mpv.player;

  @override
  void initState() {
    super.initState();
    final resume = Duration(milliseconds: widget.recording.resumePositionMs);
    final path = widget.recording.filePath;
    if (path == null) {
      _error = 'The recording file is missing.';
    } else {
      unawaited(
        _mpv
            .playFile(path, start: widget.fromStart ? null : resume)
            .then((_) => _player.setVolume(widget.settings.volume)),
      );
    }
    _subs.addAll([
      _player.stream.position.listen((p) {
        if (mounted && _dragging == null) setState(() => _position = p);
      }),
      _player.stream.duration.listen((d) {
        if (mounted) setState(() => _duration = d);
      }),
      _player.stream.playing.listen((p) {
        if (mounted) setState(() => _playing = p);
      }),
      _player.stream.completed.listen((done) {
        if (mounted && done) setState(() => _ended = true);
      }),
      _player.stream.error.listen((message) {
        if (mounted && isReloadableError(message) && _duration == Duration.zero) {
          setState(() => _error = "This recording can't be played. $message");
        }
      }),
    ]);
    _touch();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    // Finished, or stopped within ten seconds of the end: start over next time.
    final nearEnd = _ended ||
        (_duration > Duration.zero && _duration - _position < const Duration(seconds: 10));
    widget.dvr.saveResumePosition(widget.recording.id, nearEnd ? Duration.zero : _position);
    _focus.dispose();
    unawaited(_mpv.dispose());
    super.dispose();
  }

  void _touch() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(controlsLinger, () {
      if (mounted && _playing) setState(() => _controls = false);
    });
    if (!_controls && mounted) setState(() => _controls = true);
  }

  void _seekBy(Duration delta) {
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    setState(() {
      _position = target;
      _ended = false;
    });
    unawaited(_player.seek(target));
    _touch();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      unawaited(_player.playOrPause());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-seekStep);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(seekStep);
    } else if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      widget.onToggleFullscreen();
    } else if (key == LogicalKeyboardKey.keyP) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      widget.onToggleMini();
    } else if (key == LogicalKeyboardKey.escape) {
      if (widget.mini) {
        widget.onToggleMini();
      } else if (widget.fullscreen) {
        widget.onToggleFullscreen();
      } else {
        widget.onClose();
      }
    } else {
      return KeyEventResult.ignored;
    }
    _touch();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    final max = _duration.inMilliseconds.toDouble();
    final value = (_dragging ?? _position.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 0.0 : max);
    final showControls = _controls || !_playing || _error != null;

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: showControls ? SystemMouseCursors.basic : SystemMouseCursors.none,
        onHover: (_) => _touch(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _focus.requestFocus();
            _touch();
          },
          // Popped out, a double-click goes back to the full window.
          onDoubleTap: widget.mini ? widget.onToggleMini : widget.onToggleFullscreen,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: _mpv.controller, controls: NoVideoControls, fill: Colors.black),
                if (_error != null)
                  ColoredBox(
                    color: ZipColors.overlayPlayer,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: showControls ? 1 : 0,
                  duration: ZipMotion.fast,
                  child: IgnorePointer(
                    ignoring: !showControls,
                    child: Column(
                      children: [
                        if (!widget.mini)
                          Container(
                            padding: const EdgeInsets.fromLTRB(8, 8, 16, 32),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xD9000000), Color(0x66000000), Colors.transparent],
                                stops: [0, 0.5, 1],
                              ),
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: 'Back to recordings (Esc)',
                                  onPressed: widget.onClose,
                                  icon: const Icon(Icons.arrow_back),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(
                                      text: r.title,
                                      children: [
                                        TextSpan(
                                          text: '   ${r.streamName}',
                                          style: const TextStyle(
                                            color: ZipColors.textSecondary,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 40, 12, 8),
                          decoration: const BoxDecoration(
                            // The web player's scrim: .85 black at the bottom, .4 halfway.
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0xD9000000), Color(0x66000000), Colors.transparent],
                              stops: [0, 0.5, 1],
                            ),
                          ),
                          child: Row(
                            children: [
                              if (!widget.mini)
                                IconButton(
                                  tooltip: 'Back 30 seconds (Left)',
                                  onPressed: () => _seekBy(-seekStep),
                                  icon: const Icon(Icons.replay_30),
                                ),
                              IconButton(
                                tooltip: _playing ? 'Pause (Space)' : 'Play (Space)',
                                iconSize: 28,
                                style: IconButton.styleFrom(
                                  backgroundColor: ZipColors.accent,
                                  foregroundColor: ZipColors.onAccent,
                                  hoverColor: ZipColors.accentHi,
                                  fixedSize: const Size(48, 48),
                                ),
                                onPressed: _player.playOrPause,
                                icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                              ),
                              if (!widget.mini)
                                IconButton(
                                  tooltip: 'Forward 30 seconds (Right)',
                                  onPressed: () => _seekBy(seekStep),
                                  icon: const Icon(Icons.forward_30),
                                ),
                              const SizedBox(width: 8),
                              Text(
                                formatPosition(Duration(milliseconds: value.round())),
                                style: ZipText.mono(fontSize: 13, color: ZipColors.text),
                              ),
                              Expanded(
                                child: Slider(
                                  value: value,
                                  max: max <= 0 ? 1 : max,
                                  onChanged: max <= 0
                                      ? null
                                      : (v) {
                                          setState(() => _dragging = v);
                                          _touch();
                                        },
                                  onChangeEnd: (v) {
                                    final target = Duration(milliseconds: v.round());
                                    setState(() {
                                      _dragging = null;
                                      _position = target;
                                      _ended = false;
                                    });
                                    unawaited(_player.seek(target));
                                  },
                                ),
                              ),
                              Text(
                                _duration == Duration.zero ? '--:--' : formatPosition(_duration),
                                style: ZipText.mono(fontSize: 13),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: widget.mini ? 'Back to full window (P)' : 'Pop out (P)',
                                onPressed: widget.onToggleMini,
                                icon: Icon(
                                  widget.mini ? Icons.open_in_full : Icons.picture_in_picture_alt,
                                ),
                              ),
                              IconButton(
                                tooltip: widget.fullscreen ? 'Exit full screen (Esc)' : 'Full screen (F)',
                                onPressed: widget.onToggleFullscreen,
                                icon: Icon(
                                  widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
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
