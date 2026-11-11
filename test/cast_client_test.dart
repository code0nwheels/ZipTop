import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/cast/cast_client.dart';
import 'package:ziptop/cast/cast_message.dart';

/// A pretend Chromecast: TLS on a local port, answering the way a real one
/// does (cast_channel.proto framing, JSON payloads).
class FakeCastDevice {
  FakeCastDevice._(this._server) {
    _server.listen(_accept);
  }

  static const appId = '086CC7D3';
  static const transportId = 'web-7';
  static const sessionId = 'session-1';

  static Future<FakeCastDevice> start() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/cast/cert.pem')
      ..usePrivateKey('test/fixtures/cast/key.pem');
    return FakeCastDevice._(await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context));
  }

  final SecureServerSocket _server;
  SecureSocket? _client;
  final received = <CastMessage>[];
  final _arrived = StreamController<CastMessage>.broadcast();
  final _connected = Completer<void>();
  bool appRunning = false;

  /// Completes once the client's TLS connection is accepted.
  Future<void> get connected => _connected.future;

  int get port => _server.port;

  Future<CastMessage> next(String type) =>
      _arrived.stream.firstWhere((m) => m.type == type).timeout(const Duration(seconds: 5));

  void _accept(SecureSocket socket) {
    _client = socket;
    if (!_connected.isCompleted) _connected.complete();
    final reader = CastFrameReader();
    socket.listen((chunk) {
      for (final m in reader.add(chunk)) {
        if (_arrived.isClosed) return;
        received.add(m);
        _arrived.add(m);
        _reply(m);
      }
    }, onError: (_) {});
  }

  void send(String namespace, Map<String, Object?> data, {String from = 'receiver-0'}) {
    _client?.add(CastMessage.json(
      source: from,
      destination: 'sender-0',
      namespace: namespace,
      data: data,
    ).frame());
  }

  Map<String, Object?> receiverStatus(int requestId) => {
        'type': 'RECEIVER_STATUS',
        'requestId': requestId,
        'status': {
          'applications': [
            if (appRunning)
              {'appId': appId, 'sessionId': sessionId, 'transportId': transportId},
          ],
          'volume': {'level': 0.5, 'muted': false},
        },
      };

  void _reply(CastMessage m) {
    final data = m.data!;
    final requestId = (data['requestId'] as num?)?.toInt() ?? 0;
    switch (m.type) {
      case 'PING':
        send(CastNamespace.heartbeat, {'type': 'PONG'});
      case 'LAUNCH':
        // A status while the app starts, then the one that answers.
        send(CastNamespace.receiver, receiverStatus(0));
        appRunning = true;
        send(CastNamespace.receiver, receiverStatus(requestId));
      case 'LOAD':
        send(
          CastNamespace.media,
          {
            'type': 'MEDIA_STATUS',
            'requestId': requestId,
            'status': [
              {'mediaSessionId': 1, 'playerState': 'BUFFERING'},
            ],
          },
          from: transportId,
        );
    }
  }

  Future<void> close() async {
    await _client?.close();
    await _server.close();
    await _arrived.close();
  }
}

void main() {
  late FakeCastDevice device;
  late CastClient client;

  setUp(() async {
    device = await FakeCastDevice.start();
    client = await CastClient.connect(
      CastDevice(id: 'fake', name: 'Fake TV', host: '127.0.0.1', port: device.port),
    );
  });

  tearDown(() async {
    await client.close();
    await device.close();
  });

  test('launches the receiver and plays a stream on it', () async {
    await client.launch(FakeCastDevice.appId);
    final status = await client.load(
      url: 'https://cdn/a/index.m3u8',
      contentType: 'application/x-mpegurl',
      title: 'One',
      customData: {
        'headers': {'Referer': 'https://al.zipstreams.live/'},
      },
    );
    expect(status?.state, CastPlayerState.buffering);
    // Connected to the platform, then to the app before loading on it.
    expect(
      device.received.where((m) => m.type == 'CONNECT').map((m) => m.destination),
      ['receiver-0', FakeCastDevice.transportId],
    );

    final load = device.received.firstWhere((m) => m.type == 'LOAD');
    expect(load.destination, FakeCastDevice.transportId);
    expect(load.namespace, CastNamespace.media);
    final media = load.data!['media'] as Map<String, Object?>;
    expect(media['contentId'], 'https://cdn/a/index.m3u8');
    expect(media['streamType'], 'LIVE');
    expect(load.data!['sessionId'], FakeCastDevice.sessionId);
    expect((media['customData'] as Map)['headers'], isNotNull);

    // Later status pushed by the device reaches the stream.
    final playing = client.mediaStatus.firstWhere((s) => s.state == CastPlayerState.playing);
    device.send(
      CastNamespace.media,
      {
        'type': 'MEDIA_STATUS',
        'requestId': 0,
        'status': [
          {'mediaSessionId': 1, 'playerState': 'PLAYING'},
        ],
      },
      from: FakeCastDevice.transportId,
    );
    expect((await playing.timeout(const Duration(seconds: 5))).mediaSessionId, 1);

    client.stopMedia();
    final stop = await device.next('STOP');
    expect(stop.data!['mediaSessionId'], 1);

    client.setVolume(0.3);
    final volume = await device.next('SET_VOLUME');
    expect((volume.data!['volume'] as Map)['level'], 0.3);
  });

  test('answers the device heartbeat', () async {
    await device.connected;
    final pong = device.next('PONG');
    device.send(CastNamespace.heartbeat, {'type': 'PING'});
    expect((await pong).namespace, CastNamespace.heartbeat);
  });

  test('ends when the receiver app stops on the TV', () async {
    await client.launch(FakeCastDevice.appId);
    await device.connected;
    device.appRunning = false;
    device.send(CastNamespace.receiver, device.receiverStatus(0));
    expect(await client.done.timeout(const Duration(seconds: 5)), contains('closed on the TV'));
  });

  test('stopApp quits the receiver', () async {
    await client.launch(FakeCastDevice.appId);
    final stop = device.next('STOP');
    await client.stopApp();
    final message = await stop;
    expect(message.namespace, CastNamespace.receiver);
    expect(message.data!['sessionId'], FakeCastDevice.sessionId);
    expect(client.isClosed, isTrue);
  });
}
