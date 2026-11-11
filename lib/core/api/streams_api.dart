import '../models/json.dart';
import '../models/playback.dart';
import 'api_client.dart';

/// Playback and watch sessions. Browsing lives in `StreamsV2Api`.
///
/// Ported from the Android app's `StreamRepository`: the same endpoints and
/// the same reading of their 403 bodies.
class StreamsApi {
  StreamsApi(this._client, {this._preferAppleStream = true});

  final ApiClient _client;

  /// Asks for a channel's `apple_stream` (HLS) instead of its DASH manifest,
  /// on every platform. FFmpeg's DASH demuxer, which mpv plays DASH through,
  /// loses its place in the backend's live SegmentTimeline manifests: it
  /// fetches audio segments again, skips ahead by different amounts for audio
  /// and video, and mpv resets playback (repeated audio, video jumping back).
  /// The same channels over HLS play cleanly. The Mac libmpv build cannot
  /// play the DASH at all.
  final bool _preferAppleStream;

  /// The backend picks the Apple HLS source for any User-Agent containing
  /// `AppleCoreMedia` (streaming-platform `api/viewer/playback.py`), and bakes
  /// that choice into the returned URL, so only this request needs it.
  static const appleStreamUserAgent = 'ZipTop (Macintosh) AppleCoreMedia';

  /// The account's concurrent-stream allowance, as last reported by
  /// [checkLimit]. Null until the server has said.
  int? lastStreamLimit;

  String _id(String streamId) => Uri.encodeComponent(streamId);

  /// Passes the stream about to be opened so the server can exclude this
  /// client's own session. Throws [StreamLimitException] when refused.
  Future<void> checkLimit(String streamId) async {
    final res = await _client.get(
      'api/viewer/streams/check-limit',
      query: {'stream_id': streamId},
    );
    final json = res.json;
    final reported = asInt(json?['stream_limit']);
    if (reported != null && reported > 0) lastStreamLimit = reported;
    if (res.ok) {
      if (json != null && asBool(json['allowed']) == true) return;
      final limit = asInt(json?['stream_limit']);
      final count = asInt(json?['current_count']) ?? 0;
      throw StreamLimitException(
        limit == null ? 'Stream limit reached' : 'Stream limit reached ($count/$limit)',
      );
    }
    if (res.statusCode == 403) {
      throw StreamLimitException(res.errorMessage ?? 'Stream limit reached');
    }
    throw ApiException('Check limit failed: ${res.statusCode}', status: res.statusCode);
  }

  Future<bool> isReady(String streamId) async {
    final res = await _client.get('api/viewer/streams/${_id(streamId)}/ready');
    if (!res.ok) {
      throw ApiException('Ready check failed: ${res.statusCode}', status: res.statusCode);
    }
    return asBool(res.json?['ready']) ?? false;
  }

  Future<void> start(String streamId) async {
    final res = await _client.post('api/viewer/streams/${_id(streamId)}/start');
    if (!res.ok) {
      throw ApiException(
        res.errorMessage ?? 'Start failed: ${res.statusCode}',
        status: res.statusCode,
      );
    }
  }

  /// The signed, short-lived playback URL. Never cache it.
  Future<String> streamUrl(String streamId) async {
    final res = await _client.get(
      'api/viewer/streams/${_id(streamId)}/url',
      headers: {'User-Agent': _preferAppleStream ? appleStreamUserAgent : null},
    );
    final json = res.json;
    if (res.statusCode == 403 && asBool(json?['stream_limit']) == true) {
      throw StreamLimitException(res.errorMessage ?? 'Stream limit reached');
    }
    if (!res.ok) {
      throw ApiException(
        res.errorMessage ?? 'Could not get the stream (${res.statusCode})',
        status: res.statusCode,
      );
    }
    final url = asString(json?['stream_url']);
    if (url == null || url.trim().isEmpty) {
      throw const ApiException('Stream URL is empty or unavailable');
    }
    return url;
  }

  /// Throws [StreamLimitException] when this session was evicted, and
  /// [ApiException] when the beat could not be delivered.
  Future<HeartbeatOutcome> heartbeat(String streamId) async {
    final res = await _client.post('api/viewer/streams/${_id(streamId)}/heartbeat');
    final json = res.json;
    if (res.ok) {
      if (asBool(json?['warn']) == true) {
        return HeartbeatWarn(asInt(json?['seconds_remaining']));
      }
      return const HeartbeatOk();
    }
    if (res.statusCode == 403) {
      final message = res.errorMessage;
      if (asBool(json?['max_watch_exceeded']) == true) {
        return HeartbeatKicked(
          KickReason.watchTimeExceeded,
          message ?? 'Watch time limit reached',
        );
      }
      if (asBool(json?['stream_limit']) == true) {
        throw StreamLimitException(message ?? 'Stream limit reached');
      }
      return HeartbeatKicked(KickReason.other, message ?? 'Session ended');
    }
    throw ApiException('Heartbeat failed: ${res.statusCode}', status: res.statusCode);
  }

  /// Account-wide "still watching" acknowledgement; covers every open stream.
  Future<void> extendWatch() async {
    final res = await _client.post('api/viewer/watch-session/extend');
    if (!res.ok) {
      throw ApiException('Extend failed: ${res.statusCode}', status: res.statusCode);
    }
  }

  Future<void> leave(String streamId) async {
    await _client.post('api/viewer/streams/${_id(streamId)}/leave');
  }

  Future<void> endSession(String streamId) async {
    await _client.delete('api/viewer/streams/${_id(streamId)}/heartbeat');
  }
}
