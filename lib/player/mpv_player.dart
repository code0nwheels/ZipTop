import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/api/api_config.dart';

/// Buffer and network settings for one mpv instance.
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
/// ZipTop ships (see windows/CMakeLists.txt and
/// linux/third_party/build_libmpv.sh) and the oldest one verified. A Linux
/// build made against the system libmpv usually has an older one.
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

/// One mpv instance configured for ZipStreams' signed live streams.
class MpvPlayer {
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
  }

  final ApiConfig config;
  final PlayerTuning tuning;
  final Player player;
  late final VideoController controller;
  late final Future<void> _ready;
  bool _dashSafe = false;

  /// Whether the loaded libmpv can be given [url]. A DASH manifest must never
  /// reach a libmpv that crashes on it.
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
      };
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

  /// Starts playing a signed stream URL (HLS or DASH). Check [canPlay] first.
  Future<void> play(String url) async {
    if (!await canPlay(url)) {
      throw UnsupportedError('This libmpv build cannot play DASH streams');
    }
    await player.open(
      Media(
        url,
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
    final from = start != null && start > Duration.zero ? start : null;
    await player.open(Media(path, start: from));
  }

  /// Limits which HLS variant the next [play] picks: the best one at or
  /// under [bitsPerSecond], or the best there is when null. mpv reads this
  /// when a stream opens, so it does not disturb one that is playing. It has
  /// no effect on DASH.
  Future<void> setHlsBitrateCap(int? bitsPerSecond) async {
    await _ready;
    final native = player.platform;
    if (native is NativePlayer) {
      await native.setProperty('hls-bitrate', bitsPerSecond?.toString() ?? 'max');
    }
  }

  Future<void> stop() async {
    await _ready;
    await player.stop();
  }

  Future<void> dispose() => player.dispose();
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
