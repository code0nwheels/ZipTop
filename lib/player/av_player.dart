import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api/api_config.dart';
import 'live_player.dart';
import 'mpv_player.dart'
    show MpvPlayer, PlayerTuning, StreamVariant, isDashUrl, variantsFromMasterPlaylist;
import 'playback_stats.dart';

/// The engine for macOS: an AVPlayer in the ziptop_avplayer plugin
/// (packages/ziptop_avplayer), drawn through a Flutter texture.
///
/// AVPlayer plays the backend's HLS natively, adapts between variants itself
/// (capped by `preferredPeakBitRate`) and can hand the stream to an Apple TV
/// over AirPlay. It cannot play DASH; the app asks for HLS everywhere.
class AvPlayer implements LivePlayer {
  AvPlayer({required this.config, this.tuning = PlayerTuning.main}) {
    _ready = _create();
    // Every call awaits this and sees the failure; don't also report it as
    // unhandled before the first call.
    unawaited(_ready.catchError((Object _) {}));
  }

  static const _channel = MethodChannel('ziptop/avplayer');

  final ApiConfig config;
  final PlayerTuning tuning;

  late final Future<void> _ready;
  int? _id;
  StreamSubscription<dynamic>? _eventSub;
  bool _disposed = false;
  int? _bitrateCap;
  int _openCount = 0;

  /// The Flutter texture the plugin draws into, once created.
  final textureId = ValueNotifier<int?>(null);

  /// Width / height of the playing video; null until the first frame.
  final aspectRatio = ValueNotifier<double?>(null);

  /// Whether a frame of the open stream has been drawn. False while
  /// stopped, so the last picture doesn't linger.
  final hasPicture = ValueNotifier<bool>(false);

  /// The caption text on screen now, empty when none. AVPlayer only draws
  /// captions into its own layer, not into the frames the texture gets.
  final caption = ValueNotifier<String>('');

  @override
  final ValueNotifier<List<StreamVariant>> variants = ValueNotifier(const []);

  @override
  final ValueNotifier<int?> activeBitrate = ValueNotifier(null);

  @override
  final ValueNotifier<MediaTracks> tracks = ValueNotifier(MediaTracks.none);

  @override
  final ValueNotifier<bool> externalPlayback = ValueNotifier(false);

  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  bool _isBuffering = false;

  /// Only the main player offers AirPlay; multiview tiles stay local.
  @override
  bool get supportsAirPlay => identical(tuning, PlayerTuning.main);

  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;

  @override
  bool get isBuffering => _isBuffering;

  Future<void> _create() async {
    final created = await _channel.invokeMapMethod<String, Object?>('create', {
      'bufferSeconds': tuning.readaheadSeconds.toDouble(),
      'allowsAirPlay': supportsAirPlay,
    });
    final id = (created?['id'] as num?)?.toInt();
    if (id == null) throw StateError('The AVPlayer plugin did not create a player');
    _id = id;
    if (_disposed) {
      await _call('dispose');
      return;
    }
    _eventSub = EventChannel('ziptop/avplayer/$id')
        .receiveBroadcastStream()
        .listen(_onEvent, onError: (Object e) => _errors.add('$e'));
    textureId.value = (created?['textureId'] as num?)?.toInt();
  }

  Future<void> _call(String method, [Map<String, Object?> args = const {}]) async {
    await _ready;
    final id = _id;
    if (id == null) return;
    await _channel.invokeMethod<void>(method, {'id': id, ...args});
  }

  void _onEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final event = raw.cast<String, Object?>();
    // Events from a stream that has since been replaced are dropped.
    final open = (event['open'] as num?)?.toInt();
    if (open != null && open != _openCount) return;
    switch (event['event']) {
      case 'buffering':
        _isBuffering = event['value'] == true;
        _buffering.add(_isBuffering);
      case 'position':
        _position.add(Duration(milliseconds: (event['ms'] as num?)?.toInt() ?? 0));
      case 'completed':
        _completed.add(true);
      case 'error':
        _errors.add('${event['message'] ?? 'Playback error'}');
      case 'firstFrame':
        hasPicture.value = true;
      case 'size':
        final w = (event['width'] as num?)?.toDouble() ?? 0;
        final h = (event['height'] as num?)?.toDouble() ?? 0;
        aspectRatio.value = w > 0 && h > 0 ? w / h : null;
      case 'bitrate':
        final rate = (event['value'] as num?)?.toInt();
        activeBitrate.value = rate == null || rate <= 0 ? null : _nearestVariant(rate);
      case 'tracks':
        tracks.value = _parseTracks(event);
      case 'caption':
        caption.value = (event['text'] as String?) ?? '';
      case 'external':
        externalPlayback.value = event['value'] == true;
    }
  }

  /// AVPlayer reports the variant's BANDWIDTH; snap to the ladder in case
  /// it reports AVERAGE-BANDWIDTH instead.
  int _nearestVariant(int rate) {
    final ladder = variants.value;
    if (ladder.isEmpty) return rate;
    var best = ladder.first.bitrate;
    for (final v in ladder) {
      if ((v.bitrate - rate).abs() < (best - rate).abs()) best = v.bitrate;
    }
    return best;
  }

  static MediaTracks _parseTracks(Map<String, Object?> event) {
    List<MediaTrack> list(Object? raw) => [
          if (raw is List)
            for (final t in raw)
              if (t is Map)
                MediaTrack(
                  id: '${t['id']}',
                  title: t['title'] as String?,
                  language: t['language'] as String?,
                ),
        ];
    return MediaTracks(
      audio: list(event['audio']),
      captions: [MediaTrack.off, ...list(event['captions'])],
      audioId: (event['audioId'] as String?) ?? 'auto',
      captionId: (event['captionId'] as String?) ?? 'no',
    );
  }

  @override
  Future<bool> canPlay(String url) async => !isDashUrl(url);

  @override
  Future<void> play(String url) async {
    if (isDashUrl(url)) throw UnsupportedError('AVPlayer cannot play DASH streams');
    final open = _forget();
    // Fetched only for the quality menu; AVPlayer reads the playlist itself.
    unawaited(fetchPlaylist(url, referer: config.referer).then((master) {
      if (master == null || _disposed || open != _openCount) return;
      variants.value = variantsFromMasterPlaylist(master.text, master.url);
    }));
    await _call('open', {
      'url': url,
      'open': open,
      'userAgent': ApiConfig.mediaUserAgent,
      'headers': {'Referer': config.referer},
      'peakBitRate': _bitrateCap ?? 0,
    });
  }

  @override
  Future<void> stop() async {
    _forget();
    await _call('stop');
  }

  @override
  Future<void> pause() => _call('pause');

  @override
  Future<void> resume() => _call('resume');

  @override
  Future<void> playOrPause() => _call('playOrPause');

  @override
  Future<void> setVolume(double volume) =>
      _call('setVolume', {'volume': (volume / 100).clamp(0.0, 1.0)});

  @override
  Future<void> setAudioEnabled(bool enabled) => _call('setMuted', {'muted': !enabled});

  @override
  Future<void> selectAudio(MediaTrack track) => _call('selectAudio', {'track': track.id});

  @override
  Future<void> selectCaptions(MediaTrack track) {
    if (track.id == 'no') caption.value = '';
    return _call('selectCaptions', {'track': track.id == 'no' ? null : track.id});
  }

  /// AVPlayer applies a new cap to the playing stream by itself.
  @override
  Future<void> setHlsBitrateCap(int? bitsPerSecond) async {
    _bitrateCap = bitsPerSecond;
    await _call('setPeakBitRate', {'peakBitRate': bitsPerSecond ?? 0});
  }

  @override
  Future<void> showAirPlayPicker(Rect anchor) => _call('showRoutePicker', {
        'x': anchor.left,
        'y': anchor.top,
        'width': anchor.width,
        'height': anchor.height,
      });

  @override
  Future<void> note(String text) async {
    if (MpvPlayer.diagnosticLogPath == null) return;
    debugPrint('ZipTop: $text');
  }

  @override
  Future<PlaybackStats> readStats() async {
    if (_disposed) return PlaybackStats.empty;
    try {
      await _ready;
      final id = _id;
      if (id == null || _disposed) return PlaybackStats.empty;
      final raw = await _channel.invokeMapMethod<String, Object?>('stats', {'id': id});
      return raw == null ? PlaybackStats.empty : statsFromAvPlayer(raw);
    } catch (_) {
      return PlaybackStats.empty;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openCount++;
    await _eventSub?.cancel();
    try {
      await _call('dispose');
    } catch (_) {
      // The plugin is gone with the engine.
    }
    for (final c in [_completed, _errors, _position, _buffering]) {
      await c.close();
    }
    // The notifiers are left to the garbage collector: a multiview tile's
    // view can still be listening to them until the next frame.
  }

  int _forget() {
    if (!_disposed) {
      variants.value = const [];
      activeBitrate.value = null;
      tracks.value = MediaTracks.none;
      hasPicture.value = false;
      aspectRatio.value = null;
      caption.value = '';
      _isBuffering = false;
    }
    return ++_openCount;
  }

  @override
  Widget view() => AvPlayerView(player: this);
}

/// The texture, letterboxed on black, with captions drawn over it.
class AvPlayerView extends StatelessWidget {
  const AvPlayerView({super.key, required this.player});

  final AvPlayer player;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: ListenableBuilder(
        listenable: Listenable.merge([player.textureId, player.aspectRatio, player.hasPicture]),
        builder: (context, _) {
          final texture = player.textureId.value;
          if (texture == null || !player.hasPicture.value) return const SizedBox.expand();
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: player.aspectRatio.value ?? 16 / 9,
                  child: Texture(textureId: texture, filterQuality: FilterQuality.medium),
                ),
              ),
              _Captions(caption: player.caption),
            ],
          );
        },
      ),
    );
  }
}

class _Captions extends StatelessWidget {
  const _Captions({required this.caption});

  final ValueListenable<String> caption;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => ValueListenableBuilder<String>(
        valueListenable: caption,
        builder: (context, text, _) {
          if (text.trim().isEmpty) return const SizedBox.shrink();
          // Sized to the picture, like mpv's: about 1/18 of its height.
          final size = (box.maxHeight / 18).clamp(11.0, 40.0);
          return Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, box.maxHeight * 0.07),
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Color(0xB3000000)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: size, height: 1.25),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
