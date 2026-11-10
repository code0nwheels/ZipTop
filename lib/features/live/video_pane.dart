import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/guide_repository.dart';
import '../../dvr/dvr_service.dart';
import '../../theme.dart';
import 'channel_panel.dart' show nowPlayingProgress;
import '../recordings/record_actions.dart';
import 'live_controller.dart';

/// The video with everything drawn over it: the control bar, the channel
/// banner, the number-entry pill and the session notices.
class VideoPane extends StatefulWidget {
  const VideoPane({
    super.key,
    required this.live,
    required this.dvr,
    required this.guide,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.onActivity,
    required this.controlsVisible,
  });

  final LiveController live;
  final DvrService dvr;
  final GuideRepository guide;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// Mouse moved or clicked over the video.
  final VoidCallback onActivity;
  final bool controlsVisible;

  @override
  State<VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<VideoPane> {
  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    final session = live.session;
    final channel = live.current;
    final warning = session.warningSeconds;

    Widget? notice;
    if (live.failure != null) {
      notice = _Notice(message: live.failure!, action: 'Retry', onAction: live.retryNow);
    } else {
      notice = switch (session.phase) {
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
        SessionPhase.idle =>
          channel == null ? const _Notice(message: 'Pick a channel to start watching.') : null,
        SessionPhase.playing => null,
      };
    }

    // Controls stay up whenever there is nothing to watch underneath them.
    final showControls = widget.controlsVisible || notice != null;

    return MouseRegion(
      cursor: widget.fullscreen && !showControls
          ? SystemMouseCursors.none
          : SystemMouseCursors.basic,
      onHover: (_) => widget.onActivity(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onActivity,
        onDoubleTap: widget.onToggleFullscreen,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: live.player.controller,
                controls: NoVideoControls,
                fill: Colors.black,
              ),
              if (notice == null)
                StreamBuilder<bool>(
                  stream: live.player.player.stream.buffering,
                  initialData: live.player.player.state.buffering,
                  builder: (context, snapshot) => snapshot.data == true
                      ? const Center(child: CircularProgressIndicator())
                      : const SizedBox.shrink(),
                ),
              if (notice != null) ColoredBox(color: Colors.black54, child: notice),
              if (live.numberEntry.isNotEmpty)
                Positioned(
                  top: 20,
                  right: 24,
                  child: _NumberPill(
                    digits: live.numberEntry,
                    invalid: live.numberEntryInvalid,
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !showControls,
                  child: AnimatedOpacity(
                    opacity: showControls ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: _ControlBar(
                      live: live,
                      dvr: widget.dvr,
                      guide: widget.guide,
                      fullscreen: widget.fullscreen,
                      onToggleFullscreen: widget.onToggleFullscreen,
                    ),
                  ),
                ),
              ),
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
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.live,
    required this.dvr,
    required this.guide,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final LiveController live;
  final DvrService dvr;
  final GuideRepository guide;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final channel = live.current;
    final catalog = live.catalog;
    final player = live.player.player;
    final text = Theme.of(context).textTheme;
    final now = channel?.nowPlaying;
    final progress = nowPlayingProgress(now);
    final favorite = channel != null && catalog.isFavorite(channel.id);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 28, 12, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xE6000000)],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Previous channel in list (Up)',
            onPressed: () => live.zap(-1),
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            tooltip: 'Next channel in list (Down)',
            onPressed: () => live.zap(1),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          IconButton(
            tooltip: 'Last channel (Backspace)',
            onPressed: live.previous == null ? null : live.tunePrevious,
            icon: const Icon(Icons.swap_horiz),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: channel == null
                ? const SizedBox.shrink()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          if (channel.number != null) '${channel.number}',
                          channel.name,
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (now?.title != null && now!.title!.isNotEmpty)
                        Text(
                          now.title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: ZipColors.textSecondary),
                        ),
                      if (progress != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 6),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              backgroundColor: Colors.white24,
                              color: ZipColors.accent,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 8),
                    ],
                  ),
          ),
          if (channel != null)
            IconButton(
              tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => _toggleFavorite(context, channel),
              icon: Icon(
                favorite ? Icons.star : Icons.star_border,
                color: favorite ? ZipColors.retrying : null,
              ),
            ),
          if (channel != null) RecordButton(dvr: dvr, guide: guide, channel: channel),
          StreamBuilder<Tracks>(
            stream: player.stream.tracks,
            initialData: player.state.tracks,
            builder: (context, snapshot) {
              final tracks = snapshot.data ?? player.state.tracks;
              final current = player.state.track;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TrackMenu<VideoTrack>(
                    tooltip: 'Quality',
                    icon: Icons.high_quality_outlined,
                    tracks: [for (final t in tracks.video) if (t.id != 'no') t],
                    currentId: current.video.id,
                    idOf: (t) => t.id,
                    labelOf: _videoLabel,
                    onSelected: player.setVideoTrack,
                  ),
                  _TrackMenu<AudioTrack>(
                    tooltip: 'Audio',
                    icon: Icons.audiotrack_outlined,
                    tracks: [for (final t in tracks.audio) if (t.id != 'no') t],
                    currentId: current.audio.id,
                    idOf: (t) => t.id,
                    labelOf: (t) => _namedLabel(t.id, t.title, t.language, 'Track'),
                    onSelected: player.setAudioTrack,
                  ),
                  _TrackMenu<SubtitleTrack>(
                    tooltip: 'Captions',
                    icon: Icons.closed_caption_outlined,
                    tracks: [for (final t in tracks.subtitle) if (t.id != 'auto') t],
                    currentId: current.subtitle.id,
                    idOf: (t) => t.id,
                    labelOf: (t) => _namedLabel(t.id, t.title, t.language, 'Captions'),
                    onSelected: player.setSubtitleTrack,
                  ),
                ],
              );
            },
          ),
          ListenableBuilder(
            listenable: live.settings,
            builder: (context, _) {
              final volume = live.settings.volume;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: volume == 0 ? 'Unmute (M)' : 'Mute (M)',
                    onPressed: live.toggleMute,
                    icon: Icon(
                      volume == 0
                          ? Icons.volume_off
                          : volume < 50
                              ? Icons.volume_down
                              : Icons.volume_up,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: volume,
                        max: 100,
                        onChanged: live.setVolume,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: fullscreen ? 'Exit full screen (Esc)' : 'Full screen (F)',
            onPressed: onToggleFullscreen,
            icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleFavorite(BuildContext context, Channel channel) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final catalog = live.catalog;
    try {
      await catalog.setFavorite(channel.id, !catalog.isFavorite(channel.id));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text("Couldn't update favorites")));
    }
  }

  static String _videoLabel(VideoTrack t) {
    if (t.id == 'auto') return 'Auto';
    final height = t.h;
    final kbps = t.bitrate == null ? null : (t.bitrate! / 1000).round();
    if (height != null) return kbps == null ? '${height}p' : '${height}p  ·  $kbps kbps';
    return t.title ?? 'Track ${t.id}';
  }

  static String _namedLabel(String id, String? title, String? language, String fallback) {
    if (id == 'auto') return 'Auto';
    if (id == 'no') return 'Off';
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (language != null && language.isNotEmpty) language.toUpperCase(),
    ];
    return parts.isEmpty ? '$fallback $id' : parts.join('  ·  ');
  }
}

class _TrackMenu<T> extends StatelessWidget {
  const _TrackMenu({
    required this.tooltip,
    required this.icon,
    required this.tracks,
    required this.currentId,
    required this.idOf,
    required this.labelOf,
    required this.onSelected,
  });

  final String tooltip;
  final IconData icon;
  final List<T> tracks;
  final String currentId;
  final String Function(T track) idOf;
  final String Function(T track) labelOf;
  final Future<void> Function(T track) onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      icon: Icon(icon),
      enabled: tracks.isNotEmpty,
      color: ZipColors.surface,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final track in tracks)
          CheckedPopupMenuItem<T>(
            value: track,
            checked: idOf(track) == currentId,
            child: Text(labelOf(track)),
          ),
      ],
    );
  }
}

class _NumberPill extends StatelessWidget {
  const _NumberPill({required this.digits, required this.invalid});

  final String digits;
  final bool invalid;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: invalid ? ZipColors.offline : const Color(0xCC000000),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        digits,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: 3,
        ),
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
