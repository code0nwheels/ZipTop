import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/api/api_config.dart';
import '../core/api/streams_api.dart';
import '../core/session/playback_session.dart';
import '../player/mpv_player.dart' show isDashUrl;
import 'capture/hls_capture.dart';
import 'disk_space.dart';
import 'dvr_store.dart';
import 'models.dart';

/// One recording, start to finish: open the file, take a server session,
/// capture until the planned stop, then label the result and release the
/// slot. Ported from the Android app's `RecordingSession`.
class RecordingRunner {
  RecordingRunner({
    required this.store,
    required this.recordingId,
    required this.api,
    required this.config,
    required this.directory,
    this.slots,
    HttpClient? client,
    this.clock = DateTime.now,
  }) : _client = client ?? HlsCapture.newClient();

  final DvrStore store;
  final String recordingId;
  final StreamsApi api;
  final ApiConfig config;

  /// Where the file goes.
  final Directory directory;
  final StreamSlots? slots;
  final DateTime Function() clock;
  final HttpClient _client;

  final _token = CaptureToken();
  bool _stoppedByUser = false;
  bool _finished = false;
  RecordingFailure? _kickFailure;
  String? _kickMessage;
  PlaybackSession? _session;
  FileCaptureSink? _sink;

  /// Ends the recording early, keeping what has been captured.
  void stop({bool byUser = true}) {
    if (byUser) _stoppedByUser = true;
    _token.cancel();
  }

  Future<void> run() async {
    final settings = store.settings;
    final now = clock();
    final row = store.update(
      recordingId,
      (r) => r.copyWith(
        state: RecordingState.recording,
        actualStart: r.actualStart ?? now,
        failure: RecordingFailure.none,
        errorMessage: null,
      ),
    );
    if (row == null) return;

    try {
      // ---- storage ----
      final FileCaptureSink sink;
      try {
        await directory.create(recursive: true);
        final free = freeDiskBytes(directory.path);
        if (free != null && free < settings.minFreeBytes) {
          await _finish(RecordingFailure.diskFull, 'Not enough free space to record');
          return;
        }
        sink = await FileCaptureSink.open(File(p.join(directory.path, '${fileStem(row)}.part')));
      } catch (e) {
        await _finish(RecordingFailure.storageGone, 'Recording folder unavailable: $e');
        return;
      }
      _sink = sink;
      store.update(recordingId, (r) => r.copyWith(filePath: sink.file.path));

      // ---- server session ----
      final session = PlaybackSession(
        api,
        slots: slots,
        autoExtendWatch: settings.autoExtendWatch,
      );
      _session = session;
      await session.open(row.streamId, iptv: row.streamType == 'iptv');

      final limit = api.lastStreamLimit;
      if (limit != null && limit != store.settings.cachedStreamLimit) {
        store.saveSettings(store.settings.copyWith(cachedStreamLimit: limit));
      }

      final url = session.url;
      switch (session.phase) {
        case SessionPhase.playing when url != null:
          break;
        case SessionPhase.streamLimit:
          await _finish(RecordingFailure.streamLimit, session.message ?? 'Stream limit reached');
          return;
        case SessionPhase.watchTimeUp:
          await _finish(
            RecordingFailure.watchKicked,
            session.message ?? 'Watch time limit reached',
          );
          return;
        default:
          await _finish(
            RecordingFailure.noUrl,
            session.message ?? 'The stream URL was unavailable',
          );
          return;
      }
      if (isDashUrl(url)) {
        await _finish(
          RecordingFailure.unsupportedDash,
          'This channel streams in DASH, which cannot be recorded',
        );
        return;
      }

      // If the server ends our session, stop fetching straight away.
      session.addListener(_onSession);

      // ---- capture ----
      final outcome = await HlsCapture.run(
        initialUrl: url,
        client: _client,
        sink: sink,
        config: CaptureConfig(
          userAgent: ApiConfig.mediaUserAgent,
          referer: config.referer,
          variantPreference: settings.variantPreference,
          minFreeBytes: settings.minFreeBytes,
        ),
        deadline: row.plannedStop,
        hardCap: (row.actualStart ?? now).add(settings.maxDuration),
        resolveUrl: () async {
          try {
            return await api.streamUrl(row.streamId);
          } catch (_) {
            return null;
          }
        },
        onProgress: (bytes, gaps) => store.update(
          recordingId,
          (r) => r.copyWith(bytesWritten: bytes, gapCount: gaps),
        ),
        token: _token,
        clock: clock,
      );

      switch (outcome) {
        case CaptureFinished():
          await _finish(RecordingFailure.none, null, outcome);
        case CaptureFailed(:final failure, :final message):
          await _finish(failure, message, outcome);
      }
    } on CaptureCancelled {
      final kick = _kickFailure;
      if (kick != null) {
        await _finish(kick, _kickMessage);
      } else if (_stoppedByUser) {
        await _finish(RecordingFailure.cancelledByUser, 'Stopped');
      } else {
        await _finish(RecordingFailure.network, 'Recording was interrupted');
      }
    } catch (e) {
      await _finish(RecordingFailure.network, 'Recording failed: $e');
    }
  }

  void _onSession() {
    final session = _session;
    if (session == null || _finished) return;
    if (session.phase == SessionPhase.streamLimit) {
      _kickFailure = RecordingFailure.streamLimit;
      _kickMessage = session.message ?? 'Another device took the stream slot';
      _token.cancel();
    } else if (session.phase == SessionPhase.watchTimeUp) {
      _kickFailure = RecordingFailure.watchKicked;
      _kickMessage = session.message ?? 'Watch time limit reached';
      _token.cancel();
    }
  }

  /// Closes the file, decides the final state and releases the server slot.
  /// Every exit path comes through here, once.
  Future<void> _finish(
    RecordingFailure failure,
    String? message, [
    CaptureOutcome? outcome,
  ]) async {
    if (_finished) return;
    _finished = true;

    final session = _session;
    session?.removeListener(_onSession);

    final sink = _sink;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }

    final stop = clock();
    final bytes = outcome?.bytesWritten ?? sink?.bytesWritten ?? 0;
    final gaps = outcome?.gapCount ?? store.byId(recordingId)?.gapCount ?? 0;
    final container = outcome?.container ?? 'ts';

    // Give the file its real name now the container is known; an empty one
    // leaves no rubbish behind.
    String? finalPath;
    if (sink != null) {
      try {
        if (bytes > 0) {
          final target = p.setExtension(sink.file.path, '.$container');
          finalPath = (await sink.file.rename(await _unusedPath(target))).path;
        } else {
          await sink.file.delete();
        }
      } catch (_) {
        finalPath = bytes > 0 ? sink.file.path : null;
      }
    }

    final updated = store.update(recordingId, (row) {
      final reachedEnd = !stop.isBefore(row.plannedStop.subtract(const Duration(minutes: 1)));
      final clean = failure == RecordingFailure.none && reachedEnd && gaps == 0;
      final state = bytes <= 0
          ? RecordingState.failed
          : clean
              ? RecordingState.completed
              // Bytes with a shortfall, a gap or a stop reason: still worth
              // keeping and playing.
              : RecordingState.partial;
      return row.copyWith(
        state: state,
        failure: failure,
        errorMessage: message,
        bytesWritten: bytes,
        gapCount: gaps,
        container: bytes > 0 ? container : null,
        filePath: finalPath,
        actualStop: stop,
      );
    });

    // Leaves the stream unless the viewer is still watching it.
    if (session != null) {
      try {
        await session.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
      session.dispose();
    }
    _client.close(force: true);

    if (updated != null) await _pruneSeries(updated);
  }

  /// Enforces a series rule's keep limit, oldest first. Only finished
  /// recordings are candidates.
  Future<void> _pruneSeries(Recording justFinished) async {
    final ruleId = justFinished.seriesRuleId;
    if (ruleId == null) return;
    SeriesRule? rule;
    for (final r in store.rules) {
      if (r.id == ruleId) rule = r;
    }
    if (rule == null || rule.keepMax <= 0) return;
    final kept = [
      for (final r in store.recordings)
        if (r.seriesRuleId == ruleId && r.hasPlayableFile && r.isTerminal) r,
    ]..sort((a, b) => (b.actualStart ?? b.plannedStart).compareTo(a.actualStart ?? a.plannedStart));
    for (final old in kept.skip(rule.keepMax)) {
      if (old.id == justFinished.id) continue;
      try {
        await File(old.filePath!).delete();
      } catch (_) {}
      store.remove(old.id);
    }
  }

  static Future<String> _unusedPath(String path) async {
    if (!await File(path).exists()) return path;
    final base = p.withoutExtension(path);
    final ext = p.extension(path);
    for (var i = 2;; i++) {
      final candidate = '$base ($i)$ext';
      if (!await File(candidate).exists()) return candidate;
    }
  }

  /// `Title - Channel - 2026-01-31 20-00`, safe for a Windows file name.
  static String fileStem(Recording row) {
    final t = row.plannedStart;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}-${two(t.minute)}';
    final title = _safe(row.title.isEmpty ? row.streamName : row.title);
    final channel = _safe(row.streamName);
    final name = title == channel || channel.isEmpty ? title : '$title - $channel';
    final stem = '$name - $stamp';
    return stem.length > 150 ? '${name.substring(0, 150 - stamp.length - 3).trim()} - $stamp' : stem;
  }

  static String _safe(String text) => text
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
}
