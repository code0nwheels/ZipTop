import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'mpv_player.dart' show formatBitrate;

/// What a player is doing right now, for the "Stats for nerds" panel.
/// Anything the engine doesn't report is null.
///
/// Never holds the stream URL: it is signed and carries the viewer's token.
@immutable
class PlaybackStats {
  const PlaybackStats({
    this.engine,
    this.source,
    this.width,
    this.height,
    this.pixelFormat,
    this.videoCodec,
    this.decoder,
    this.fps,
    this.audioCodec,
    this.sampleRate,
    this.channels,
    this.variantBitrate,
    this.videoBitrate,
    this.downloadRate,
    this.bufferSeconds,
    this.droppedFrames,
    this.decoderDrops,
    this.stalls,
    this.avSync,
  });

  static const empty = PlaybackStats();

  /// `mpv v0.42.0`, `AVPlayer`.
  final String? engine;

  /// `HLS`, `DASH` or `File`.
  final String? source;
  final int? width;
  final int? height;
  final String? pixelFormat;
  final String? videoCodec;

  /// The hardware decoder in use, or `software`.
  final String? decoder;
  final double? fps;
  final String? audioCodec;
  final int? sampleRate;
  final int? channels;

  /// The bitrate the playing variant advertises, bits per second.
  final int? variantBitrate;

  /// The video bitrate actually measured, bits per second.
  final int? videoBitrate;

  /// How fast the stream is downloading, bits per second.
  final int? downloadRate;

  /// Media buffered ahead of the playhead.
  final double? bufferSeconds;
  final int? droppedFrames;

  /// Frames the decoder dropped (mpv only; [droppedFrames] are the output's).
  final int? decoderDrops;
  final int? stalls;

  /// Audio ahead of video, in seconds (mpv only).
  final double? avSync;
}

/// Parses what [MpvPlayer] reads back from mpv's properties, each a string
/// or null when mpv had none.
PlaybackStats statsFromMpv(
  Map<String, String?> props, {
  String? source,
  int? variantBitrate,
}) {
  String? text(String key) {
    final value = props[key]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  double? number(String key) => double.tryParse(text(key) ?? '');
  int? whole(String key) => number(key)?.round();

  final hwdec = text('hwdec-current');
  final cacheSpeed = number('cache-speed');
  final fps = number('container-fps') ?? number('estimated-vf-fps');
  return PlaybackStats(
    engine: text('mpv-version'),
    source: source,
    width: _positive(whole('video-params/w')),
    height: _positive(whole('video-params/h')),
    pixelFormat: text('video-params/pixelformat'),
    videoCodec: text('video-codec'),
    decoder: hwdec == null ? null : (hwdec == 'no' ? 'software' : hwdec),
    fps: fps != null && fps > 0 ? fps : null,
    audioCodec: text('audio-codec-name'),
    sampleRate: _positive(whole('audio-params/samplerate')),
    channels: _positive(whole('audio-params/channel-count')),
    variantBitrate: _positive(variantBitrate),
    videoBitrate: _positive(whole('video-bitrate')),
    downloadRate: cacheSpeed == null ? null : _positive((cacheSpeed * 8).round()),
    bufferSeconds: _nonNegative(number('demuxer-cache-duration')),
    droppedFrames: _nonNegativeInt(whole('frame-drop-count')),
    decoderDrops: _nonNegativeInt(whole('decoder-frame-drop-count')),
    avSync: number('avsync'),
  );
}

/// Parses the ziptop_avplayer plugin's `stats` reply. AVFoundation's access
/// log reports unknown values as negative numbers.
PlaybackStats statsFromAvPlayer(Map<String, Object?> raw) {
  double? number(String key) {
    final value = raw[key];
    return value is num ? value.toDouble() : null;
  }

  int? whole(String key) => number(key)?.round();
  final codec = raw['codec'];
  final fps = number('fps');
  return PlaybackStats(
    engine: 'AVPlayer',
    source: 'HLS',
    width: _positive(whole('width')),
    height: _positive(whole('height')),
    videoCodec: codec is String && codec.trim().isNotEmpty ? codec.trim() : null,
    fps: fps != null && fps > 0 ? fps : null,
    variantBitrate: _positive(whole('indicatedBitrate')),
    videoBitrate: _positive(whole('averageVideoBitrate')),
    downloadRate: _positive(whole('observedBitrate')),
    bufferSeconds: _nonNegative(number('bufferSeconds')),
    droppedFrames: _nonNegativeInt(whole('droppedFrames')),
    stalls: _nonNegativeInt(whole('stalls')),
  );
}

int? _positive(int? n) => n != null && n > 0 ? n : null;
int? _nonNegativeInt(int? n) => n != null && n >= 0 ? n : null;
double? _nonNegative(double? n) => n != null && n >= 0 ? n : null;

/// The panel's rows, label then value, leaving out what isn't known.
List<(String, String)> statsRows(PlaybackStats s, {Size? viewport}) {
  final rows = <(String, String)>[];
  void add(String label, String? value) {
    if (value != null && value.isNotEmpty) rows.add((label, value));
  }

  add('Engine', s.engine);
  add('Source', s.source);
  if (s.width != null && s.height != null) {
    add('Resolution', '${s.width}×${s.height}${s.fps == null ? '' : ' @ ${formatFps(s.fps!)} fps'}');
  } else if (s.fps != null) {
    add('Frame rate', '${formatFps(s.fps!)} fps');
  }
  if (viewport != null && viewport.width > 0 && viewport.height > 0) {
    add('Viewport', '${viewport.width.round()}×${viewport.height.round()}');
  }
  add('Video', _joined([s.videoCodec, s.pixelFormat, s.decoder]));
  add(
    'Audio',
    _joined([
      s.audioCodec,
      if (s.sampleRate != null) '${_trim(s.sampleRate! / 1000, 1)} kHz',
      if (s.channels != null) '${s.channels} ch',
    ]),
  );
  add('Variant', s.variantBitrate == null ? null : formatBitrate(s.variantBitrate!));
  add('Video bitrate', s.videoBitrate == null ? null : formatBitrate(s.videoBitrate!));
  add('Connection', s.downloadRate == null ? null : formatBitrate(s.downloadRate!));
  add('Buffer', s.bufferSeconds == null ? null : '${s.bufferSeconds!.toStringAsFixed(1)} s');
  if (s.droppedFrames != null) {
    add(
      'Dropped',
      s.decoderDrops == null ? '${s.droppedFrames}' : '${s.droppedFrames} (decoder ${s.decoderDrops})',
    );
  } else if (s.decoderDrops != null) {
    add('Dropped', 'decoder ${s.decoderDrops}');
  }
  add('Stalls', s.stalls?.toString());
  if (s.avSync != null) {
    add('A/V sync', '${s.avSync! >= 0 ? '+' : '−'}${s.avSync!.abs().toStringAsFixed(3)} s');
  }
  return rows;
}

/// `59.940059` → `59.94`, `30.0` → `30`.
String formatFps(double fps) => _trim(fps, 2);

String _trim(double value, int digits) {
  var text = value.toStringAsFixed(digits);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

String? _joined(List<String?> parts) {
  final present = [
    for (final p in parts)
      if (p != null && p.isNotEmpty) p,
  ];
  return present.isEmpty ? null : present.join('  ·  ');
}
