import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cast_message.dart';

/// A Chromecast (or Google TV, or speaker) found on the network.
@immutable
class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.host,
    this.port = 8009,
    this.model,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String? model;

  @override
  bool operator ==(Object other) =>
      other is CastDevice && other.id == id && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(id, host, port);

  @override
  String toString() => 'CastDevice($name, $host:$port)';
}

enum CastPlayerState { idle, buffering, playing, paused }

/// The receiver's `MEDIA_STATUS` for the one media session ZipTop runs.
@immutable
class CastMediaStatus {
  const CastMediaStatus({required this.state, this.idleReason, this.mediaSessionId});

  final CastPlayerState state;

  /// `FINISHED`, `ERROR`, `CANCELLED` or `INTERRUPTED` while [state] is idle.
  final String? idleReason;
  final int? mediaSessionId;

  /// The first entry of a `MEDIA_STATUS` payload, or null when it has none
  /// (no media loaded).
  static CastMediaStatus? fromPayload(Map<String, Object?> data) {
    final list = data['status'];
    if (list is! List || list.isEmpty || list.first is! Map) return null;
    final status = (list.first as Map).cast<String, Object?>();
    final state = switch (status['playerState']) {
      'PLAYING' => CastPlayerState.playing,
      'BUFFERING' || 'LOADING' => CastPlayerState.buffering,
      'PAUSED' => CastPlayerState.paused,
      _ => CastPlayerState.idle,
    };
    return CastMediaStatus(
      state: state,
      idleReason: status['idleReason'] as String?,
      mediaSessionId: (status['mediaSessionId'] as num?)?.toInt(),
    );
  }
}

/// A running receiver application, from `RECEIVER_STATUS`.
@immutable
class CastApp {
  const CastApp({required this.appId, required this.sessionId, required this.transportId});

  final String appId;
  final String sessionId;
  final String transportId;

  /// The application running [appId] in a `RECEIVER_STATUS` payload.
  static CastApp? find(Map<String, Object?> data, String appId) {
    final status = data['status'];
    if (status is! Map) return null;
    final apps = status['applications'];
    if (apps is! List) return null;
    for (final app in apps) {
      if (app is! Map || app['appId'] != appId) continue;
      final session = app['sessionId'];
      final transport = app['transportId'];
      if (session is String && transport is String) {
        return CastApp(appId: appId, sessionId: session, transportId: transport);
      }
    }
    return null;
  }
}

class CastException implements Exception {
  const CastException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One Cast v2 connection to a device: TLS on port 8009, a virtual
/// connection to the platform receiver and, once [launch] has run, one to
/// the receiver application.
class CastClient {
  CastClient._(this.device, this._socket) {
    _sub = _socket.listen(
      _onData,
      onError: (Object e) => _close('Connection lost: $e'),
      onDone: () => _close('The device closed the connection'),
      cancelOnError: true,
    );
  }

  static const _sender = 'sender-0';
  static const _platform = 'receiver-0';
  static const _requestTimeout = Duration(seconds: 15);
  static const _pingEvery = Duration(seconds: 5);

  /// Nothing heard for this long and the device is gone.
  static const _silenceLimit = Duration(seconds: 16);

  /// Connects to [device]. Cast devices present a certificate signed by
  /// Google's device CA, which no system trust store has, so it isn't
  /// checked; there is nothing secret on this channel.
  static Future<CastClient> connect(
    CastDevice device, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final socket = await SecureSocket.connect(
      device.host,
      device.port,
      timeout: timeout,
      onBadCertificate: (_) => true,
    );
    final client = CastClient._(device, socket);
    client._send(CastNamespace.connection, _platform, {'type': 'CONNECT'});
    client._lastHeard = DateTime.now();
    client._pinger = Timer.periodic(_pingEvery, (_) => client._ping());
    return client;
  }

  final CastDevice device;
  final SecureSocket _socket;
  late final StreamSubscription<List<int>> _sub;
  final _reader = CastFrameReader();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _mediaStatus = StreamController<CastMediaStatus>.broadcast();
  final _done = Completer<String>();
  Timer? _pinger;
  DateTime _lastHeard = DateTime.now();
  int _nextRequest = 1;
  CastApp? _app;
  int? _mediaSessionId;

  /// Media status from the receiver application.
  Stream<CastMediaStatus> get mediaStatus => _mediaStatus.stream;

  /// Completes, with the reason, when the connection ends or the receiver
  /// application stops (closed on the TV, or another sender took over).
  Future<String> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Starts the receiver [appId] (or joins it if it is already running) and
  /// connects to it.
  Future<void> launch(String appId) async {
    final reply = await _request(
      CastNamespace.receiver,
      _platform,
      {'type': 'LAUNCH', 'appId': appId},
      until: (data) => data['type'] == 'LAUNCH_ERROR' || CastApp.find(data, appId) != null,
    );
    if (reply['type'] == 'LAUNCH_ERROR') {
      throw CastException('The TV refused to start ZipStreams (${reply['reason'] ?? 'error'})');
    }
    final app = CastApp.find(reply, appId)!;
    _app = app;
    _send(CastNamespace.connection, app.transportId, {'type': 'CONNECT'});
  }

  /// Plays [url] on the receiver application.
  Future<CastMediaStatus?> load({
    required String url,
    required String contentType,
    required String title,
    String? subtitle,
    Map<String, Object?>? customData,
  }) async {
    final app = _app;
    if (app == null) throw const CastException('Not connected to the receiver');
    final reply = await _request(
      CastNamespace.media,
      app.transportId,
      {
        'type': 'LOAD',
        'sessionId': app.sessionId,
        'autoplay': true,
        'media': {
          'contentId': url,
          'contentUrl': url,
          'contentType': contentType,
          'streamType': 'LIVE',
          'metadata': {
            'metadataType': 0,
            'title': title,
            if (subtitle != null && subtitle.isNotEmpty) 'subtitle': subtitle,
          },
          'customData': ?customData,
        },
        'customData': ?customData,
      },
    );
    switch (reply['type']) {
      case 'LOAD_FAILED' || 'LOAD_CANCELLED' || 'INVALID_REQUEST':
        throw CastException(
          'The TV could not play this channel (${reply['reason'] ?? reply['type']})',
        );
    }
    return CastMediaStatus.fromPayload(reply);
  }

  /// Stops the media but leaves the receiver application running.
  void stopMedia() {
    final app = _app;
    final media = _mediaSessionId;
    if (app == null || media == null || isClosed) return;
    _send(CastNamespace.media, app.transportId, {
      'type': 'STOP',
      'mediaSessionId': media,
      'requestId': _nextRequest++,
    });
  }

  /// Sets the device volume, 0 to 1.
  void setVolume(double level) {
    if (isClosed) return;
    _send(CastNamespace.receiver, _platform, {
      'type': 'SET_VOLUME',
      'volume': {'level': level.clamp(0.0, 1.0)},
      'requestId': _nextRequest++,
    });
  }

  /// Quits the receiver application, which returns the TV to its idle
  /// screen, and closes the connection.
  Future<void> stopApp() async {
    final app = _app;
    if (app != null && !isClosed) {
      _send(CastNamespace.receiver, _platform, {
        'type': 'STOP',
        'sessionId': app.sessionId,
        'requestId': _nextRequest++,
      });
      await _socket.flush().timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await close();
  }

  /// Closes the connection, leaving whatever is playing on the device.
  Future<void> close() async {
    if (!isClosed) {
      final app = _app;
      if (app != null) _send(CastNamespace.connection, app.transportId, {'type': 'CLOSE'});
      _send(CastNamespace.connection, _platform, {'type': 'CLOSE'});
      try {
        await _socket.flush().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _close('Closed');
  }

  void _ping() {
    if (DateTime.now().difference(_lastHeard) > _silenceLimit) {
      _close('The device stopped answering');
      return;
    }
    _send(CastNamespace.heartbeat, _platform, {'type': 'PING'});
  }

  Future<Map<String, Object?>> _request(
    String namespace,
    String destination,
    Map<String, Object?> data, {
    bool Function(Map<String, Object?> reply)? until,
  }) {
    if (isClosed) return Future.error(const CastException('Not connected'));
    final id = _nextRequest++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send(namespace, destination, {...data, 'requestId': id});
    // A launch is answered with RECEIVER_STATUS as the app comes up, which
    // may take more than one status.
    final wait = until == null
        ? completer.future
        : _untilMatching(completer.future, id, until);
    return wait.timeout(_requestTimeout, onTimeout: () {
      _pending.remove(id);
      throw const CastException('The TV did not answer');
    });
  }

  Future<Map<String, Object?>> _untilMatching(
    Future<Map<String, Object?>> first,
    int id,
    bool Function(Map<String, Object?>) until,
  ) async {
    var reply = await first;
    while (!until(reply)) {
      final next = Completer<Map<String, Object?>>();
      _pending[id] = next;
      reply = await next.future;
    }
    return reply;
  }

  void _send(String namespace, String destination, Map<String, Object?> data) {
    if (isClosed) return;
    try {
      _socket.add(CastMessage.json(
        source: _sender,
        destination: destination,
        namespace: namespace,
        data: data,
      ).frame());
    } catch (e) {
      _close('Connection lost: $e');
    }
  }

  void _onData(List<int> chunk) {
    final List<CastMessage> messages;
    try {
      messages = _reader.add(chunk);
    } catch (e) {
      _close('Bad data from the device: $e');
      return;
    }
    _lastHeard = DateTime.now();
    for (final message in messages) {
      _handle(message);
    }
  }

  void _handle(CastMessage message) {
    final data = message.data;
    if (data == null) return;
    final type = data['type'];

    if (message.namespace == CastNamespace.heartbeat) {
      if (type == 'PING') _send(CastNamespace.heartbeat, message.source, {'type': 'PONG'});
      return;
    }
    if (message.namespace == CastNamespace.connection && type == 'CLOSE') {
      final app = _app;
      if (app != null && message.source == app.transportId) {
        _close('ZipStreams was closed on the TV');
      } else if (message.source == _platform) {
        _close('The device closed the connection');
      }
      return;
    }
    if (message.namespace == CastNamespace.receiver && type == 'RECEIVER_STATUS') {
      final app = _app;
      // Our application stopped, or another sender started something else.
      if (app != null && CastApp.find(data, app.appId)?.sessionId != app.sessionId) {
        _close('ZipStreams was closed on the TV');
        return;
      }
    }
    if (message.namespace == CastNamespace.media && type == 'MEDIA_STATUS') {
      final status = CastMediaStatus.fromPayload(data);
      if (status != null) {
        if (status.mediaSessionId != null) _mediaSessionId = status.mediaSessionId;
        _mediaStatus.add(status);
      }
    }

    final requestId = (data['requestId'] as num?)?.toInt();
    if (requestId != null && requestId != 0) {
      final completer = _pending.remove(requestId);
      if (completer != null && !completer.isCompleted) completer.complete(data);
    }
  }

  void _close(String reason) {
    if (_done.isCompleted) return;
    _done.complete(reason);
    _pinger?.cancel();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(CastException(reason));
    }
    _pending.clear();
    unawaited(_sub.cancel());
    _socket.destroy();
    unawaited(_mediaStatus.close());
  }
}
