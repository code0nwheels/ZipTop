import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/api/api_config.dart';
import '../core/api/streams_api.dart';
import '../core/models/guide.dart';
import '../core/session/playback_session.dart';
import '../core/stores/guide_repository.dart';
import 'dvr_store.dart';
import 'models.dart';
import 'recording_runner.dart';
import 'series_matcher.dart';

/// The channel a recording is made from.
typedef RecordTarget = ({String id, String name, String type});

/// Runs the DVR: starts recordings when they are due, stops them on request,
/// and keeps series rules scheduled. It only works while ZipTop is running.
class DvrService extends ChangeNotifier {
  DvrService({
    required this.store,
    required this.api,
    required this.config,
    required this.guide,
    this.slots,
    this.clock = DateTime.now,
  });

  static const tickInterval = Duration(seconds: 15);
  static const seriesRescanInterval = Duration(minutes: 30);

  final DvrStore store;
  final StreamsApi api;
  final ApiConfig config;
  final GuideRepository guide;
  final StreamSlots? slots;
  final DateTime Function() clock;

  final _runners = <String, RecordingRunner>{};
  Timer? _tickTimer;
  Timer? _dueTimer;
  DateTime? _lastSeriesRescan;
  int _idCounter = 0;
  bool _started = false;
  bool _disposed = false;

  /// Recordings still to come or under way. While this is true the app
  /// should keep running when its window is closed.
  bool get hasPendingWork =>
      _runners.isNotEmpty || store.recordings.any((r) => r.state == RecordingState.scheduled);

  bool isRunning(String recordingId) => _runners.containsKey(recordingId);

  Directory get directory => Directory(store.settings.storageDir ?? defaultDirectory());

  static String defaultDirectory() {
    if (Platform.isLinux) {
      final env = Platform.environment;
      final home = env['HOME'] ?? '.';
      final configHome = env['XDG_CONFIG_HOME'];
      final configDir =
          configHome != null && configHome.isNotEmpty ? configHome : p.join(home, '.config');
      String? userDirs;
      try {
        userDirs = File(p.join(configDir, 'user-dirs.dirs')).readAsStringSync();
      } catch (_) {}
      final videos = (userDirs == null ? null : xdgVideosDir(userDirs, home: home)) ??
          p.join(home, 'Videos');
      return p.join(videos, 'ZipTop');
    }
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    return p.join(home, 'Videos', 'ZipTop');
  }

  /// Begins watching the clock. Call once the viewer is signed in.
  void start() {
    if (_started) return;
    _started = true;
    _recoverInterrupted();
    store.addListener(_onStore);
    guide.addListener(_onGuide);
    _tickTimer = Timer.periodic(tickInterval, (_) => tick());
    tick();
  }

  /// A recording still marked as running when the app starts was cut off by
  /// the app closing or crashing.
  void _recoverInterrupted() {
    for (final row in store.active) {
      if (_runners.containsKey(row.id)) continue;
      var bytes = row.bytesWritten;
      final path = row.filePath;
      if (path != null) {
        try {
          bytes = File(path).lengthSync();
        } catch (_) {
          bytes = 0;
        }
      }
      store.update(
        row.id,
        (r) => r.copyWith(
          state: bytes > 0 ? RecordingState.partial : RecordingState.failed,
          failure: RecordingFailure.network,
          errorMessage: 'ZipTop closed during the recording',
          bytesWritten: bytes,
          container: bytes > 0 ? (r.container ?? 'ts') : null,
          filePath: bytes > 0 ? path : null,
          actualStop: clock(),
        ),
      );
    }
  }

  /// Starts whatever is due and writes off whatever was missed.
  void tick() {
    if (_disposed || !_started) return;
    final now = clock();
    for (final row in store.scheduled) {
      if (!now.isBefore(row.plannedStop)) {
        store.update(
          row.id,
          (r) => r.copyWith(
            state: RecordingState.failed,
            failure: RecordingFailure.missed,
            errorMessage: "ZipTop wasn't running at the time",
          ),
        );
      } else if (!now.isBefore(row.plannedStart)) {
        _startRunner(row);
      }
    }
    _armDueTimer();
    if (store.rules.any((r) => r.enabled)) {
      final last = _lastSeriesRescan;
      if (last == null || now.difference(last) >= seriesRescanInterval) {
        _lastSeriesRescan = now;
        // The guide listener does the planning once this arrives.
        unawaited(guide.load().then(rescanSeries).catchError((Object _) => 0));
      }
    }
  }

  /// Wakes exactly when the next recording is due, rather than up to a tick late.
  void _armDueTimer() {
    _dueTimer?.cancel();
    final upcoming = store.scheduled;
    if (upcoming.isEmpty) return;
    final wait = upcoming.first.plannedStart.difference(clock());
    if (wait > Duration.zero && wait < tickInterval) _dueTimer = Timer(wait, tick);
  }

  void _startRunner(Recording row) {
    if (_runners.containsKey(row.id)) return;
    final runner = RecordingRunner(
      store: store,
      recordingId: row.id,
      api: api,
      config: config,
      directory: directory,
      slots: slots,
      clock: clock,
    );
    _runners[row.id] = runner;
    _notify();
    unawaited(
      runner.run().whenComplete(() {
        _runners.remove(row.id);
        _notify();
      }),
    );
  }

  void _onStore() {
    _armDueTimer();
    _notify();
  }

  void _onGuide() {
    final current = guide.guide;
    if (current != null) rescanSeries(current);
  }

  String _newId() => '${clock().microsecondsSinceEpoch}-${_idCounter++}';

  /// The recording under way on [streamId], if any.
  Recording? activeOn(String streamId) {
    for (final r in store.active) {
      if (r.streamId == streamId) return r;
    }
    return null;
  }

  /// The stored recording for this programme on this channel, if it is
  /// scheduled or running.
  Recording? pendingFor(String streamId, Programme programme) {
    final found = store.findSameAiring(
      streamId,
      normalizeTitle(programme.title),
      programme.start.subtract(store.settings.padStart),
    );
    return found == null || found.isTerminal ? null : found;
  }

  /// Records [programme]. One already on air is recorded from now.
  Recording scheduleProgramme(RecordTarget channel, Programme programme) {
    final now = clock();
    final settings = store.settings;
    final existing = pendingFor(channel.id, programme);
    if (existing != null) return existing;

    final onAir = !programme.start.isAfter(now);
    final recording = Recording(
      id: _newId(),
      streamId: channel.id,
      streamName: channel.name,
      streamType: channel.type,
      title: programme.title.isEmpty ? channel.name : programme.title,
      titleNorm: normalizeTitle(programme.title),
      description: programme.description,
      epgStart: programme.start,
      epgStop: programme.stop,
      plannedStart: onAir ? now : programme.start.subtract(settings.padStart),
      plannedStop: programme.stop.add(settings.padStop),
      createdAt: now,
    );
    store.add(recording);
    tick();
    return store.byId(recording.id) ?? recording;
  }

  /// Records [channel] from now for [length], for when there is no guide data.
  Recording scheduleFromNow(RecordTarget channel, {Duration length = const Duration(hours: 1)}) {
    final now = clock();
    final recording = Recording(
      id: _newId(),
      streamId: channel.id,
      streamName: channel.name,
      streamType: channel.type,
      title: channel.name,
      titleNorm: normalizeTitle(channel.name),
      plannedStart: now,
      plannedStop: now.add(length),
      createdAt: now,
    );
    store.add(recording);
    tick();
    return store.byId(recording.id) ?? recording;
  }

  /// Records every future airing of [title] on [channel]. Returns how many
  /// airings the current guide let it schedule straight away.
  int addSeriesRule(RecordTarget channel, String title) {
    final now = clock();
    final titleNorm = normalizeTitle(title);
    final already = store.rules.any((r) => r.titleNorm == titleNorm && r.streamId == channel.id);
    if (!already) {
      store.addRule(
        SeriesRule(
          id: _newId(),
          displayTitle: title,
          titleNorm: titleNorm,
          streamId: channel.id,
          streamName: channel.name,
          padStart: store.settings.padStart,
          padStop: store.settings.padStop,
          createdAt: now,
        ),
      );
    }
    final current = guide.guide;
    return current == null ? 0 : rescanSeries(current);
  }

  /// Schedules what the series rules match in [guide]. Returns how many
  /// recordings were added.
  int rescanSeries(Guide guide) {
    final additions = SeriesMatcher.plan(
      rules: store.rules,
      guide: guide,
      existing: store.recordings,
      dismissedAiringKeys: store.dismissedAiringKeys,
      now: clock(),
      newId: _newId,
    );
    store.addAll(additions);
    return additions.length;
  }

  /// Cancels a scheduled recording, or stops a running one (keeping the file).
  void cancel(String recordingId) {
    final runner = _runners[recordingId];
    if (runner != null) {
      runner.stop();
      return;
    }
    final row = store.byId(recordingId);
    if (row == null || row.state != RecordingState.scheduled) return;
    if (row.seriesRuleId != null) {
      // Keep a tombstone so the series rule does not put it straight back.
      store.dismissAiring(row.airingKey);
      store.update(
        recordingId,
        (r) => r.copyWith(
          state: RecordingState.cancelled,
          failure: RecordingFailure.cancelledByUser,
        ),
      );
    } else {
      store.remove(recordingId);
    }
  }

  /// Removes a finished recording from the list and deletes its file.
  Future<void> delete(String recordingId) async {
    final row = store.byId(recordingId);
    if (row == null || _runners.containsKey(recordingId)) return;
    final path = row.filePath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        // Already gone, or in use; the entry goes either way.
      }
    }
    store.remove(recordingId);
  }

  /// Schedules a failed or missed recording again, if its window is still open.
  bool retry(String recordingId) {
    final row = store.byId(recordingId);
    if (row == null || !row.isTerminal || !clock().isBefore(row.plannedStop)) return false;
    store.update(
      recordingId,
      (r) => r.copyWith(
        state: RecordingState.scheduled,
        failure: RecordingFailure.none,
        errorMessage: null,
      ),
    );
    tick();
    return true;
  }

  void removeRule(String ruleId) {
    // Its not-yet-started recordings go with it.
    for (final row in store.scheduled) {
      if (row.seriesRuleId == ruleId) store.remove(row.id);
    }
    store.removeRule(ruleId);
  }

  void saveResumePosition(String recordingId, Duration position) {
    store.update(recordingId, (r) => r.copyWith(resumePositionMs: position.inMilliseconds));
  }

  /// A warning when recording this window would need more streams than the
  /// account allows, or null.
  String? conflictWarning(DateTime start, DateTime stop, {String? streamId}) {
    final overlapping = store.conflictsAt(start, stop, excludeStreamId: streamId);
    if (overlapping.isEmpty) return null;
    final limit = store.settings.cachedStreamLimit;
    final n = overlapping.length;
    if (limit > 0 && n + 1 > limit) {
      return 'You have $n other recording${n == 1 ? '' : 's'} at this time and your plan '
          'allows $limit stream${limit == 1 ? '' : 's'} at once. One of them may fail.';
    }
    return 'Overlaps $n other recording${n == 1 ? '' : 's'}.';
  }

  /// Stops every running recording and waits for the files to be closed.
  Future<void> stopAll() async {
    final running = _runners.values.toList();
    for (final runner in running) {
      runner.stop(byUser: false);
    }
    final deadline = clock().add(const Duration(seconds: 8));
    while (_runners.isNotEmpty && clock().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await store.saved;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tickTimer?.cancel();
    _dueTimer?.cancel();
    if (_started) {
      store.removeListener(_onStore);
      guide.removeListener(_onGuide);
    }
    super.dispose();
  }
}

/// The `XDG_VIDEOS_DIR` entry of a `user-dirs.dirs` file, with `$HOME`
/// expanded, or null when it is missing or points at the home folder itself
/// (which is how xdg-user-dirs marks a disabled folder).
String? xdgVideosDir(String userDirs, {required String home}) {
  for (final raw in userDirs.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('XDG_VIDEOS_DIR=')) continue;
    var value = line.substring('XDG_VIDEOS_DIR='.length).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.startsWith(r'$HOME')) {
      value = home + value.substring(r'$HOME'.length);
    } else if (value.startsWith(r'${HOME}')) {
      value = home + value.substring(r'${HOME}'.length);
    }
    if (value.isEmpty || !value.startsWith('/')) return null;
    final normalized = value.replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty || normalized == home.replaceAll(RegExp(r'/+$'), '')) return null;
    return normalized;
  }
  return null;
}
