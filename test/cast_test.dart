import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/cast/cast_client.dart';
import 'package:ziptop/cast/cast_discovery.dart';
import 'package:ziptop/cast/cast_message.dart';
import 'package:ziptop/core/models/catalog.dart';
import 'package:ziptop/core/session/playback_session.dart';
import 'package:ziptop/core/stores/settings_store.dart';
import 'package:ziptop/features/live/live_controller.dart';
import 'package:ziptop/player/live_player.dart';
import 'package:ziptop/player/mpv_player.dart' show StreamVariant;

import 'fakes.dart';
import 'models_test.dart' show emptyStore;

void main() {
  group('CastMessage', () {
    const message = CastMessage(
      source: 'sender-0',
      destination: 'receiver-0',
      namespace: CastNamespace.receiver,
      payload: '{"type":"LAUNCH","appId":"086CC7D3","requestId":1}',
    );

    test('encodes the protobuf fields in order', () {
      final bytes = const CastMessage(
        source: 'a',
        destination: 'b',
        namespace: 'n',
        payload: 'p',
      ).encode();
      expect(bytes, [
        0x08, 0x00, // protocol_version = CASTV2_1_0
        0x12, 0x01, 0x61, // source_id = "a"
        0x1a, 0x01, 0x62, // destination_id = "b"
        0x22, 0x01, 0x6e, // namespace = "n"
        0x28, 0x00, // payload_type = STRING
        0x32, 0x01, 0x70, // payload_utf8 = "p"
      ]);
    });

    test('round-trips, including long and non-ASCII payloads', () {
      final long = CastMessage(
        source: 'sender-0',
        destination: 'web-5',
        namespace: CastNamespace.media,
        payload: '{"title":"Café ${'x' * 300}"}',
      );
      for (final m in [message, long]) {
        final decoded = CastMessage.decode(m.encode());
        expect(decoded.source, m.source);
        expect(decoded.destination, m.destination);
        expect(decoded.namespace, m.namespace);
        expect(decoded.payload, m.payload);
      }
      expect(CastMessage.decode(message.encode()).type, 'LAUNCH');
    });

    test('frames carry a big-endian length', () {
      final framed = message.frame();
      final length = ByteData.sublistView(framed).getUint32(0);
      expect(length, framed.length - 4);
    });

    test('the frame reader copes with chunks split anywhere', () {
      final stream = Uint8List.fromList([...message.frame(), ...message.frame()]);
      for (final size in [1, 3, 7, stream.length]) {
        final reader = CastFrameReader();
        final out = <CastMessage>[];
        for (var i = 0; i < stream.length; i += size) {
          final end = i + size > stream.length ? stream.length : i + size;
          out.addAll(reader.add(stream.sublist(i, end)));
        }
        expect(out, hasLength(2), reason: 'chunk size $size');
        expect(out.every((m) => m.payload == message.payload), isTrue);
      }
    });

    test('an absurd frame length is an error, not a huge allocation', () {
      expect(() => CastFrameReader().add([0x7f, 0, 0, 0, 1]), throwsFormatException);
    });
  });

  group('receiver payloads', () {
    test('finds the launched app', () {
      final app = CastApp.find({
        'type': 'RECEIVER_STATUS',
        'status': {
          'applications': [
            {'appId': 'E8C28D3C', 'sessionId': 'idle', 'transportId': 'idle'},
            {'appId': '086CC7D3', 'sessionId': 's-1', 'transportId': 'web-7'},
          ],
        },
      }, '086CC7D3');
      expect(app?.sessionId, 's-1');
      expect(app?.transportId, 'web-7');
      expect(CastApp.find({'status': {}}, '086CC7D3'), isNull);
    });

    test('reads media status', () {
      final status = CastMediaStatus.fromPayload({
        'type': 'MEDIA_STATUS',
        'status': [
          {'mediaSessionId': 3, 'playerState': 'IDLE', 'idleReason': 'ERROR'},
        ],
      });
      expect(status?.state, CastPlayerState.idle);
      expect(status?.idleReason, 'ERROR');
      expect(status?.mediaSessionId, 3);
      expect(CastMediaStatus.fromPayload({'status': []}), isNull);
    });

    test('reads the TXT record', () {
      final txt = parseCastTxt('id=abc123\nmd=Chromecast\nfn=Living Room TV\nrs=\n');
      expect(txt['id'], 'abc123');
      expect(txt['md'], 'Chromecast');
      expect(txt['fn'], 'Living Room TV');
    });
  });

  group('LiveController casting', () {
    late FakeStreamsApi api;
    late PlaybackSession session;
    late _FakePlayer player;
    late LiveController live;
    late _FakeRemote remote;
    const channel = Channel(id: 'ch1', name: 'One');

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      api = FakeStreamsApi();
      session = PlaybackSession(api);
      player = _FakePlayer();
      remote = _FakeRemote();
      live = LiveController(
        catalog: emptyStore(),
        settings: await SettingsStore.load(),
        session: session,
        player: player,
      );
    });

    tearDown(() {
      live.dispose();
      session.dispose();
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('the playing URL moves to the device and back', () async {
      await live.tune(channel);
      await settle();
      expect(player.played, [api.url]);

      await live.startCasting(remote);
      expect(player.stops, greaterThan(0));
      expect(remote.loaded, [api.url]);

      api.url = 'https://cdn/b/index.m3u8';
      await live.stopCasting();
      await settle();
      expect(live.remote, isNull);
      expect(remote.mediaStops, 1);
      // A fresh URL plays here again.
      expect(player.played.last, 'https://cdn/b/index.m3u8');
    });

    test('a channel change while casting goes to the device', () async {
      await live.tune(channel);
      await settle();
      await live.startCasting(remote);
      api.url = 'https://cdn/two/index.m3u8';
      await live.tune(const Channel(id: 'ch2', name: 'Two'));
      await settle();
      expect(remote.loaded.last, 'https://cdn/two/index.m3u8');
      expect(player.played, hasLength(1));
    });

    test('the device failing asks the server for a new URL', () {
      fakeAsync((async) {
        unawaited(live.tune(channel));
        async.flushMicrotasks();
        unawaited(live.startCasting(remote));
        async.flushMicrotasks();
        final urlsBefore = api.calls.where((c) => c.startsWith('url')).length;

        remote.emit(const RemoteFailed('boom'));
        async.elapse(const Duration(seconds: 3));
        expect(api.calls.where((c) => c.startsWith('url')).length, urlsBefore + 1);
        expect(remote.loaded, hasLength(2));
      });
    });

    test('a device that goes away hands playback back here', () async {
      await live.tune(channel);
      await settle();
      await live.startCasting(remote);
      remote.emit(const RemoteGone('closed on the TV'));
      await settle();
      await settle();
      expect(live.remote, isNull);
      expect(remote.mediaStops, 0);
      expect(player.played, hasLength(2));
    });

    test('volume follows the device while casting', () async {
      await live.tune(channel);
      await settle();
      await live.startCasting(remote);
      await live.setVolume(40);
      expect(remote.volumes, contains(40));
      expect(player.volumes, isNot(contains(40)));
    });
  });
}

class _FakeRemote implements RemoteOutput {
  final loaded = <String>[];
  final volumes = <double>[];
  int mediaStops = 0;

  // ignore: close_sinks
  final _events = StreamController<RemoteEvent>.broadcast(sync: true);

  void emit(RemoteEvent event) => _events.add(event);

  @override
  Stream<RemoteEvent> get events => _events.stream;

  @override
  String get name => 'Living Room TV';

  @override
  Future<void> load(String url, Channel channel) async => loaded.add(url);

  @override
  Future<void> stopMedia() async => mediaStops++;

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
}

class _FakePlayer implements LivePlayer {
  final played = <String>[];
  final volumes = <double>[];
  int stops = 0;

  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _buffering = StreamController<bool>.broadcast();

  @override
  final ValueNotifier<List<StreamVariant>> variants = ValueNotifier(const []);
  @override
  final ValueNotifier<int?> activeBitrate = ValueNotifier(null);
  @override
  final ValueNotifier<MediaTracks> tracks = ValueNotifier(MediaTracks.none);
  @override
  final ValueNotifier<bool> externalPlayback = ValueNotifier(false);

  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  bool get isBuffering => false;
  @override
  bool get supportsAirPlay => false;

  @override
  Future<bool> canPlay(String url) async => true;
  @override
  Future<void> play(String url) async => played.add(url);
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setAudioEnabled(bool enabled) async {}
  @override
  Future<void> selectAudio(MediaTrack track) async {}
  @override
  Future<void> selectCaptions(MediaTrack track) async {}
  @override
  Future<void> setHlsBitrateCap(int? bitsPerSecond) async {}
  @override
  Future<void> showAirPlayPicker(Rect anchor) async {}
  @override
  Future<void> note(String text) async {}
  @override
  Future<PlaybackStats> readStats() async => PlaybackStats.empty;
  @override
  Future<void> dispose() async {}
  @override
  Widget view() => const SizedBox();
}
