import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/streams_api.dart';
import '../models/playback.dart';

enum SessionPhase {
  /// Nothing open.
  idle,

  /// Running the limit / ready / start / url / first-heartbeat pipeline.
  preparing,

  /// [PlaybackSession.url] is valid and heartbeats are running.
  playing,

  /// Could not get a stream. [PlaybackSession.message] says why.
  failed,

  /// At the account's stream limit, or evicted by another device.
  streamLimit,

  /// The account-wide watch window closed without being extended.
  watchTimeUp,
}

/// One viewer session on one stream: the server-side protocol that has to run
/// alongside playback, or the server drops the stream.
///
/// Ported from the Android app's `PlayerViewModel`:
/// `check-limit` → (IPTV only: `ready`, else `start` and wait 2 s) → `url` →
/// one heartbeat before playback → a heartbeat every 20 s → on switch or exit,
/// `leave` then `DELETE heartbeat`.
///
/// Used by the main player, each multiview tile and each recording.
class PlaybackSession extends ChangeNotifier {
  PlaybackSession(this._api);

  static const heartbeatInterval = Duration(seconds: 20);
  static const startWait = Duration(seconds: 2);
  static const leaveTimeout = Duration(seconds: 2);
  static const evictedMessage =
      'This session was ended because you opened a stream on another device';

  final StreamsApi _api;

  SessionPhase _phase = SessionPhase.idle;
  String? _streamId;
  bool _iptv = false;
  String? _url;
  String? _message;
  int? _warningSeconds;

  // Bumped whenever the current pipeline or heartbeat loop must stop.
  int _generation = 0;
  Timer? _beatTimer;
  Timer? _deadlineTimer;
  Timer? _countdownTimer;
  bool _disposed = false;

  SessionPhase get phase => _phase;
  String? get streamId => _streamId;

  /// The signed playback URL while [phase] is [SessionPhase.playing].
  String? get url => _url;
  String? get message => _message;

  /// Seconds left to answer "are you still watching?", or null when not asked.
  int? get warningSeconds => _warningSeconds;

  /// Opens [streamId], releasing the previous stream first so an account with
  /// a limit of one does not evict its own new session.
  Future<void> open(String streamId, {required bool iptv}) async {
    final generation = _begin();
    final previous = _streamId;
    _streamId = streamId;
    _iptv = iptv;
    _set(SessionPhase.preparing);

    if (previous != null && previous != streamId) {
      try {
        await _api.leave(previous).timeout(leaveTimeout);
      } catch (_) {
        // Best effort; the server times the old session out anyway.
      }
      _quietly(_api.endSession(previous));
    }
    if (generation != _generation) return;
    await _prepare(generation, streamId, iptv);
  }

  /// Runs the pipeline again for the current stream. Playback URLs are
  /// short-lived, so every player retry goes through here for a new one.
  Future<void> reopen() async {
    final streamId = _streamId;
    if (streamId == null) return;
    final generation = _begin();
    _set(SessionPhase.preparing);
    await _prepare(generation, streamId, _iptv);
  }

  /// Acknowledges the account-wide watch window.
  void extendWatch() {
    _deadlineTimer?.cancel();
    _countdownTimer?.cancel();
    _warningSeconds = null;
    _notify();
    _quietly(_api.extendWatch());
  }

  /// Ends the session and releases the server slot.
  Future<void> close() async {
    _begin();
    final streamId = _streamId;
    _streamId = null;
    _set(SessionPhase.idle);
    if (streamId == null) return;
    try {
      await _api.leave(streamId);
      await _api.endSession(streamId);
    } catch (_) {
      // Best effort.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _generation++;
    super.dispose();
  }

  Future<void> _prepare(int generation, String streamId, bool iptv) async {
    bool stale() => generation != _generation;
    try {
      try {
        await _api.checkLimit(streamId);
      } on StreamLimitException {
        rethrow;
      } catch (_) {
        // Only a refusal stops us; the URL call is the real gate.
      }
      if (stale()) return;

      if (iptv) {
        var ready = true;
        try {
          ready = await _api.isReady(streamId);
        } catch (_) {
          // If the ready check fails, try for the URL anyway.
        }
        if (stale()) return;
        if (!ready) {
          try {
            await _api.start(streamId);
          } catch (e) {
            throw ApiException('Failed to start stream: $e');
          }
          if (stale()) return;
          await Future<void>.delayed(startWait);
          if (stale()) return;
        }
      }

      final url = await _api.streamUrl(streamId);
      if (stale()) return;

      // Register the session before playback starts. A stream-limit refusal
      // here means another device took the slot first.
      HeartbeatOutcome? outcome;
      try {
        outcome = await _api.heartbeat(streamId);
      } on StreamLimitException {
        rethrow;
      } catch (_) {
        outcome = null;
      }
      if (stale()) return;
      if (outcome is HeartbeatKicked && outcome.reason == KickReason.watchTimeExceeded) {
        _watchTimeUp(outcome.message);
        return;
      }

      _url = url;
      _set(SessionPhase.playing);
      if (outcome is HeartbeatWarn) {
        final seconds = outcome.secondsRemaining ?? 0;
        _startCountdown(seconds);
        _scheduleDeadline(seconds);
        if (stale()) return;
      }
      _scheduleBeat(generation, streamId, heartbeatInterval);
    } on StreamLimitException catch (e) {
      if (stale()) return;
      _set(SessionPhase.streamLimit, message: e.message);
    } catch (e) {
      if (stale()) return;
      _set(SessionPhase.failed, message: e.toString());
    }
  }

  void _scheduleBeat(int generation, String streamId, Duration delay) {
    _beatTimer?.cancel();
    _beatTimer = Timer(delay, () => _beat(generation, streamId));
  }

  Future<void> _beat(int generation, String streamId) async {
    bool stale() => generation != _generation;
    if (stale()) return;
    var next = heartbeatInterval;
    try {
      final outcome = await _api.heartbeat(streamId);
      if (stale()) return;
      switch (outcome) {
        case HeartbeatOk():
          // The window is account-wide, so Ok can also mean the viewer
          // answered the prompt on another device.
          _deadlineTimer?.cancel();
          _countdownTimer?.cancel();
          if (_warningSeconds != null) {
            _warningSeconds = null;
            _notify();
          }
        case HeartbeatWarn(:final secondsRemaining):
          final seconds = secondsRemaining ?? 20;
          _startCountdown(seconds);
          // Poll close to the deadline so the kick lands promptly.
          next = Duration(milliseconds: (seconds * 1000 + 1000).clamp(2000, 20000));
          _scheduleDeadline(seconds);
          if (stale()) return;
        case HeartbeatKicked(:final reason, :final message):
          if (reason == KickReason.watchTimeExceeded) {
            _watchTimeUp(message);
          } else {
            _begin();
            _set(SessionPhase.streamLimit, message: message);
          }
          return;
      }
    } on StreamLimitException {
      if (stale()) return;
      // Evicted: a newer session, e.g. another device, took the slot.
      _begin();
      _set(SessionPhase.streamLimit, message: evictedMessage);
      return;
    } catch (_) {
      // A missed beat is not fatal; try again on the next tick.
    }
    if (!stale()) _scheduleBeat(generation, streamId, next);
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _warningSeconds = seconds;
    _notify();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_warningSeconds ?? 0) - 1;
      if (left <= 0) {
        timer.cancel();
        _warningSeconds = 0;
      } else {
        _warningSeconds = left;
      }
      _notify();
    });
  }

  /// Enforces the deadline locally so playback stops on time even if the next
  /// heartbeat has not fired yet.
  void _scheduleDeadline(int secondsRemaining) {
    _deadlineTimer?.cancel();
    if (secondsRemaining <= 0) {
      _watchTimeUp('Watch time limit reached.');
      return;
    }
    _deadlineTimer = Timer(
      Duration(seconds: secondsRemaining + 2),
      () => _watchTimeUp('Watch time limit reached.'),
    );
  }

  void _watchTimeUp(String message) {
    _begin();
    final streamId = _streamId;
    _streamId = null;
    if (streamId != null) _quietly(_api.leave(streamId));
    _set(SessionPhase.watchTimeUp, message: message);
  }

  /// Stops whatever is running and returns the new generation.
  int _begin() {
    _cancelTimers();
    _url = null;
    _warningSeconds = null;
    return ++_generation;
  }

  void _cancelTimers() {
    _beatTimer?.cancel();
    _deadlineTimer?.cancel();
    _countdownTimer?.cancel();
  }

  void _set(SessionPhase phase, {String? message}) {
    _phase = phase;
    _message = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _quietly(Future<void> future) {
    unawaited(future.catchError((Object _) {}));
  }
}
