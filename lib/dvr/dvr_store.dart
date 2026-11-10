import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models/json.dart';
import 'models.dart';

/// Everything the DVR remembers: recordings, series rules and its settings.
/// Kept in one JSON file and rewritten whole on every change.
class DvrStore extends ChangeNotifier {
  DvrStore._(this._file);

  /// Two airings of one title on one channel this close together are the
  /// same airing (the guide shifted, or it was scheduled twice).
  static const airingMatchWindow = Duration(minutes: 45);
  static const maxDismissed = 500;

  /// Opens the store at [file], or an in-memory one when [file] is null.
  static Future<DvrStore> open(File? file) async {
    final store = DvrStore._(file);
    if (file != null && await file.exists()) {
      try {
        final json = asJson(jsonDecode(await file.readAsString()));
        if (json != null) store._load(json);
      } catch (_) {
        // A corrupt file must not stop the app; keep it aside and start clean.
        try {
          await file.rename('${file.path}.corrupt');
        } catch (_) {}
      }
    }
    return store;
  }

  final File? _file;
  var _recordings = <Recording>[];
  var _rules = <SeriesRule>[];
  var _settings = const DvrSettings();
  var _dismissed = <String>[];
  Future<void> _saving = Future.value();

  List<Recording> get recordings => List.unmodifiable(_recordings);
  List<SeriesRule> get rules => List.unmodifiable(_rules);
  DvrSettings get settings => _settings;
  Set<String> get dismissedAiringKeys => _dismissed.toSet();

  /// Completes when every change so far is on disk.
  Future<void> get saved => _saving;

  void _load(Json json) {
    _recordings = asList(json['recordings'], (j) {
      final r = Recording.fromJson(j);
      return r.id.isEmpty ? null : r;
    });
    _rules = asList(json['seriesRules'], (j) {
      final r = SeriesRule.fromJson(j);
      return r.id.isEmpty ? null : r;
    });
    final settings = asJson(json['settings']);
    if (settings != null) _settings = DvrSettings.fromJson(settings);
    _dismissed = asStringList(json['dismissedAiringKeys']);
  }

  Recording? byId(String id) {
    for (final r in _recordings) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<Recording> get scheduled => _sorted(
        _recordings.where((r) => r.state == RecordingState.scheduled),
        (a, b) => a.plannedStart.compareTo(b.plannedStart),
      );

  List<Recording> get active =>
      [for (final r in _recordings) if (r.state == RecordingState.recording) r];

  /// Finished recordings, newest first. Cancelled rows are tombstones and
  /// are not shown.
  List<Recording> get finished => _sorted(
        _recordings.where((r) => r.isTerminal && r.state != RecordingState.cancelled),
        (a, b) => (b.actualStart ?? b.plannedStart).compareTo(a.actualStart ?? a.plannedStart),
      );

  static List<Recording> _sorted(
    Iterable<Recording> rows,
    int Function(Recording a, Recording b) compare,
  ) =>
      rows.toList()..sort(compare);

  /// The stored recording for this airing, whatever its state.
  Recording? findSameAiring(String streamId, String titleNorm, DateTime start) {
    for (final r in _recordings) {
      if (r.streamId == streamId &&
          r.titleNorm == titleNorm &&
          r.plannedStart.difference(start).abs() < airingMatchWindow) {
        return r;
      }
    }
    return null;
  }

  /// Recordings, scheduled or running, that overlap a window on other
  /// channels. Each needs its own stream slot.
  List<Recording> conflictsAt(DateTime start, DateTime stop, {String? excludeStreamId}) => [
        for (final r in _recordings)
          if (!r.isTerminal && r.streamId != excludeStreamId && r.overlaps(start, stop)) r,
      ];

  void add(Recording recording) => addAll([recording]);

  void addAll(List<Recording> additions) {
    if (additions.isEmpty) return;
    _recordings = [..._recordings, ...additions];
    _changed();
  }

  /// Replaces one recording with [transform] of itself. Returns the new row.
  Recording? update(String id, Recording Function(Recording row) transform) {
    final index = _recordings.indexWhere((r) => r.id == id);
    if (index < 0) return null;
    final next = transform(_recordings[index]);
    _recordings = [..._recordings]..[index] = next;
    _changed();
    return next;
  }

  void remove(String id) {
    final before = _recordings.length;
    _recordings = [for (final r in _recordings) if (r.id != id) r];
    if (_recordings.length != before) _changed();
  }

  /// Remembers that the viewer declined this airing, so a series rule does
  /// not schedule it again.
  void dismissAiring(String airingKey) {
    if (_dismissed.contains(airingKey)) return;
    _dismissed = [..._dismissed, airingKey];
    if (_dismissed.length > maxDismissed) {
      _dismissed = _dismissed.sublist(_dismissed.length - maxDismissed);
    }
    _changed();
  }

  void addRule(SeriesRule rule) {
    _rules = [..._rules, rule];
    _changed();
  }

  void updateRule(String id, SeriesRule Function(SeriesRule rule) transform) {
    _rules = [for (final r in _rules) r.id == id ? transform(r) : r];
    _changed();
  }

  void removeRule(String id) {
    _rules = [for (final r in _rules) if (r.id != id) r];
    _changed();
  }

  void saveSettings(DvrSettings settings) {
    _settings = settings;
    _changed();
  }

  void _changed() {
    notifyListeners();
    final file = _file;
    if (file == null) return;
    final text = jsonEncode({
      'recordings': [for (final r in _recordings) r.toJson()],
      'seriesRules': [for (final r in _rules) r.toJson()],
      'settings': _settings.toJson(),
      'dismissedAiringKeys': _dismissed,
    });
    // One write at a time, in order, each replacing the file in one step.
    _saving = _saving.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(text, flush: true);
        await temp.rename(file.path);
      } catch (_) {
        // Still held in memory; the next change tries again.
      }
    });
  }
}
