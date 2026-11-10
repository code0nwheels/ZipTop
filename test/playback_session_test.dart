import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/models/playback.dart';
import 'package:ziptop/core/session/playback_session.dart';
import 'fakes.dart';
import 'package:ziptop/player/mpv_player.dart' show RetryPolicy, isDashUrl, isReloadableError, mpvPlaysDash;

void main() {
  late FakeStreamsApi api;
  late PlaybackSession session;

  setUp(() {
    api = FakeStreamsApi();
    session = PlaybackSession(api);
  });

  test('a non-IPTV channel goes limit → url → heartbeat, then plays', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();

      expect(api.calls, ['limit r-1', 'url r-1', 'beat r-1']);
      expect(session.phase, SessionPhase.playing);
      expect(session.url, api.url);
    });
  });

  test('an IPTV channel that is not ready is started, then given 2 s', () {
    fakeAsync((async) {
      api.ready = false;
      session.open('s-1', iptv: true);
      async.flushMicrotasks();

      expect(api.calls, ['limit s-1', 'ready s-1', 'start s-1']);
      expect(session.phase, SessionPhase.preparing);

      async.elapse(const Duration(seconds: 2));
      expect(api.calls.sublist(3), ['url s-1', 'beat s-1']);
      expect(session.phase, SessionPhase.playing);
    });
  });

  test('heartbeats repeat every 20 s while playing', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      api.calls.clear();

      async.elapse(const Duration(seconds: 61));
      expect(api.calls, ['beat r-1', 'beat r-1', 'beat r-1']);
    });
  });

  test('a missed heartbeat does not end the session', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      api.heartbeats.add(const ApiException('Heartbeat failed: 502'));

      async.elapse(const Duration(seconds: 41));
      expect(session.phase, SessionPhase.playing);
      expect(api.calls.where((c) => c == 'beat r-1'), hasLength(3));
    });
  });

  test('a stream-limit refusal up front stops before asking for a URL', () {
    fakeAsync((async) {
      api.limitError = const StreamLimitException('Stream limit reached (2/2)');
      session.open('r-1', iptv: false);
      async.flushMicrotasks();

      expect(api.calls, ['limit r-1']);
      expect(session.phase, SessionPhase.streamLimit);
      expect(session.message, 'Stream limit reached (2/2)');
      expect(session.url, isNull);
    });
  });

  test('a URL failure is reported and nothing plays', () {
    fakeAsync((async) {
      api.urlError = const ApiException("This channel isn't included in your current plan.");
      session.open('r-1', iptv: false);
      async.flushMicrotasks();

      expect(session.phase, SessionPhase.failed);
      expect(session.message, contains("isn't included"));
      async.elapse(const Duration(minutes: 1));
      expect(api.calls.any((c) => c.startsWith('beat')), isFalse);
    });
  });

  test('switching channel leaves the old stream before opening the new one', () {
    fakeAsync((async) {
      session.open('a', iptv: false);
      async.flushMicrotasks();
      api.calls.clear();

      session.open('b', iptv: false);
      async.flushMicrotasks();

      expect(api.calls.first, 'leave a');
      expect(api.calls, containsAll(['end a', 'limit b', 'url b', 'beat b']));
      expect(api.calls.indexOf('leave a'), lessThan(api.calls.indexOf('limit b')));

      api.calls.clear();
      async.elapse(const Duration(seconds: 21));
      expect(api.calls, ['beat b'], reason: 'the old heartbeat loop is gone');
    });
  });

  test('eviction by another device ends playback', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      api.heartbeats.add(const StreamLimitException('limit'));

      async.elapse(const Duration(seconds: 20));
      expect(session.phase, SessionPhase.streamLimit);
      expect(session.message, PlaybackSession.evictedMessage);
      expect(session.url, isNull);

      api.calls.clear();
      async.elapse(const Duration(minutes: 1));
      expect(api.calls, isEmpty);
    });
  });

  test('a watch warning counts down and can be extended', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      api.heartbeats.add(const HeartbeatWarn(30));

      async.elapse(const Duration(seconds: 20));
      expect(session.warningSeconds, 30);
      async.elapse(const Duration(seconds: 5));
      expect(session.warningSeconds, 25);

      session.extendWatch();
      async.flushMicrotasks();
      expect(session.warningSeconds, isNull);
      expect(api.calls, contains('extend'));

      async.elapse(const Duration(minutes: 2));
      expect(session.phase, SessionPhase.playing);
    });
  });

  test('an unanswered watch warning stops playback at the deadline', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      // Nobody answers, and the beat near the deadline is lost: the local
      // deadline has to stop playback on its own.
      api.heartbeats.addAll(const [
        HeartbeatWarn(10),
        ApiException('Heartbeat failed: 502'),
      ]);

      async.elapse(const Duration(seconds: 20));
      expect(session.warningSeconds, 10);

      async.elapse(const Duration(seconds: 13));
      expect(session.phase, SessionPhase.watchTimeUp);
      expect(session.url, isNull);
      expect(api.calls, contains('leave r-1'));
    });
  });

  test('a server kick for watch time ends playback', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      api.heartbeats.add(
        const HeartbeatKicked(KickReason.watchTimeExceeded, 'Watch time limit reached'),
      );

      async.elapse(const Duration(seconds: 20));
      expect(session.phase, SessionPhase.watchTimeUp);
      expect(session.message, 'Watch time limit reached');
    });
  });

  test('close leaves and ends the session, and stops heartbeats', () {
    fakeAsync((async) {
      session.open('r-1', iptv: false);
      async.flushMicrotasks();
      api.calls.clear();

      session.close();
      async.flushMicrotasks();
      expect(api.calls, ['leave r-1', 'end r-1']);
      expect(session.phase, SessionPhase.idle);

      async.elapse(const Duration(minutes: 1));
      expect(api.calls, hasLength(2));
    });
  });

  test('reopen fetches a new URL for the same stream without leaving it', () {
    fakeAsync((async) {
      session.open('s-1', iptv: true);
      async.flushMicrotasks();
      api.calls.clear();
      api.url = 'https://cdn/b/index.m3u8';

      session.reopen();
      async.flushMicrotasks();
      expect(api.calls, ['limit s-1', 'ready s-1', 'url s-1', 'beat s-1']);
      expect(session.url, 'https://cdn/b/index.m3u8');
    });
  });

  test('retry backoff matches the Android player', () {
    final policy = RetryPolicy();
    expect(
      [for (var i = 0; i < 6; i++) policy.nextAfterError()?.inSeconds],
      [2, 4, 8, 16, 16, null],
    );
    expect(
      [for (var i = 0; i < 11; i++) policy.nextAfterEnded()?.inSeconds],
      [1, 2, 4, 8, 8, 8, 8, 8, 8, 8, null],
    );
    policy.reset();
    expect(policy.nextAfterError()?.inSeconds, 2);
  });

  test('DASH is only allowed on a libmpv known to play it', () {
    expect(mpvPlaysDash('mpv v0.36.0-403-g652a1dd907'), isFalse);
    expect(mpvPlaysDash('mpv v0.42.0-19-ga61f6c3ab'), isTrue);
    expect(mpvPlaysDash('mpv v1.0.0'), isTrue);
    expect(mpvPlaysDash(null), isFalse);
    expect(mpvPlaysDash('unknown'), isFalse);

    expect(isDashUrl('https://h/api/hls/1/a/b/manifest.mpd'), isTrue);
    expect(isDashUrl('https://h/api/hls/1/a/b/index.m3u8'), isFalse);
  });

  test('a sound-device failure is not a reason to reload the stream', () {
    expect(
      isReloadableError('Could not open/initialize audio device -> no sound.'),
      isFalse,
    );
    expect(isReloadableError("Failed to initialize audio driver 'openal'"), isFalse);
    expect(isReloadableError('Failed to open https://h/segment/1.m4v.'), isTrue);
    expect(isReloadableError('Failed to recognize file format.'), isTrue);
  });
}
