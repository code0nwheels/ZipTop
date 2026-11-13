import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../player/live_player.dart';
import '../../player/mpv_player.dart' show ProgressTracker, RetryPolicy, isReloadableError;

/// What happened to the stream on a [RemoteOutput].
sealed class RemoteEvent {
  const RemoteEvent();
}

/// Playing: the stream is healthy.
class RemotePlaying extends RemoteEvent {
  const RemotePlaying();
}

/// The stream ran out, as live streams sometimes do; it needs a new URL.
class RemoteEnded extends RemoteEvent {
  const RemoteEnded();
}

class RemoteFailed extends RemoteEvent {
  const RemoteFailed(this.message);
  final String message;
}

/// The device went away or was taken over; playback comes back here.
class RemoteGone extends RemoteEvent {
  const RemoteGone(this.message);
  final String message;
}

/// Somewhere other than this window to send the stream: a Chromecast.
///
/// The server session (heartbeats included) keeps running here, so the
/// device only ever gets the signed URL.
abstract class RemoteOutput {
  /// Shown as "Casting to [name]".
  String get name;

  /// Plays [url], the signed stream for [channel], on the device.
  Future<void> load(String url, Channel channel);

  /// Stops what the device is playing.
  Future<void> stopMedia();

  /// 0 to 100.
  Future<void> setVolume(double volume);

  Stream<RemoteEvent> get events;
}

/// Joins the catalogue, the server session and the player for the main
/// video: tuning, zapping, number entry, casting, and recovering when
/// playback dies.
class LiveController extends ChangeNotifier {
  LiveController({
    required this.catalog,
    required this.settings,
    required this.session,
    required this.player,
  }) {
    session.addListener(_onSession);
    // While casting, this window's player is stopped and the device's
    // events count instead.
    _subs = [
      player.completed.listen((done) {
        if (done && _remote == null) _onEnded();
      }),
      player.errors.listen((message) {
        if (_remote == null) _onError(message);
      }),
      player.position.listen((position) {
        if (_remote == null) _onPosition(position);
      }),
      player.buffering.listen((buffering) {
        if (_remote == null) _onBuffering(buffering);
      }),
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
  final LivePlayer player;

  late final List<StreamSubscription<dynamic>> _subs;
  final _retry = RetryPolicy();

  Channel? _current;
  Channel? _previous;
  List<String>? _scopeIds;
  String? _scopeName;
  String? _playingUrl;
  String? _failure;
  final _progress = ProgressTracker();
  SessionPhase? _loggedPhase;
  String _digits = '';
  bool _digitsInvalid = false;
  double _unmutedVolume = 100;
  Timer? _digitsTimer;
  Timer? _retryTimer;
  Timer? _errorTimer;
  Timer? _stallTimer;
  Timer? _pollTimer;
  bool _disposed = false;
  RemoteOutput? _remote;
  StreamSubscription<RemoteEvent>? _remoteSub;

  Channel? get current => _current;

  /// The device the stream is cast to, or null when it plays here.
  RemoteOutput? get remote => _remote;
  Channel? get previous => _previous;

  /// Set when retries ran out; cleared by [retryNow] or tuning.
  String? get failure => _failure;

  /// Digits typed so far for a channel number, empty when not entering one.
  String get numberEntry => _digits;

  /// True briefly after a number that matches no channel.
  bool get numberEntryInvalid => _digitsInvalid;

  /// Whether the "Stats for nerds" panel is over the video. Not saved.
  bool get statsVisible => _statsVisible;
  bool _statsVisible = false;

  void toggleStats() {
    _statsVisible = !_statsVisible;
    notifyListeners();
  }

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
  ///
  /// With [autoplay] false nothing is tuned, for a start hidden in the
  /// notification area.
  Future<void> boot({bool autoplay = true}) async {
    await catalog.refresh();
    unawaited(catalog.refreshLiveIfStale());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(catalog.refreshLiveIfStale());
      unawaited(catalog.refreshIfStale());
    });
    unawaited(player.setVolume(settings.volume));

    if (!autoplay) return;
    await _tuneLast();
  }

  Future<void> _tuneLast() async {
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

  /// Sets the volume of whatever is playing: this window, or the TV while
  /// casting.
  Future<void> setVolume(double volume) async {
    settings.volume = volume;
    final remote = _remote;
    if (remote != null) {
      await remote.setVolume(settings.volume);
    } else {
      await player.setVolume(settings.volume);
    }
  }

  /// Sends the stream to [remote] instead of this window. The channel keeps
  /// its server session; the device gets the URL.
  Future<void> startCasting(RemoteOutput remote) async {
    if (identical(_remote, remote)) return;
    await _remoteSub?.cancel();
    _remote = remote;
    _remoteSub = remote.events.listen(_onRemote);
    _cancelRecovery();
    _retry.reset();
    unawaited(player.stop());
    unawaited(player.note('casting to ${remote.name}'));
    notifyListeners();
    final url = session.url;
    if (_current == null) return;
    if (session.phase == SessionPhase.playing && url != null) {
      _playingUrl = url;
      await _start(url);
    } else if (session.phase != SessionPhase.preparing) {
      await retryNow();
    }
  }

  /// Brings the stream back to this window from the device. With
  /// [stopDevice] false the device is left alone (it has gone, or someone
  /// else is using it); with [resumeHere] false nothing restarts here (the
  /// app is about to stop live playback anyway).
  Future<void> stopCasting({bool stopDevice = true, bool resumeHere = true}) async {
    final remote = _remote;
    if (remote == null) return;
    _remote = null;
    await _remoteSub?.cancel();
    _remoteSub = null;
    _cancelRecovery();
    if (stopDevice) unawaited(remote.stopMedia());
    unawaited(player.note('stopped casting'));
    unawaited(player.setVolume(settings.volume));
    if (!_disposed) notifyListeners();
    // The URL may be close to expiring; a fresh one starts cleanly.
    if (resumeHere && _current != null && _playingUrl != null) {
      _playingUrl = null;
      _retry.reset();
      await session.reopen();
    }
  }

  void _onRemote(RemoteEvent event) {
    switch (event) {
      case RemoteGone():
        unawaited(stopCasting(stopDevice: false));
      case _ when _playingUrl == null:
        return;
      case RemotePlaying():
        _retry.reset();
        _errorTimer?.cancel();
      case RemoteEnded():
        _recover(_retry.nextAfterEnded(), 'cast: stream ended');
      case RemoteFailed(:final message):
        _recover(_retry.nextAfterError(), 'cast: $message');
    }
  }

  /// Stops this window's player and anything playing on the device.
  void _stopOutput() {
    unawaited(player.stop());
    final remote = _remote;
    if (remote != null) unawaited(remote.stopMedia());
  }

  Future<void> toggleMute() async {
    if (settings.volume > 0) {
      _unmutedVolume = settings.volume;
      await setVolume(0);
    } else {
      await setVolume(_unmutedVolume > 0 ? _unmutedVolume : 100);
    }
  }

  /// The bitrate cap the viewer picked, or null for the best there is.
  int? get maxBitrate => settings.maxBitrate;

  /// Caps the bitrate for this and later channels, and reopens the playing
  /// stream at it: mpv only picks a variant when a stream opens.
  Future<void> setMaxBitrate(int? bitsPerSecond) async {
    final cap = bitsPerSecond == null || bitsPerSecond <= 0 ? null : bitsPerSecond;
    if (cap == settings.maxBitrate) return;
    settings.maxBitrate = cap;
    unawaited(player.note('bitrate cap ${cap ?? 'none'}, reopening'));
    final channel = _current;
    if (channel == null || _playingUrl == null || session.streamId != channel.id) return;
    _cancelRecovery();
    _retry.reset();
    _playingUrl = null;
    await session.reopen();
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
    _stopOutput();
    await session.close();
  }

  Future<void> resume() => _current == null ? _tuneLast() : retryNow();

  /// Stops playback and releases the server slot (sign-out, app exit).
  Future<void> shutdown() async {
    _cancelRecovery();
    _pollTimer?.cancel();
    _playingUrl = null;
    _stopOutput();
    await session.close();
  }

  void _onSession() {
    final url = session.url;
    if (session.phase != _loggedPhase) {
      _loggedPhase = session.phase;
      final why = session.message;
      unawaited(player.note('session ${session.phase.name}${why == null ? '' : ': $why'}'));
    }
    if (session.phase == SessionPhase.playing && url != null) {
      if (url != _playingUrl) {
        _playingUrl = url;
        _progress.restart();
        unawaited(_start(url));
      }
    } else if (session.phase != SessionPhase.preparing) {
      // Failed, limited, kicked or closed: nothing should keep playing.
      _cancelRecovery();
      if (_playingUrl != null) {
        _playingUrl = null;
        _stopOutput();
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _start(String url) async {
    final remote = _remote;
    final channel = _current;
    if (remote != null && channel != null) {
      try {
        await remote.load(url, channel);
      } catch (e) {
        if (_disposed || _playingUrl != url || !identical(_remote, remote)) return;
        _recover(_retry.nextAfterError(), 'cast load failed: $e');
      }
      return;
    }
    final playable = await player.canPlay(url);
    // The viewer may have moved on while the player was getting ready.
    if (_disposed || _playingUrl != url) return;
    if (playable) {
      await player.setHlsBitrateCap(settings.maxBitrate);
      if (_disposed || _playingUrl != url) return;
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
    if (_progress.update(position)) {
      _retry.reset();
      _errorTimer?.cancel();
    }
  }

  void _onBuffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering && _playingUrl != null) {
      _stallTimer = Timer(
        _stallLimit,
        () => _recover(_retry.nextAfterError(), 'buffering for ${_stallLimit.inSeconds} s'),
      );
    }
  }

  void _onEnded() {
    if (_playingUrl == null) return;
    _recover(_retry.nextAfterEnded(), 'stream ended');
  }

  void _onError(String message) {
    if (_playingUrl == null || !isReloadableError(message)) return;
    // mpv also reports recoverable hiccups here. Only treat it as fatal if
    // playback has not moved on a few seconds later.
    final mark = _progress.played;
    _errorTimer?.cancel();
    _errorTimer = Timer(_errorGrace, () {
      // Still loading is the stall timer's business, not an error.
      if (!_progress.movedSince(mark) && !player.isBuffering) {
        _recover(_retry.nextAfterError(), 'error with no progress: $message');
      }
    });
  }

  void _recover(Duration? wait, String reason) {
    if (_playingUrl == null || _retryTimer?.isActive == true) return;
    unawaited(player.note('reload (${wait == null ? 'giving up' : 'in ${wait.inSeconds} s'}): $reason'));
    if (wait == null) {
      _failure = "This channel isn't playing right now.";
      _playingUrl = null;
      _stopOutput();
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
    unawaited(_remoteSub?.cancel());
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
