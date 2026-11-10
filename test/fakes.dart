import 'package:ziptop/core/api/streams_api.dart';
import 'package:ziptop/core/models/playback.dart';

/// Records every call and answers from scripted values.
class FakeStreamsApi implements StreamsApi {
  final calls = <String>[];

  @override
  int? lastStreamLimit;
  bool ready = true;
  Object? limitError;
  Object? urlError;
  String url = 'https://cdn/a/index.m3u8';
  final heartbeats = <Object>[];

  @override
  Future<void> checkLimit(String streamId) async {
    calls.add('limit $streamId');
    if (limitError != null) throw limitError!;
  }

  @override
  Future<bool> isReady(String streamId) async {
    calls.add('ready $streamId');
    return ready;
  }

  @override
  Future<void> start(String streamId) async => calls.add('start $streamId');

  @override
  Future<String> streamUrl(String streamId) async {
    calls.add('url $streamId');
    if (urlError != null) throw urlError!;
    return url;
  }

  /// Pops the next scripted outcome; Ok once the script runs out.
  @override
  Future<HeartbeatOutcome> heartbeat(String streamId) async {
    calls.add('beat $streamId');
    if (heartbeats.isEmpty) return const HeartbeatOk();
    final next = heartbeats.removeAt(0);
    if (next is HeartbeatOutcome) return next;
    throw next;
  }

  @override
  Future<void> extendWatch() async => calls.add('extend');

  @override
  Future<void> leave(String streamId) async => calls.add('leave $streamId');

  @override
  Future<void> endSession(String streamId) async => calls.add('end $streamId');
}
