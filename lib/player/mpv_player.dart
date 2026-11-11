import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/api/api_config.dart';
import '../dvr/capture/m3u8_parser.dart';
import 'live_player.dart';

/// Buffer and network settings for one player instance.
class PlayerTuning {
  const PlayerTuning({
    required this.bufferBytes,
    required this.readaheadSeconds,
  });

  /// The main player: generous buffer, like the Android app's 15–30 s window.
  static const main = PlayerTuning(bufferBytes: 32 * 1024 * 1024, readaheadSeconds: 30);

  /// A multiview tile: small buffer so eight of them stay light.
  static const tile = PlayerTuning(bufferBytes: 8 * 1024 * 1024, readaheadSeconds: 12);

  final int bufferBytes;
  final int readaheadSeconds;
}

/// True when [mpvVersion] (the `mpv-version` property, e.g.
/// `mpv v0.42.0-19-ga61f6c3ab`) is a build known to play the backend's DASH.
///
/// mpv 0.36, which media_kit bundles, crashes the whole process in FFmpeg's
/// DASH demuxer on the backend's live `.mpd` manifests. 0.42 is the build
/// ZipTop ships (see windows/CMakeLists.txt, linux/third_party/build_libmpv.sh
/// and macos/third_party/build_libmpv.sh) and the oldest one verified. A Linux
/// build made against the system libmpv, or a macOS build made before
/// macos/third_party/build_libmpv.sh has run (media_kit's own Mpv.framework),
/// has an older one.
bool mpvPlaysDash(String? mpvVersion) {
  final match = RegExp(r'v?(\d+)\.(\d+)').firstMatch(mpvVersion ?? '');
  if (match == null) return false;
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  return major > 0 || minor >= 42;
}

/// mpv reports some problems that reloading the stream cannot fix, such as
/// the sound device being unavailable. Those must not restart playback.
bool isReloadableError(String message) {
  final text = message.toLowerCase();
  return !(text.contains('audio device') || text.contains('audio driver'));
}

bool isDashUrl(String url) =>
    (Uri.tryParse(url)?.path ?? url).toLowerCase().endsWith('.mpd');

/// One rung of a multi-bitrate stream's ladder: an HLS variant or a DASH
/// video representation.
@immutable
class StreamVariant {
  const StreamVariant({required this.bitrate, this.height});

  /// Bits per second, as the manifest advertises it. This is what mpv's
  /// `hls-bitrate` option compares against.
  final int bitrate;
  final int? height;

  String get label {
    final rate = formatBitrate(bitrate);
    return height == null ? rate : '${height}p  ·  $rate';
  }

  @override
  bool operator ==(Object other) =>
      other is StreamVariant && other.bitrate == bitrate && other.height == height;

  @override
  int get hashCode => Object.hash(bitrate, height);

  @override
  String toString() => 'StreamVariant($label)';
}

/// `6221600` → `6.2 Mbps`, `836280` → `836 kbps`.
String formatBitrate(int bitsPerSecond) {
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).round()} kbps';
}

/// Highest bitrate first, one entry per bitrate. Unknown (0) bitrates are
/// dropped: they cannot be asked for through `hls-bitrate`.
List<StreamVariant> _ladder(Iterable<StreamVariant> variants) {
  final byRate = <int, StreamVariant>{};
  for (final v in variants) {
    if (v.bitrate <= 0) continue;
    final known = byRate[v.bitrate];
    if (known == null || (known.height == null && v.height != null)) byRate[v.bitrate] = v;
  }
  return byRate.values.toList()..sort((a, b) => b.bitrate.compareTo(a.bitrate));
}

/// The variants of an HLS master playlist. A media playlist (a single
/// rendition) has none to choose from.
List<StreamVariant> variantsFromMasterPlaylist(String text, String url) {
  if (!M3u8Parser.isMaster(text)) return const [];
  return _ladder([
    for (final v in M3u8Parser.parseMaster(text, url))
      StreamVariant(bitrate: v.bandwidth, height: v.height),
  ]);
}

/// The variant mpv's `hls-bitrate` would pick: the highest bitrate at or
/// under [cap], else the lowest there is; the highest when [cap] is null.
/// Ties go to the first in [bitrates]. Returns an index, or null when empty.
int? pickVariant(List<int> bitrates, int? cap) {
  int? best;
  int? lowest;
  for (var i = 0; i < bitrates.length; i++) {
    final rate = bitrates[i];
    if (lowest == null || rate < bitrates[lowest]) lowest = i;
    final fits = cap == null || rate <= cap;
    if (fits && (best == null || rate > bitrates[best])) best = i;
  }
  return best ?? lowest;
}

/// [text], an HLS master playlist fetched from [baseUrl], cut down to the
/// one variant [pickVariant] chooses for [cap] and the renditions (audio,
/// subtitles) that variant uses, with every URI made absolute.
///
/// FFmpeg's HLS demuxer downloads and probes every variant of a master
/// before it plays any, about a second each on the backend's ladders. One
/// variant starts at once. Null when [text] is not a master playlist.
String? trimMasterPlaylist(String text, String baseUrl, {int? cap}) {
  if (!M3u8Parser.isMaster(text)) return null;
  final lines = text.split(RegExp(r'\r?\n'));

  // Each variant: the index of its #EXT-X-STREAM-INF line and its URI line.
  final variants = <({int tag, int uri, int bitrate})>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    var j = i + 1;
    while (j < lines.length && (lines[j].trim().isEmpty || lines[j].trimLeft().startsWith('#'))) {
      j++;
    }
    if (j >= lines.length) break;
    final attrs = M3u8Parser.parseAttributes(_afterColon(line));
    final bitrate = int.tryParse(attrs['BANDWIDTH'] ?? attrs['AVERAGE-BANDWIDTH'] ?? '') ?? 0;
    variants.add((tag: i, uri: j, bitrate: bitrate));
    i = j;
  }
  final chosen = pickVariant([for (final v in variants) v.bitrate], cap);
  if (chosen == null) return null;
  final variant = variants[chosen];
  final variantAttrs = M3u8Parser.parseAttributes(_afterColon(lines[variant.tag].trim()));

  String absolute(String line) => line.replaceAllMapped(
        RegExp(r'URI="([^"]*)"'),
        (m) => 'URI="${M3u8Parser.resolve(baseUrl, m.group(1)!)}"',
      );

  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (i == variant.tag) {
      out
        ..add(line)
        ..add(M3u8Parser.resolve(baseUrl, lines[variant.uri].trim()));
      continue;
    }
    if (variants.any((v) => v.tag == i || v.uri == i)) continue;
    // Trick-play variants are never played and would only be probed.
    if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF')) continue;
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final attrs = M3u8Parser.parseAttributes(_afterColon(line));
      final group = switch (attrs['TYPE']) {
        'AUDIO' => variantAttrs['AUDIO'],
        'SUBTITLES' => variantAttrs['SUBTITLES'],
        'VIDEO' => variantAttrs['VIDEO'],
        'CLOSED-CAPTIONS' => variantAttrs['CLOSED-CAPTIONS'],
        _ => null,
      };
      if (group == null || attrs['GROUP-ID'] != group) continue;
    }
    if (!line.startsWith('#')) continue;
    out.add(absolute(line));
  }
  return '${out.join('\n')}\n';
}

String _afterColon(String line) {
  final index = line.indexOf(':');
  return index < 0 ? '' : line.substring(index + 1);
}

/// The video tracks in mpv's `track-list` (JSON), as variants. For DASH,
/// mpv lists every video representation; for HLS only the variant it opened.
List<StreamVariant> variantsFromTrackList(String json) => _ladder([
      for (final t in _videoTracks(json))
        StreamVariant(bitrate: _int(t['hls-bitrate']) ?? 0, height: _int(t['demux-h'])),
    ]);

/// The bitrate of the video track mpv is playing, from `track-list` (JSON).
int? selectedVideoBitrate(String json) {
  for (final t in _videoTracks(json)) {
    if (t['selected'] == true) return _int(t['hls-bitrate']);
  }
  return null;
}

Iterable<Map<String, dynamic>> _videoTracks(String json) sync* {
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return;
  }
  if (decoded is! List) return;
  for (final t in decoded) {
    if (t is Map<String, dynamic> && t['type'] == 'video' && t['image'] != true) yield t;
  }
}

int? _int(Object? value) => value is num ? value.toInt() : null;

/// One mpv instance configured for ZipStreams' signed live streams.
class MpvPlayer implements LivePlayer {
  MpvPlayer({required this.config, this.tuning = PlayerTuning.main})
      : player = Player(
          configuration: PlayerConfiguration(
            title: 'ZipTop',
            bufferSize: tuning.bufferBytes,
            logLevel: MPVLogLevel.warn,
          ),
        ) {
    controller = VideoController(player);
    _ready = _configure();
    _trackSub = player.stream.tracks.listen((_) => unawaited(_readTracks()));
    _selectionSub = player.stream.track.listen((_) => _publishTracks());
  }

  final ApiConfig config;
  final PlayerTuning tuning;
  final Player player;
  late final VideoController controller;
  late final Future<void> _ready;
  late final StreamSubscription<Tracks> _trackSub;
  late final StreamSubscription<Track> _selectionSub;
  bool _dashSafe = false;
  bool _disposed = false;

  @override
  final ValueNotifier<List<StreamVariant>> variants = ValueNotifier(const []);

  @override
  final ValueNotifier<int?> activeBitrate = ValueNotifier(null);

  @override
  final ValueNotifier<MediaTracks> tracks = ValueNotifier(MediaTracks.none);

  @override
  final ValueNotifier<bool> externalPlayback = ValueNotifier(false);

  @override
  bool get supportsAirPlay => false;

  @override
  Stream<bool> get completed => player.stream.completed;

  @override
  Stream<String> get errors => player.stream.error;

  @override
  Stream<Duration> get position => player.stream.position;

  @override
  Stream<bool> get buffering => player.stream.buffering;

  @override
  bool get isBuffering => player.state.buffering;

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> resume() => player.play();

  @override
  Future<void> playOrPause() => player.playOrPause();

  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);

  @override
  Future<void> setAudioEnabled(bool enabled) =>
      player.setAudioTrack(enabled ? AudioTrack.auto() : AudioTrack.no());

  @override
  Future<void> selectAudio(MediaTrack track) async {
    for (final t in player.state.tracks.audio) {
      if (t.id == track.id) return player.setAudioTrack(t);
    }
  }

  @override
  Future<void> selectCaptions(MediaTrack track) async {
    if (track.id == 'no') return player.setSubtitleTrack(SubtitleTrack.no());
    for (final t in player.state.tracks.subtitle) {
      if (t.id == track.id) return player.setSubtitleTrack(t);
    }
  }

  @override
  Future<void> showAirPlayPicker(Rect anchor) async {}

  @override
  Widget view() => Video(controller: controller, controls: NoVideoControls, fill: Colors.black);

  void _publishTracks() {
    if (_disposed) return;
    final all = player.state.tracks;
    final current = player.state.track;
    MediaTrack of(String id, String? title, String? language) =>
        MediaTrack(id: id, title: title, language: language);
    tracks.value = MediaTracks(
      audio: [
        for (final t in all.audio)
          if (t.id != 'no') of(t.id, t.title, t.language),
      ],
      captions: [
        for (final t in all.subtitle)
          if (t.id != 'auto') of(t.id, t.title, t.language),
      ],
      audioId: current.audio.id,
      captionId: current.subtitle.id,
    );
  }

  // Bumped by every open, so a slow playlist fetch can't fill in the
  // variants of a stream that has since been replaced.
  int _openCount = 0;
  bool _variantsFromTracks = false;
  int? _bitrateCap;

  // Each player writes its cut-down master playlist to its own file.
  static int _instances = 0;
  final int _instance = _instances++;
  File? _trimmedFile;

  /// Whether the loaded libmpv can be given [url]. A DASH manifest must never
  /// reach a libmpv that crashes on it.
  @override
  Future<bool> canPlay(String url) async {
    await _ready;
    return _dashSafe || !isDashUrl(url);
  }

  Future<void> _configure() async {
    final native = player.platform;
    if (native is NativePlayer) {
      try {
        _dashSafe = mpvPlaysDash(await native.getProperty('mpv-version'));
      } catch (_) {
        _dashSafe = false;
      }
      final options = <String, String>{
        // The Android app sends these on every media request and notes the CDN expects them.
        'user-agent': ApiConfig.mediaUserAgent,
        'network-timeout': '15',
        'audio-channels': 'stereo',
        'hwdec': 'auto-safe',
        'cache': 'yes',
        'demuxer-readahead-secs': '${tuning.readaheadSeconds}',
        // With the cache on, mpv reads ahead by cache-secs (default: an
        // hour) and ignores demuxer-readahead-secs. On a live stream that
        // runs FFmpeg's DASH demuxer into the live edge, where it asks for
        // segments that do not exist yet, skips them, then re-reads older
        // ones: repeated audio and video jumping back.
        'cache-secs': '${tuning.readaheadSeconds}',
      };
      final logFile = diagnosticLogPath;
      if (logFile != null && identical(tuning, PlayerTuning.main)) {
        // mpv writes its verbose log here: demuxer, segment and timestamp
        // detail that the warn-level log stream leaves out.
        options['log-file'] = logFile;
      }
      for (final entry in options.entries) {
        try {
          await native.setProperty(entry.key, entry.value);
        } catch (_) {
          // An option this mpv build does not know is not worth failing playback over.
        }
      }
    }
    // Captions are off until the viewer picks a track.
    await player.setSubtitleTrack(SubtitleTrack.no());
  }

  /// Where the main player writes mpv's verbose log, from the
  /// `ZIPTOP_MPV_LOG` environment variable. Null (no log) when unset.
  static final String? diagnosticLogPath = () {
    final path = Platform.environment['ZIPTOP_MPV_LOG']?.trim();
    return path == null || path.isEmpty ? null : path;
  }();

  /// Writes [text] into the diagnostic log, if there is one, so the app's
  /// own decisions (reloads, quality changes) line up with mpv's.
  @override
  Future<void> note(String text) async {
    if (diagnosticLogPath == null || _disposed) return;
    await _ready;
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      await native.command(['print-text', 'ZipTop: $text']);
    } catch (_) {
      // Diagnostics only.
    }
  }

  /// Starts playing a signed stream URL (HLS or DASH). Check [canPlay] first.
  @override
  Future<void> play(String url) async {
    if (!await canPlay(url)) {
      throw UnsupportedError('This libmpv build cannot play DASH streams');
    }
    final open = _forgetVariants();
    // mpv lists only the HLS variant it opened, so the ladder comes from the
    // master playlist. For DASH it lists every representation.
    _variantsFromTracks = isDashUrl(url);
    var source = url;
    if (!_variantsFromTracks) {
      final master = await fetchPlaylist(url, referer: config.referer);
      if (_disposed || open != _openCount) return;
      if (master != null) {
        variants.value = variantsFromMasterPlaylist(master.text, master.url);
        final trimmed = trimMasterPlaylist(master.text, master.url, cap: _bitrateCap);
        if (trimmed != null) source = await _writeTrimmedMaster(trimmed) ?? url;
        if (_disposed || open != _openCount) return;
      }
    }
    unawaited(note(
      'open ${isDashUrl(url) ? 'DASH' : 'HLS'} stream'
      '${source == url ? '' : ' (one variant, cap ${_bitrateCap ?? 'none'})'}',
    ));
    await player.open(
      Media(
        source,
        httpHeaders: {
          'User-Agent': ApiConfig.mediaUserAgent,
          'Referer': config.referer,
        },
      ),
    );
  }

  /// Plays a local file, such as a recording, optionally from [start].
  Future<void> playFile(String path, {Duration? start}) async {
    await _ready;
    _forgetVariants();
    _variantsFromTracks = false;
    final from = start != null && start > Duration.zero ? start : null;
    await player.open(Media(path, start: from));
  }

  /// Limits which variant the next [play] picks: the best one at or under
  /// [bitsPerSecond] (the lowest there is when none is), or the best there is
  /// when null. mpv reads this when a stream opens and ignores changes to a
  /// stream that is playing. It covers HLS variants and DASH representations.
  @override
  Future<void> setHlsBitrateCap(int? bitsPerSecond) async {
    _bitrateCap = bitsPerSecond;
    await _ready;
    final native = player.platform;
    if (native is NativePlayer) {
      await native.setProperty('hls-bitrate', bitsPerSecond?.toString() ?? 'max');
    }
  }

  @override
  Future<void> stop() async {
    await _ready;
    _forgetVariants();
    await player.stop();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _openCount++;
    await _trackSub.cancel();
    await _selectionSub.cancel();
    await player.dispose();
    variants.dispose();
    activeBitrate.dispose();
    tracks.dispose();
    externalPlayback.dispose();
    try {
      await _trimmedFile?.delete();
    } catch (_) {
      // Already gone, or the temp folder is being cleaned up anyway.
    }
  }

  int _forgetVariants() {
    if (!_disposed) {
      variants.value = const [];
      activeBitrate.value = null;
    }
    return ++_openCount;
  }

  /// Writes [playlist] where mpv can open it, or null if it can't be.
  Future<String?> _writeTrimmedMaster(String playlist) async {
    try {
      final file = _trimmedFile ??= File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}ziptop'
        '${Platform.pathSeparator}master-$pid-$_instance.m3u8',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(playlist, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _readTracks() async {
    final native = player.platform;
    if (_disposed || native is! NativePlayer) return;
    final open = _openCount;
    final String json;
    try {
      json = await native.getProperty('track-list');
    } catch (_) {
      return;
    }
    if (_disposed || open != _openCount) return;
    activeBitrate.value = selectedVideoBitrate(json);
    if (_variantsFromTracks) variants.value = variantsFromTrackList(json);
    _publishTracks();
  }
}

/// Tells a playing stream from a stuck one by its position.
///
/// Live timestamps can jump back (a segment read twice, a discontinuity), so
/// progress is the sum of small forward steps, not "past the furthest
/// position seen": after a jump back, that would ignore real playback until
/// the stream caught up with where it had been.
class ProgressTracker {
  /// Forward playback that counts as the stream being healthy.
  static const healthy = Duration(seconds: 2);

  /// Bigger steps are jumps, not playback.
  static const maxStep = Duration(seconds: 5);

  Duration? _last;
  Duration _played = Duration.zero;
  Duration _sinceHealthy = Duration.zero;

  /// Forward playback seen since [restart]. Only ever grows.
  Duration get played => _played;

  /// Whether at least a second has played since [played] was [mark].
  bool movedSince(Duration mark) => _played - mark >= const Duration(seconds: 1);

  /// For a newly opened stream, whose positions start over.
  void restart() {
    _last = null;
    _played = Duration.zero;
    _sinceHealthy = Duration.zero;
  }

  /// Feeds a position. True each time another [healthy] of playback adds up.
  bool update(Duration position) {
    final last = _last;
    _last = position;
    if (last == null) return false;
    final step = position - last;
    if (step <= Duration.zero || step > maxStep) return false;
    _played += step;
    _sinceHealthy += step;
    if (_sinceHealthy < healthy) return false;
    _sinceHealthy = Duration.zero;
    return true;
  }
}

/// Decides when a dead player should ask for a new stream URL.
///
/// Backoff ported from the Android app: a stream that ends is retried up to
/// 10 times (1 s doubling to 8 s); an error up to 5 times (2 s doubling to
/// 16 s). Progress resets both counters.
class RetryPolicy {
  static const maxEndedRetries = 10;
  static const maxErrorRetries = 5;

  int _ended = 0;
  int _errors = 0;

  /// The wait before the next retry after the stream ended, or null to give up.
  Duration? nextAfterEnded() {
    if (_ended >= maxEndedRetries) return null;
    final seconds = (1 << _ended).clamp(1, 8);
    _ended++;
    return Duration(seconds: seconds);
  }

  /// The wait before the next retry after an error, or null to give up.
  Duration? nextAfterError() {
    if (_errors >= maxErrorRetries) return null;
    final seconds = (2 << _errors).clamp(2, 16);
    _errors++;
    return Duration(seconds: seconds);
  }

  void reset() {
    _ended = 0;
    _errors = 0;
  }
}
