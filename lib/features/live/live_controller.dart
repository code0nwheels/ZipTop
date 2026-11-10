import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../player/mpv_player.dart';

/// Joins the catalogue, the server session and mpv for the main player:
/// tuning, zapping, number entry, and recovering when playback dies.
class LiveController extends ChangeNotifier {
  LiveController({
    required this.catalog,
    required this.settings,
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

  static const unsupportedMessage =
      "This channel uses a stream format (DASH) that ZipTop can't play yet.";
  static const maxNumberDigits = 4;
  static const numberCommitDelay = Duration(seconds: 2);
  static const numberErrorFlash = Duration(milliseconds: 700);
  static const _errorGrace = Duration(seconds: 4);
  static const _stallLimit = Duration(seconds: 30);

  final CatalogStore catalog;
  final SettingsStore settings;
  final PlaybackSession session;
  final MpvPlayer player;

  late final List<StreamSubscription<dynamic>> _subs;
  final _retry = RetryPolicy();

  Channel? _current;
  Channel? _previous;
  List<String>? _scopeIds;
  String? _scopeName;
  String? _playingUrl;
  String? _failure;
  Duration _position = Duration.zero;
  String _digits = '';
  bool _digitsInvalid = false;
  double _unmutedVolume = 100;
  Timer? _digitsTimer;
  Timer? _retryTimer;
  Timer? _errorTimer;
  Timer? _stallTimer;
  Timer? _pollTimer;
  bool _disposed = false;

  Channel? get current => _current;
  Channel? get previous => _previous;

  /// Set when retries ran out; cleared by [retryNow] or tuning.
  String? get failure => _failure;

  /// Digits typed so far for a channel number, empty when not entering one.
  String get numberEntry => _digits;

  /// True briefly after a number that matches no channel.
  bool get numberEntryInvalid => _digitsInvalid;

  /// The row Up/Down zaps within, or null for All channels.
  String? get scopeName => _scopeName;

  /// Channels the viewer recently tuned here, most recent first.
  List<Channel> get recents => [
        for (final id in settings.recentIds)
          if (catalog.channelsById[id] != null) catalog.channelsById[id]!,
      ];

  /// What Up/Down moves through: the row last tuned from, else All channels.
  List<Channel> get zapChannels {
    final ids = _scopeIds;
    if (ids != null) {
      final scoped = [
        for (final id in ids)
          if (catalog.channelsById[id] != null) catalog.channelsById[id]!,
      ];
      if (scoped.isNotEmpty) return scoped;
    }
    return catalog.allChannels;
  }

  /// Loads the catalogue and, if the viewer wants it, resumes the last channel.
  Future<void> boot() async {
    await catalog.refresh();
    unawaited(catalog.refreshLiveIfStale());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(catalog.refreshLiveIfStale());
      unawaited(catalog.refreshIfStale());
    });
    unawaited(player.player.setVolume(settings.volume));

    if (!settings.playLastOnStart) return;
    final channels = catalog.allChannels;
    if (channels.isEmpty) return;
    final last = catalog.channelsById[settings.lastChannelId];
    await tune(last ?? channels.first);
  }

  /// Tunes [channel]. When it was picked from a row, pass that row as [scope]
  /// so Up/Down stay inside it.
  Future<void> tune(Channel channel, {List<Channel>? scope, String? scopeName}) async {
    if (scope != null) {
      _scopeIds = [for (final c in scope) c.id];
      _scopeName = scopeName;
    }
    if (_current?.id == channel.id && session.phase == SessionPhase.playing) {
      notifyListeners();
      return;
    }
    if (_current != null && _current!.id != channel.id) _previous = _current;
    _current = channel;
    _failure = null;
    _retry.reset();
    _cancelRecovery();
    _playingUrl = null;
    notifyListeners();
    unawaited(player.stop());
    settings.rememberChannel(channel.id);
    await session.open(channel.id, iptv: channel.isIptv);
  }

  /// Moves [step] channels through [zapChannels], wrapping at the ends.
  Future<void> zap(int step) async {
    final channels = zapChannels;
    if (channels.isEmpty) return;
    final index = channels.indexWhere((c) => c.id == _current?.id);
    final next = index < 0 && step < 0
        ? channels.last
        : channels[(index + step) % channels.length];
    await tune(next);
  }

  Future<void> tunePrevious() async {
    final previous = _previous;
    if (previous != null) await tune(previous);
  }

  /// Adds a digit to the channel number being typed. It commits by itself
  /// after a pause, or at once with [commitNumber].
  void typeDigit(int digit) {
    if (_digitsInvalid) return;
    if (_digits.length >= maxNumberDigits) return;
    _digits += '$digit';
    _digitsTimer?.cancel();
    _digitsTimer = Timer(numberCommitDelay, commitNumber);
    notifyListeners();
  }

  void commitNumber() {
    _digitsTimer?.cancel();
    if (_digits.isEmpty || _digitsInvalid) return;
    final number = int.tryParse(_digits);
    Channel? match;
    for (final channel in catalog.allChannels) {
      if (channel.number == number) {
        match = channel;
        break;
      }
    }
    if (match == null) {
      _digitsInvalid = true;
      notifyListeners();
      _digitsTimer = Timer(numberErrorFlash, cancelNumber);
      return;
    }
    _digits = '';
    // A typed number can be anywhere, so zapping widens back to every channel.
    _scopeIds = null;
    _scopeName = null;
    unawaited(tune(match));
  }

  void cancelNumber() {
    _digitsTimer?.cancel();
    if (_digits.isEmpty && !_digitsInvalid) return;
    _digits = '';
    _digitsInvalid = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    settings.volume = volume;
    await player.player.setVolume(settings.volume);
  }

  Future<void> toggleMute() async {
    if (settings.volume > 0) {
      _unmutedVolume = settings.volume;
      await setVolume(0);
    } else {
      await setVolume(_unmutedVolume > 0 ? _unmutedVolume : 100);
    }
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

  /// Stops playback and gives the server slot back, keeping the channel so
  /// [resume] can pick it up again (while multiview has the screen).
  Future<void> suspend() async {
    _cancelRecovery();
    cancelNumber();
    _playingUrl = null;
    unawaited(player.stop());
    await session.close();
  }

  Future<void> resume() => retryNow();

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
    if (_playingUrl == null || !isReloadableError(message)) return;
    // mpv also reports recoverable hiccups here. Only treat it as fatal if
    // playback has not moved on a few seconds later.
    final mark = _position;
    _errorTimer?.cancel();
    _errorTimer = Timer(_errorGrace, () {
      // Still loading is the stall timer's business, not an error.
      if (_position == mark && !player.player.state.buffering) {
        _recover(_retry.nextAfterError());
      }
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

  @override
  void dispose() {
    _disposed = true;
    _cancelRecovery();
    _pollTimer?.cancel();
    _digitsTimer?.cancel();
    session.removeListener(_onSession);
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
