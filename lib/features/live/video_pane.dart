import 'dart:async';

import 'package:flutter/material.dart';

import '../../cast/cast_controller.dart';
import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/guide_repository.dart';
import '../../dvr/dvr_service.dart';
import '../../player/live_player.dart';
import '../../player/mpv_player.dart' show StreamVariant, formatBitrate;
import '../../theme.dart';
import '../../ui/ch_num_chip.dart';
import '../../ui/zip_spinner.dart';
import 'channel_panel.dart' show nowPlayingProgress;
import '../recordings/record_actions.dart';
import 'live_controller.dart';

/// The video with everything drawn over it: the control bar, the channel
/// banner, the number-entry pill and the session notices.
class VideoPane extends StatefulWidget {
  const VideoPane({
    super.key,
    required this.live,
    required this.cast,
    required this.dvr,
    required this.guide,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.mini,
    required this.onToggleMini,
    required this.onActivity,
    required this.controlsVisible,
    this.onSeePlans,
  });

  final LiveController live;
  final CastController cast;
  final DvrService dvr;
  final GuideRepository guide;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// Popped out into the small always-on-top window.
  final bool mini;
  final VoidCallback onToggleMini;

  /// Mouse moved or clicked over the video.
  final VoidCallback onActivity;
  final bool controlsVisible;

  /// Opens the plans page, offered when the plan doesn't include a channel.
  final VoidCallback? onSeePlans;

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
        SessionPhase.preparing => const Center(child: ZipSpinner(size: 52)),
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
        SessionPhase.notEntitled => _Notice(
            message: session.message ?? "Your plan doesn't include this channel.",
            action: widget.onSeePlans == null ? null : 'See plans',
            onAction: widget.onSeePlans,
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
        // Popped out, a double-click goes back to the full window.
        onDoubleTap: widget.mini ? widget.onToggleMini : widget.onToggleFullscreen,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              live.player.view(),
              _ElsewhereCard(live: live, cast: widget.cast, compact: widget.mini),
              if (notice == null && live.remote == null)
                StreamBuilder<bool>(
                  stream: live.player.buffering,
                  initialData: live.player.isBuffering,
                  builder: (context, snapshot) => snapshot.data == true
                      ? const Center(child: ZipSpinner(size: 44))
                      : const SizedBox.shrink(),
                ),
              if (notice != null) ColoredBox(color: ZipColors.overlayPlayer, child: notice),
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
                    duration: ZipMotion.fast,
                    child: _ControlBar(
                      live: live,
                      cast: widget.cast,
                      dvr: widget.dvr,
                      guide: widget.guide,
                      fullscreen: widget.fullscreen,
                      onToggleFullscreen: widget.onToggleFullscreen,
                      mini: widget.mini,
                      onToggleMini: widget.onToggleMini,
                    ),
                  ),
                ),
              ),
              if (warning != null)
                Center(
                  child: Container(
                    decoration: BoxDecoration(
                      color: ZipColors.surface,
                      borderRadius: ZipRadius.lgAll,
                      border: Border.all(color: ZipColors.lineHi),
                      boxShadow: ZipShadow.lg,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Are you still watching?',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text.rich(
                            TextSpan(
                              text: 'Playback stops in ',
                              style: const TextStyle(color: ZipColors.textSecondary),
                              children: [
                                TextSpan(
                                  text: '$warning s',
                                  style: ZipText.mono(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: ZipColors.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
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
    required this.cast,
    required this.dvr,
    required this.guide,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.mini,
    required this.onToggleMini,
  });

  final LiveController live;
  final CastController cast;
  final DvrService dvr;
  final GuideRepository guide;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// The mini player keeps only the channel, mute and the way back.
  final bool mini;
  final VoidCallback onToggleMini;

  @override
  Widget build(BuildContext context) {
    final channel = live.current;
    final catalog = live.catalog;
    final player = live.player;
    final text = Theme.of(context).textTheme;
    final now = channel?.nowPlaying;
    final progress = nowPlayingProgress(now);
    final favorite = channel != null && catalog.isFavorite(channel.id);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 40, 12, 10),
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mini) ...[
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
          ],
          Expanded(
            child: channel == null
                ? const SizedBox.shrink()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (channel.number != null) ...[
                            ChNumChip(channel.number!),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleMedium?.copyWith(
                                fontSize: 17,
                                letterSpacing: -0.17,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
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
                            child: ClipRRect(
                              borderRadius: ZipRadius.pillAll,
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                                backgroundColor: ZipColors.lineHi,
                                color: ZipColors.accent,
                              ),
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 8),
                    ],
                  ),
          ),
          if (channel != null && !mini)
            IconButton(
              tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => _toggleFavorite(context, channel),
              icon: Icon(
                favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                color: favorite ? ZipColors.accentText : null,
              ),
            ),
          if (channel != null && !mini) RecordButton(dvr: dvr, guide: guide, channel: channel),
          if (!mini && live.remote == null)
            ValueListenableBuilder<MediaTracks>(
              valueListenable: player.tracks,
              builder: (context, tracks, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _QualityMenu(live: live),
                    _TrackMenu<MediaTrack>(
                      tooltip: 'Audio',
                      icon: Icons.audiotrack_outlined,
                      tracks: tracks.audio,
                      currentId: tracks.audioId,
                      idOf: (t) => t.id,
                      labelOf: (t) => _namedLabel(t.id, t.title, t.language, 'Track'),
                      onSelected: player.selectAudio,
                    ),
                    _TrackMenu<MediaTrack>(
                      tooltip: 'Captions',
                      icon: Icons.closed_caption_outlined,
                      tracks: tracks.captions,
                      currentId: tracks.captionId,
                      idOf: (t) => t.id,
                      labelOf: (t) => _namedLabel(t.id, t.title, t.language, 'Captions'),
                      onSelected: player.selectCaptions,
                    ),
                  ],
                );
              },
            ),
          if (!mini && player.supportsAirPlay && live.remote == null)
            _AirPlayButton(player: player),
          if (!mini) _CastButton(cast: cast),
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
                  if (!mini)
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
          if (!mini) const SizedBox(width: 8),
          IconButton(
            tooltip: mini ? 'Back to full window (P)' : 'Pop out (P)',
            onPressed: onToggleMini,
            icon: Icon(mini ? Icons.open_in_full : Icons.picture_in_picture_alt),
          ),
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

/// Picks the stream's bitrate. Switching mpv's video track on the fly would
/// mix variants, so a pick caps the bitrate and reopens the stream.
class _QualityMenu extends StatelessWidget {
  const _QualityMenu({required this.live});

  final LiveController live;

  /// The menu value for "Best available".
  static const _best = 0;

  @override
  Widget build(BuildContext context) {
    final player = live.player;
    return ListenableBuilder(
      listenable: Listenable.merge([player.variants, player.activeBitrate, live.settings]),
      builder: (context, _) {
        final variants = player.variants.value;
        final active = player.activeBitrate.value;
        final cap = live.maxBitrate;
        StreamVariant? playing;
        for (final v in variants) {
          if (v.bitrate == active) playing = v;
        }
        final bestLabel = cap == null && playing != null
            ? 'Best available  ·  ${playing.height != null ? '${playing.height}p' : formatBitrate(playing.bitrate)}'
            : 'Best available';
        return PopupMenuButton<int>(
          tooltip: playing == null ? 'Quality' : 'Quality: ${playing.label}',
          icon: const Icon(Icons.high_quality_outlined),
          enabled: variants.length > 1,
          onSelected: (bitrate) => unawaited(live.setMaxBitrate(bitrate == _best ? null : bitrate)),
          itemBuilder: (context) => [
            CheckedPopupMenuItem<int>(
              value: _best,
              checked: cap == null,
              child: Text(bestLabel),
            ),
            const PopupMenuDivider(),
            for (final v in variants)
              CheckedPopupMenuItem<int>(
                value: v.bitrate,
                checked: cap != null && v.bitrate == (active ?? cap),
                child: Text(v.label),
              ),
          ],
        );
      },
    );
  }
}

/// Opens the system AirPlay menu over itself (macOS).
class _AirPlayButton extends StatelessWidget {
  const _AirPlayButton({required this.player});

  final LivePlayer player;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: player.externalPlayback,
      builder: (context, external, _) => IconButton(
        tooltip: external ? 'Playing on AirPlay' : 'AirPlay',
        icon: Icon(Icons.airplay, color: external ? ZipColors.accentText : null),
        onPressed: () {
          final box = context.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          unawaited(player.showAirPlayPicker(box.localToGlobal(Offset.zero) & box.size));
        },
      ),
    );
  }
}

class _CastButton extends StatelessWidget {
  const _CastButton({required this.cast});

  final CastController cast;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cast,
      builder: (context, _) {
        final name = cast.device?.name ?? 'TV';
        return IconButton(
          tooltip: switch (cast.phase) {
            CastPhase.casting => 'Casting to $name',
            CastPhase.connecting => 'Connecting to $name…',
            CastPhase.idle => 'Cast to a TV',
          },
          icon: Icon(
            cast.phase == CastPhase.idle ? Icons.cast : Icons.cast_connected,
            color: cast.phase == CastPhase.idle ? null : ZipColors.accentText,
          ),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => _CastDialog(cast: cast),
          ),
        );
      },
    );
  }
}

/// Lists the Cast devices on the network; picking one casts to it.
class _CastDialog extends StatefulWidget {
  const _CastDialog({required this.cast});

  final CastController cast;

  @override
  State<_CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<_CastDialog> {
  @override
  void initState() {
    super.initState();
    if (widget.cast.phase == CastPhase.idle) unawaited(widget.cast.scan());
  }

  @override
  Widget build(BuildContext context) {
    final cast = widget.cast;
    return ListenableBuilder(
      listenable: cast,
      builder: (context, _) {
        final current = cast.device;
        final devices = [
          ...cast.devices,
          if (current != null && !cast.devices.contains(current)) current,
        ];
        return AlertDialog(
          title: const Text('Cast to a TV'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final device in devices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      device == current ? Icons.cast_connected : Icons.tv,
                      color: device == current ? ZipColors.accentText : null,
                    ),
                    title: Text(device.name),
                    subtitle: device.model == null ? null : Text(device.model!),
                    trailing: device == current && cast.phase == CastPhase.connecting
                        ? const ZipSpinner(size: 20)
                        : null,
                    onTap: device == current
                        ? null
                        : () {
                            unawaited(cast.castTo(device));
                            Navigator.of(context).pop();
                          },
                  ),
                if (cast.scanning)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        ZipSpinner(size: 20),
                        SizedBox(width: 12),
                        Text('Looking for devices…'),
                      ],
                    ),
                  )
                else if (devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No Chromecast or Google TV found. It needs to be on the same '
                      'network as this computer.',
                      style: TextStyle(color: ZipColors.textSecondary),
                    ),
                  ),
                if (cast.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(cast.error!, style: const TextStyle(color: ZipColors.danger)),
                  ),
              ],
            ),
          ),
          actions: [
            if (cast.phase != CastPhase.idle)
              TextButton(
                onPressed: () {
                  unawaited(cast.stop());
                  Navigator.of(context).pop();
                },
                child: const Text('Stop casting'),
              ),
            TextButton(
              onPressed: cast.scanning ? null : cast.scan,
              child: const Text('Search again'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

/// Over the black video while the picture is on a TV: where it is, and
/// the way back.
class _ElsewhereCard extends StatelessWidget {
  const _ElsewhereCard({required this.live, required this.cast, required this.compact});

  final LiveController live;
  final CastController cast;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([cast, live.player.externalPlayback]),
      builder: (context, _) {
        final String label;
        final IconData icon;
        VoidCallback? onStop;
        if (cast.phase != CastPhase.idle) {
          final name = cast.device?.name ?? 'TV';
          label = cast.phase == CastPhase.casting ? 'Casting to $name' : 'Connecting to $name…';
          icon = Icons.cast_connected;
          onStop = () => unawaited(cast.stop());
        } else if (live.player.externalPlayback.value) {
          label = 'Playing on AirPlay';
          icon = Icons.airplay;
        } else {
          return const SizedBox.shrink();
        }
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: compact ? 36 : 64, color: ZipColors.textSecondary),
                SizedBox(height: compact ? 8 : 16),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (onStop != null && !compact) ...[
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: onStop, child: const Text('Stop casting')),
                ],
              ],
            ),
          ),
        );
      },
    );
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
    return AnimatedContainer(
      duration: ZipMotion.fast,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: invalid ? ZipColors.danger : ZipColors.overlayPill,
        borderRadius: ZipRadius.pillAll,
        border: Border.all(color: invalid ? ZipColors.danger : ZipColors.lineHi),
      ),
      child: Text(
        digits,
        style: ZipText.mono(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: invalid ? ZipColors.page : ZipColors.text,
        ).copyWith(letterSpacing: 3),
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
