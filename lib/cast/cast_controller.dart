import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../core/api/api_config.dart';
import '../core/models/catalog.dart';
import '../features/live/live_controller.dart';
import 'cast_client.dart';
import 'cast_discovery.dart';

enum CastPhase { idle, connecting, casting }

/// Chromecast for the main player: finds devices, starts the ZipStreams
/// receiver on one and hands it to [LiveController] as its output.
class CastController extends ChangeNotifier {
  CastController({
    required this.live,
    required this.config,
    CastDiscovery? discovery,
    Future<CastClient> Function(CastDevice device)? connect,
  })  : _discovery = discovery ?? CastDiscovery(),
        _connect = connect ?? CastClient.connect;

  /// The ZipStreams receiver application registered with Google Cast.
  static const receiverAppId = '086CC7D3';

  /// The backend serves HLS (`apple_stream`) to every client.
  static const contentType = 'application/x-mpegurl';

  final LiveController live;
  final ApiConfig config;
  final CastDiscovery _discovery;
  final Future<CastClient> Function(CastDevice device) _connect;

  List<CastDevice> _devices = const [];
  bool _scanning = false;
  CastPhase _phase = CastPhase.idle;
  CastDevice? _device;
  String? _error;
  _CastOutput? _output;
  bool _disposed = false;

  /// Devices found by the last [scan].
  List<CastDevice> get devices => _devices;
  bool get scanning => _scanning;
  CastPhase get phase => _phase;

  /// The device being connected to or cast to.
  CastDevice? get device => _device;

  /// Why the last attempt to cast failed, until the next one.
  String? get error => _error;

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    _notify();
    try {
      _devices = await _discovery.scan();
    } catch (e) {
      _error = "Couldn't look for devices: $e";
    } finally {
      _scanning = false;
      _notify();
    }
  }

  /// Starts the receiver on [device] and sends the channel there.
  Future<void> castTo(CastDevice device) async {
    if (_device == device && _phase != CastPhase.idle) return;
    await stop();
    _device = device;
    _error = null;
    _phase = CastPhase.connecting;
    _notify();
    CastClient? client;
    try {
      client = await _connect(device);
      await client.launch(receiverAppId);
    } catch (e) {
      unawaited(client?.close());
      if (_device != device) return;
      _device = null;
      _phase = CastPhase.idle;
      _error = "Couldn't cast to ${device.name}: $e";
      _notify();
      return;
    }
    // Cancelled while connecting.
    if (_device != device || _disposed) {
      unawaited(client.stopApp());
      return;
    }
    final output = _CastOutput(client, config);
    _output = output;
    _phase = CastPhase.casting;
    _notify();
    unawaited(client.done.then((reason) => _onGone(output, reason)));
    await live.startCasting(output);
  }

  /// Closes the receiver and, unless [resumeHere] is false, brings
  /// playback back to this window.
  Future<void> stop({bool resumeHere = true}) async {
    final output = _output;
    _output = null;
    _device = null;
    final wasIdle = _phase == CastPhase.idle;
    _phase = CastPhase.idle;
    if (!wasIdle) _notify();
    if (output == null) return;
    await live.stopCasting(stopDevice: false, resumeHere: resumeHere);
    await output.close();
  }

  void _onGone(_CastOutput output, String reason) {
    if (!identical(_output, output)) return;
    _output = null;
    _device = null;
    _phase = CastPhase.idle;
    _error = reason == 'Closed' ? null : reason;
    output.gone(reason);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final output = _output;
    _output = null;
    if (output != null) unawaited(output.close());
    super.dispose();
  }
}

/// The live controller's view of one cast session.
class _CastOutput implements RemoteOutput {
  _CastOutput(this._client, this._config) {
    _statusSub = _client.mediaStatus.listen(_onStatus);
  }

  final CastClient _client;
  final ApiConfig _config;
  final _events = StreamController<RemoteEvent>.broadcast();
  late final StreamSubscription<CastMediaStatus> _statusSub;

  // Set while a load is in flight, so the IDLE (INTERRUPTED) that replacing
  // the previous stream causes isn't taken for the new one failing.
  bool _loading = false;

  @override
  String get name => _client.device.name;

  @override
  Stream<RemoteEvent> get events => _events.stream;

  @override
  Future<void> load(String url, Channel channel) async {
    _loading = true;
    try {
      await _client.load(
        url: url,
        contentType: CastController.contentType,
        title: channel.name,
        subtitle: channel.nowPlaying?.title,
        // The receiver plays the URL itself. The CDN expects the same
        // headers the apps send; a receiver that can set them finds them here.
        customData: {
          'streamId': channel.id,
          'headers': {
            'User-Agent': ApiConfig.mediaUserAgent,
            'Referer': _config.referer,
          },
        },
      );
    } finally {
      _loading = false;
    }
  }

  @override
  Future<void> stopMedia() async => _client.stopMedia();

  @override
  Future<void> setVolume(double volume) async => _client.setVolume(volume / 100);

  void _onStatus(CastMediaStatus status) {
    if (_events.isClosed) return;
    switch (status.state) {
      case CastPlayerState.playing:
        _events.add(const RemotePlaying());
      case CastPlayerState.idle when !_loading:
        switch (status.idleReason) {
          case 'FINISHED':
            _events.add(const RemoteEnded());
          case 'ERROR':
            _events.add(const RemoteFailed('the TV could not play the stream'));
          // CANCELLED (stopped from the TV or its remote) and INTERRUPTED
          // (another load) need nothing from here.
        }
      default:
        break;
    }
  }

  void gone(String reason) {
    if (_events.isClosed) return;
    _events.add(RemoteGone(reason));
    unawaited(_statusSub.cancel());
    unawaited(_events.close());
  }

  Future<void> close() async {
    await _statusSub.cancel();
    await _client.stopApp();
    await _events.close();
  }
}
