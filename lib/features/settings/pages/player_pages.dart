import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/stores/settings_store.dart';
import '../../../player/mpv_player.dart' show formatBitrate;
import '../../../player/player_preferences.dart';
import '../../../ui/segmented_pills.dart';
import '../settings_widgets.dart';

/// On a Mac live TV plays through AVPlayer, which picks its own decoder,
/// sound output and network handling; mpv only plays recordings there.
String? get _mpvOnlyNote =>
    Platform.isMacOS ? 'On a Mac this applies to recordings. Live TV uses Apple\'s player.' : null;

const _nextChannel = 'Takes effect on the next channel you open.';

/// Joins notes that both apply.
String? _notes(String? a, String? b) => a == null ? b : (b == null ? a : '$a $b');

/// Starting up and stream quality.
class PlaybackPage extends StatelessWidget {
  const PlaybackPage({super.key, required this.settings, required this.setMaxBitrate});

  final SettingsStore settings;

  /// Caps the bitrate and reopens the playing stream at it.
  final Future<void> Function(int? bitsPerSecond) setMaxBitrate;

  /// Default-quality presets, bits per second; null is the best there is.
  static const qualityPresets = <int?>[null, 8000000, 4000000, 1500000];

  static String qualityLabel(int? cap) => switch (cap) {
        null => 'Best available',
        8000000 => 'High (8 Mbps)',
        4000000 => 'Medium (4 Mbps)',
        1500000 => 'Low (1.5 Mbps)',
        final rate => 'Custom (${formatBitrate(rate)})',
      };

  static String tileLabel(int? cap) => cap == null ? 'No limit' : 'Up to ${formatBitrate(cap)}';

  @override
  Widget build(BuildContext context) {
    final prefs = settings.playerPreferences;
    final cap = settings.maxBitrate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'When ZipTop opens',
          children: [
            SettingsSwitchRow(
              title: 'Play the last channel',
              description: 'Pick up where you left off.',
              value: settings.playLastOnStart,
              onChanged: (v) => settings.playLastOnStart = v,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Quality',
          footer: 'Channels offer a few bitrates; ZipTop plays the best one at or '
              'under your choice.',
          children: [
            SettingsSelectRow<int?>(
              title: 'Default quality',
              description: 'Lower it to save data or on a slow connection. The '
                  'quality menu on the player changes this too.',
              values: [...qualityPresets, if (!qualityPresets.contains(cap)) cap],
              selected: cap,
              label: qualityLabel,
              onSelected: (v) => unawaited(setMaxBitrate(v)),
            ),
            SettingsSelectRow<int?>(
              title: 'Multiview tiles',
              description: 'Small tiles in a layout stay at or under this '
                  '(4.5 Mbps is about 720p). A tile shown on its own plays at your '
                  'default quality.',
              values: PlayerPreferences.tileMaxBitrateChoices,
              selected: prefs.tileMaxBitrate,
              label: tileLabel,
              onSelected: (v) =>
                  settings.updatePlayerPreferences((p) => p.copyWith(tileMaxBitrate: v)),
            ),
          ],
        ),
      ],
    );
  }
}

/// How the picture is drawn and decoded.
class VideoPage extends StatelessWidget {
  const VideoPage({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    final prefs = settings.playerPreferences;
    void update(PlayerPreferences Function(PlayerPreferences) change) =>
        settings.updatePlayerPreferences(change);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Picture',
          children: [
            SettingsRow(
              title: 'Picture size',
              description: 'Fit shows the whole picture, with black bars when its '
                  'shape differs from the window. Fill crops the edges instead.',
              trailing: SegmentedPills<bool>(
                values: const [false, true],
                selected: prefs.fill,
                label: (fill) => fill ? 'Fill' : 'Fit',
                onSelected: (fill) => update((p) => p.copyWith(fill: fill)),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Decoding',
          children: [
            SettingsSelectRow<HardwareDecoding>(
              title: 'Hardware decoding',
              description: 'Decode video on the graphics card. Try "copy back" or '
                  'Off if you see green frames, blocky glitches or a black picture.',
              note: _mpvOnlyNote,
              values: HardwareDecoding.values,
              selected: prefs.hardwareDecoding,
              label: (v) => v.label,
              onSelected: (v) => update((p) => p.copyWith(hardwareDecoding: v)),
            ),
            SettingsSwitchRow(
              title: 'Deinterlace',
              description: 'Smooths the combing on interlaced broadcast channels '
                  '(1080i, 480i). Uses a little more processing.',
              note: _mpvOnlyNote,
              value: prefs.deinterlace,
              onChanged: (v) => update((p) => p.copyWith(deinterlace: v)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Sound output and which audio and caption tracks play.
class AudioCaptionsPage extends StatelessWidget {
  const AudioCaptionsPage({super.key, required this.settings});

  final SettingsStore settings;

  static final _languages = <String?>[null, ...trackLanguages.keys];

  static String _languageName(String? code, String none) =>
      code == null ? none : trackLanguages[code]?.name ?? code;

  @override
  Widget build(BuildContext context) {
    final prefs = settings.playerPreferences;
    void update(PlayerPreferences Function(PlayerPreferences) change) =>
        settings.updatePlayerPreferences(change);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Audio',
          children: [
            SettingsSelectRow<String?>(
              title: 'Preferred audio language',
              description: 'When a channel offers more than one audio track, play '
                  'this language.',
              values: _languages,
              selected: prefs.audioLanguage,
              label: (code) => _languageName(code, 'Channel default'),
              onSelected: (code) => update((p) => p.copyWith(audioLanguage: code)),
            ),
            SettingsSwitchRow(
              title: 'Surround sound',
              description: 'Play 5.1 sound on a surround system when a channel has '
                  'it. Off mixes everything down to stereo.',
              note: _notes(_mpvOnlyNote, _nextChannel),
              value: prefs.surround,
              onChanged: (v) => update((p) => p.copyWith(surround: v)),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Captions',
          children: [
            SettingsSwitchRow(
              title: 'Turn on captions automatically',
              description: 'Show captions whenever a channel has them. You can '
                  'still turn them off from the player.',
              value: prefs.captionsByDefault,
              onChanged: (v) => update((p) => p.copyWith(captionsByDefault: v)),
            ),
            SettingsSelectRow<String?>(
              title: 'Caption language',
              description: 'Which captions to show when there is a choice.',
              enabled: prefs.captionsByDefault,
              values: _languages,
              selected: prefs.captionLanguage,
              label: (code) => _languageName(code, 'First available'),
              onSelected: (code) => update((p) => p.copyWith(captionLanguage: code)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Buffering, network timeouts and stall recovery.
class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key, required this.settings});

  final SettingsStore settings;

  static String _seconds(int s) => '$s s';
  static String _megabytes(int mb) => '$mb MB';

  @override
  Widget build(BuildContext context) {
    final prefs = settings.playerPreferences;
    const d = PlayerPreferences.defaults;
    void update(PlayerPreferences Function(PlayerPreferences) change) =>
        settings.updatePlayerPreferences(change);
    String withDefault(String text, bool isDefault) => isDefault ? '$text (default)' : text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Buffer',
          footer: _nextChannel,
          children: [
            SettingsSelectRow<int>(
              title: 'Read ahead',
              description: 'How much video the player keeps downloaded ahead of '
                  'what you see. More rides out network hiccups; less uses less '
                  'memory and bandwidth.',
              values: PlayerPreferences.bufferSecondsChoices,
              selected: prefs.bufferSeconds,
              label: (s) => withDefault(_seconds(s), s == d.bufferSeconds),
              onSelected: (v) => update((p) => p.copyWith(bufferSeconds: v)),
            ),
            SettingsSelectRow<int>(
              title: 'Buffer memory',
              description: 'The most memory the buffer may use. High-bitrate '
                  'channels with a long read ahead need more.',
              note: _mpvOnlyNote,
              values: PlayerPreferences.bufferMegabytesChoices,
              selected: prefs.bufferMegabytes,
              label: (mb) => withDefault(_megabytes(mb), mb == d.bufferMegabytes),
              onSelected: (v) => update((p) => p.copyWith(bufferMegabytes: v)),
            ),
            SettingsSelectRow<int>(
              title: 'Multiview read ahead',
              description: 'The same for each multiview tile. Kept short so '
                  'several tiles stay light.',
              values: PlayerPreferences.tileBufferSecondsChoices,
              selected: prefs.tileBufferSeconds,
              label: (s) => withDefault(_seconds(s), s == d.tileBufferSeconds),
              onSelected: (v) => update((p) => p.copyWith(tileBufferSeconds: v)),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Network and recovery',
          children: [
            SettingsSelectRow<int>(
              title: 'Network timeout',
              description: 'How long to wait on a download that has stopped '
                  'responding before trying again.',
              note: _mpvOnlyNote,
              values: PlayerPreferences.networkTimeoutChoices,
              selected: prefs.networkTimeoutSeconds,
              label: (s) => withDefault(_seconds(s), s == d.networkTimeoutSeconds),
              onSelected: (v) => update((p) => p.copyWith(networkTimeoutSeconds: v)),
            ),
            SettingsSelectRow<int>(
              title: 'Reload a stalled stream after',
              description: 'If a stream sits buffering this long, ZipTop asks for '
                  'a fresh one.',
              values: PlayerPreferences.stallReloadChoices,
              selected: prefs.stallReloadSeconds,
              label: (s) => withDefault(_seconds(s), s == d.stallReloadSeconds),
              onSelected: (v) => update((p) => p.copyWith(stallReloadSeconds: v)),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: prefs.advancedAreDefault ? null : settings.resetAdvancedPlayback,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Restore defaults'),
          ),
        ),
      ],
    );
  }
}
