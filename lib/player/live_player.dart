import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/api/api_config.dart';
import 'av_player.dart';
import 'mpv_player.dart';
import 'playback_stats.dart';

export 'playback_stats.dart' show PlaybackStats;

/// An audio or caption track the viewer can pick.
@immutable
class MediaTrack {
  const MediaTrack({required this.id, this.title, this.language});

  /// `auto` and `no` mean automatic and off, as in mpv.
  final String id;
  final String? title;
  final String? language;

  static const off = MediaTrack(id: 'no');

  @override
  bool operator ==(Object other) =>
      other is MediaTrack && other.id == id && other.title == title && other.language == language;

  @override
  int get hashCode => Object.hash(id, title, language);
}

/// The tracks the open stream offers and the ones playing.
@immutable
class MediaTracks {
  const MediaTracks({
    this.audio = const [],
    this.captions = const [],
    this.audioId = 'auto',
    this.captionId = 'no',
  });

  /// Audio tracks to choose from (never "off").
  final List<MediaTrack> audio;

  /// Caption tracks to choose from, "off" first.
  final List<MediaTrack> captions;
  final String audioId;
  final String captionId;

  static const none = MediaTracks();
}

/// One live-stream player, whichever engine draws it: mpv on Windows and
/// Linux, AVPlayer on macOS (so AirPlay works). Recordings, which are MPEG-TS
/// files AVFoundation can't open, always use [MpvPlayer].
abstract class LivePlayer {
  /// The engine for this platform.
  factory LivePlayer.create({
    required ApiConfig config,
    PlayerTuning tuning = PlayerTuning.main,
  }) =>
      Platform.isMacOS
          ? AvPlayer(config: config, tuning: tuning)
          : MpvPlayer(config: config, tuning: tuning);

  /// The bitrates the open stream offers, highest first. Empty when it has
  /// just one, or before they are known.
  ValueListenable<List<StreamVariant>> get variants;

  /// The bitrate of the variant playing now, when the stream says.
  ValueListenable<int?> get activeBitrate;

  ValueListenable<MediaTracks> get tracks;

  /// True once the stream played to its end.
  Stream<bool> get completed;

  /// Playback problems, some of them recoverable hiccups.
  Stream<String> get errors;
  Stream<Duration> get position;
  Stream<bool> get buffering;
  bool get isBuffering;

  /// Whether the picture is going to an AirPlay device instead of this window.
  ValueListenable<bool> get externalPlayback;

  /// Whether this engine can send its picture over AirPlay.
  bool get supportsAirPlay;

  /// Whether [url] can be given to [play].
  Future<bool> canPlay(String url);

  /// Starts playing a signed stream URL. Check [canPlay] first.
  Future<void> play(String url);
  Future<void> stop();
  Future<void> pause();
  Future<void> resume();
  Future<void> playOrPause();

  /// 0 to 100.
  Future<void> setVolume(double volume);

  /// Off, a muted tile never opens the sound device.
  Future<void> setAudioEnabled(bool enabled);
  Future<void> selectAudio(MediaTrack track);
  Future<void> selectCaptions(MediaTrack track);

  /// Limits which variant the next [play] picks: the best one at or under
  /// [bitsPerSecond], or the best there is when null.
  Future<void> setHlsBitrateCap(int? bitsPerSecond);

  /// Shows the system's AirPlay picker over [anchor] (window coordinates).
  Future<void> showAirPlayPicker(Rect anchor);

  /// Writes [text] into the diagnostic log, if there is one.
  Future<void> note(String text);

  /// What the engine is doing now, for the "Stats for nerds" panel.
  /// [PlaybackStats.empty] when it can't say.
  Future<PlaybackStats> readStats();

  Future<void> dispose();

  /// The picture, letterboxed on black.
  Widget view();
}

/// The playlist at [url] and the URL it ended up at after redirects, which
/// its relative URIs resolve against. Null when it could not be fetched.
Future<({String text, String url})?> fetchPlaylist(String url, {required String referer}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, ApiConfig.mediaUserAgent);
    request.headers.set(HttpHeaders.refererHeader, referer);
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final text = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
    var finalUrl = Uri.parse(url);
    for (final hop in response.redirects) {
      finalUrl = finalUrl.resolveUri(hop.location);
    }
    return (text: text, url: finalUrl.toString());
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
