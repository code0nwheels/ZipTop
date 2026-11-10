import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../player/mpv_player.dart';

/// Joins the catalogue, the server session and mpv for the main player:
/// tuning, zapping, and recovering when playback dies.
class LiveController extends ChangeNotifier {
  LiveController({
    required this.catalog,
    required this.session,
    required this.player,
  }) {
    session.addListener(_onSession);
    _subs = [
      player.player.stream.completed.listen((done) {
        if (done) _onEnded();
      }),
      player.player.stream.error.listen(_onError),
      player.player.stream.position.listen(_onPosition),
      player.player.stream.buffering.listen(_onBuffering),
    ];
  }

  static const _lastChannelKey = 'last_stream_id';
  static const unsupportedMessage =
      "This channel uses a stream format (DASH) that ZipTop can't play yet.";
  static const _errorGrace = Duration(seconds: 4);
  static const _stallLimit = Duration(seconds: 30);

  final CatalogStore catalog;
  final PlaybackSession session;
  final MpvPlayer player;

  late final List<StreamSubscription<dynamic>> _subs;
  final _retry = RetryPolicy();

  Channel? _current;
  Channel? _previous;
  String? _playingUrl;
  String? _failure;
  Duration _position = Duration.zero;
  Timer? _retryTimer;
  Timer? _errorTimer;
  Timer? _stallTimer;
  Timer? _pollTimer;
  bool _disposed = false;

  Channel? get current => _current;
  Channel? get previous => _previous;

  /// Set when retries ran out; cleared by [retryNow] or tuning.
  String? get failure => _failure;

  /// Loads the catalogue and tunes the last channel watched, or the first.
  Future<void> boot() async {
    await catalog.refresh();
    unawaited(catalog.refreshLiveIfStale());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(catalog.refreshLiveIfStale());
      unawaited(catalog.refreshIfStale());
    });

    final channels = catalog.allChannels;
    if (channels.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final last = catalog.channelsById[prefs.getString(_lastChannelKey)];
    await tune(last ?? channels.first);
  }

  Future<void> tune(Channel channel) async {
    if (_current?.id == channel.id && session.phase == SessionPhase.playing) return;
    if (_current != null && _current!.id != channel.id) _previous = _current;
    _current = channel;
    _failure = null;
    _retry.reset();
    _cancelRecovery();
    _playingUrl = null;
    notifyListeners();
    unawaited(player.stop());
    unawaited(_remember(channel.id));
    await session.open(channel.id, iptv: channel.isIptv);
  }

  /// Moves [step] channels through All channels, wrapping at the ends.
  Future<void> zap(int step) async {
    final channels = catalog.allChannels;
    if (channels.isEmpty) return;
    final index = channels.indexWhere((c) => c.id == _current?.id);
    final next = channels[(index + step) % channels.length];
    await tune(next);
  }

  Future<void> tunePrevious() async {
    final previous = _previous;
    if (previous != null) await tune(previous);
  }

  /// Manual retry from the error state.
  Future<void> retryNow() async {
    final channel = _current;
    if (channel == null) return;
    _failure = null;
    _retry.reset();
    _cancelRecovery();
    notifyListeners();
    if (session.streamId == channel.id) {
      await session.reopen();
    } else {
      await session.open(channel.id, iptv: channel.isIptv);
    }
  }

  /// Stops playback and releases the server slot (sign-out, app exit).
  Future<void> shutdown() async {
    _cancelRecovery();
    _pollTimer?.cancel();
    _playingUrl = null;
    unawaited(player.stop());
    await session.close();
  }

  void _onSession() {
    final url = session.url;
    if (session.phase == SessionPhase.playing && url != null) {
      if (url != _playingUrl) {
        _playingUrl = url;
        _position = Duration.zero;
        unawaited(_start(url));
      }
    } else if (session.phase != SessionPhase.preparing) {
      // Failed, limited, kicked or closed: nothing should keep playing.
      _cancelRecovery();
      if (_playingUrl != null) {
        _playingUrl = null;
        unawaited(player.stop());
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _start(String url) async {
    final playable = await player.canPlay(url);
    // The viewer may have moved on while the player was getting ready.
    if (_disposed || _playingUrl != url) return;
    if (playable) {
      await player.play(url);
      return;
    }
    // Give the server slot back; this stream can't be shown.
    _playingUrl = null;
    _failure = unsupportedMessage;
    await session.close();
  }

  void _onPosition(Duration position) {
    // Real progress means the stream is healthy again.
    if (position > _position + const Duration(seconds: 2)) {
      _position = position;
      _retry.reset();
      _errorTimer?.cancel();
    }
  }

  void _onBuffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering && _playingUrl != null) {
      _stallTimer = Timer(_stallLimit, () => _recover(_retry.nextAfterError()));
    }
  }

  void _onEnded() {
    if (_playingUrl == null) return;
    _recover(_retry.nextAfterEnded());
  }

  void _onError(String message) {
    if (_playingUrl == null) return;
    // mpv also reports recoverable hiccups here. Only treat it as fatal if
    // playback has not moved on a few seconds later.
    final mark = _position;
    _errorTimer?.cancel();
    _errorTimer = Timer(_errorGrace, () {
      if (_position == mark) _recover(_retry.nextAfterError());
    });
  }

  void _recover(Duration? wait) {
    if (_playingUrl == null || _retryTimer?.isActive == true) return;
    if (wait == null) {
      _failure = "This channel isn't playing right now.";
      _playingUrl = null;
      unawaited(player.stop());
      if (!_disposed) notifyListeners();
      return;
    }
    final channelId = _current?.id;
    _retryTimer = Timer(wait, () {
      // Dropped if the viewer has moved to another channel meanwhile.
      if (_disposed || _current?.id != channelId) return;
      _playingUrl = null;
      unawaited(session.reopen());
    });
  }

  void _cancelRecovery() {
    _retryTimer?.cancel();
    _errorTimer?.cancel();
    _stallTimer?.cancel();
  }

  Future<void> _remember(String streamId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastChannelKey, streamId);
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRecovery();
    _pollTimer?.cancel();
    session.removeListener(_onSession);
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
