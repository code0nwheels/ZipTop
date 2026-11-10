import '../core/models/json.dart';

enum RecordingState { scheduled, recording, completed, partial, failed, cancelled }

enum RecordingFailure {
  none,
  streamLimit,
  watchKicked,
  noUrl,
  unsupportedDash,
  unsupportedCrypto,
  diskFull,
  storageGone,
  network,
  timedOut,
  cancelledByUser,

  /// ZipTop was not running when the recording should have started.
  missed,
}

enum VariantPreference {
  highest('Best available'),
  atMost720p('Up to 720p'),
  lowest('Lowest');

  const VariantPreference(this.label);
  final String label;
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

/// One scheduled or finished recording.
///
/// [plannedStart] and [plannedStop] already include padding and are the only
/// thing the recorder obeys. The guide's own times are kept for display, but
/// never re-read to drive timing: some feeds carry broken offsets, so the
/// conversion happens once, in front of the viewer, when it is scheduled.
class Recording {
  const Recording({
    required this.id,
    required this.streamId,
    required this.streamName,
    required this.streamType,
    required this.title,
    required this.titleNorm,
    this.description,
    this.epgStart,
    this.epgStop,
    required this.plannedStart,
    required this.plannedStop,
    this.state = RecordingState.scheduled,
    this.failure = RecordingFailure.none,
    this.errorMessage,
    this.seriesRuleId,
    this.filePath,
    this.container,
    this.bytesWritten = 0,
    this.actualStart,
    this.actualStop,
    this.gapCount = 0,
    this.resumePositionMs = 0,
    required this.createdAt,
  });

  factory Recording.fromJson(Json json) => Recording(
        id: asString(json['id']) ?? '',
        streamId: asString(json['streamId']) ?? '',
        streamName: asString(json['streamName']) ?? '',
        streamType: asString(json['streamType']) ?? '',
        title: asString(json['title']) ?? '',
        titleNorm: asString(json['titleNorm']) ?? '',
        description: asString(json['description']),
        epgStart: _time(json['epgStartMs']),
        epgStop: _time(json['epgStopMs']),
        plannedStart: _time(json['plannedStartMs']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        plannedStop: _time(json['plannedStopMs']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        state: _enumByName(RecordingState.values, json['state'], RecordingState.failed),
        failure: _enumByName(RecordingFailure.values, json['failure'], RecordingFailure.none),
        errorMessage: asString(json['errorMessage']),
        seriesRuleId: asString(json['seriesRuleId']),
        filePath: asString(json['filePath']),
        container: asString(json['container']),
        bytesWritten: asInt(json['bytesWritten']) ?? 0,
        actualStart: _time(json['actualStartMs']),
        actualStop: _time(json['actualStopMs']),
        gapCount: asInt(json['gapCount']) ?? 0,
        resumePositionMs: asInt(json['resumePositionMs']) ?? 0,
        createdAt: _time(json['createdAtMs']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  static DateTime? _time(Object? ms) {
    final value = asInt(ms);
    return value == null || value <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  final String id;
  final String streamId;
  final String streamName;
  final String streamType;
  final String title;
  final String titleNorm;
  final String? description;
  final DateTime? epgStart;
  final DateTime? epgStop;
  final DateTime plannedStart;
  final DateTime plannedStop;
  final RecordingState state;
  final RecordingFailure failure;
  final String? errorMessage;
  final String? seriesRuleId;
  final String? filePath;

  /// `ts` or `mp4`, known once capture has seen the stream.
  final String? container;
  final int bytesWritten;
  final DateTime? actualStart;
  final DateTime? actualStop;
  final int gapCount;
  final int resumePositionMs;
  final DateTime createdAt;

  /// Stable-enough identity for de-duplication across guide refreshes.
  String get airingKey => '$streamId|$titleNorm|${plannedStart.millisecondsSinceEpoch}';

  bool get isTerminal =>
      state == RecordingState.completed ||
      state == RecordingState.partial ||
      state == RecordingState.failed ||
      state == RecordingState.cancelled;

  /// True once there is a file worth offering for playback.
  bool get hasPlayableFile => filePath != null && bytesWritten > 0;

  bool overlaps(DateTime start, DateTime stop) =>
      plannedStart.isBefore(stop) && start.isBefore(plannedStop);

  Recording copyWith({
    DateTime? plannedStart,
    DateTime? plannedStop,
    RecordingState? state,
    RecordingFailure? failure,
    Object? errorMessage = _keep,
    Object? filePath = _keep,
    String? container,
    int? bytesWritten,
    DateTime? actualStart,
    DateTime? actualStop,
    int? gapCount,
    int? resumePositionMs,
  }) =>
      Recording(
        id: id,
        streamId: streamId,
        streamName: streamName,
        streamType: streamType,
        title: title,
        titleNorm: titleNorm,
        description: description,
        epgStart: epgStart,
        epgStop: epgStop,
        plannedStart: plannedStart ?? this.plannedStart,
        plannedStop: plannedStop ?? this.plannedStop,
        state: state ?? this.state,
        failure: failure ?? this.failure,
        errorMessage: identical(errorMessage, _keep) ? this.errorMessage : errorMessage as String?,
        seriesRuleId: seriesRuleId,
        filePath: identical(filePath, _keep) ? this.filePath : filePath as String?,
        container: container ?? this.container,
        bytesWritten: bytesWritten ?? this.bytesWritten,
        actualStart: actualStart ?? this.actualStart,
        actualStop: actualStop ?? this.actualStop,
        gapCount: gapCount ?? this.gapCount,
        resumePositionMs: resumePositionMs ?? this.resumePositionMs,
        createdAt: createdAt,
      );

  Json toJson() => {
        'id': id,
        'streamId': streamId,
        'streamName': streamName,
        'streamType': streamType,
        'title': title,
        'titleNorm': titleNorm,
        'description': description,
        'epgStartMs': epgStart?.millisecondsSinceEpoch,
        'epgStopMs': epgStop?.millisecondsSinceEpoch,
        'plannedStartMs': plannedStart.millisecondsSinceEpoch,
        'plannedStopMs': plannedStop.millisecondsSinceEpoch,
        'state': state.name,
        'failure': failure.name,
        'errorMessage': errorMessage,
        'seriesRuleId': seriesRuleId,
        'filePath': filePath,
        'container': container,
        'bytesWritten': bytesWritten,
        'actualStartMs': actualStart?.millisecondsSinceEpoch,
        'actualStopMs': actualStop?.millisecondsSinceEpoch,
        'gapCount': gapCount,
        'resumePositionMs': resumePositionMs,
        'createdAtMs': createdAt.millisecondsSinceEpoch,
      };
}

const _keep = Object();

/// "Record every episode": every future airing of a title on one channel.
class SeriesRule {
  const SeriesRule({
    required this.id,
    required this.displayTitle,
    required this.titleNorm,
    required this.streamId,
    this.streamName,
    required this.padStart,
    required this.padStop,
    this.keepMax = 5,
    this.enabled = true,
    required this.createdAt,
  });

  factory SeriesRule.fromJson(Json json) => SeriesRule(
        id: asString(json['id']) ?? '',
        displayTitle: asString(json['displayTitle']) ?? '',
        titleNorm: asString(json['titleNorm']) ?? '',
        streamId: asString(json['streamId']),
        streamName: asString(json['streamName']),
        padStart: Duration(milliseconds: asInt(json['padStartMs']) ?? 0),
        padStop: Duration(milliseconds: asInt(json['padStopMs']) ?? 0),
        keepMax: asInt(json['keepMax']) ?? 5,
        enabled: asBool(json['enabled']) ?? true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(asInt(json['createdAtMs']) ?? 0),
      );

  final String id;
  final String displayTitle;
  final String titleNorm;

  /// null means any channel.
  final String? streamId;
  final String? streamName;
  final Duration padStart;
  final Duration padStop;

  /// Finished recordings to keep for this series; 0 means all of them.
  final int keepMax;
  final bool enabled;
  final DateTime createdAt;

  SeriesRule withEnabled(bool value) => SeriesRule(
        id: id,
        displayTitle: displayTitle,
        titleNorm: titleNorm,
        streamId: streamId,
        streamName: streamName,
        padStart: padStart,
        padStop: padStop,
        keepMax: keepMax,
        enabled: value,
        createdAt: createdAt,
      );

  Json toJson() => {
        'id': id,
        'displayTitle': displayTitle,
        'titleNorm': titleNorm,
        'streamId': streamId,
        'streamName': streamName,
        'padStartMs': padStart.inMilliseconds,
        'padStopMs': padStop.inMilliseconds,
        'keepMax': keepMax,
        'enabled': enabled,
        'createdAtMs': createdAt.millisecondsSinceEpoch,
      };
}

class DvrSettings {
  const DvrSettings({
    this.padStart = defaultPadStart,
    this.padStop = defaultPadStop,
    this.maxDuration = const Duration(hours: 6),
    this.minFreeBytes = 500 * 1024 * 1024,
    this.storageDir,
    this.variantPreference = VariantPreference.highest,
    this.autoExtendWatch = true,
    this.cachedStreamLimit = 0,
  });

  factory DvrSettings.fromJson(Json json) => DvrSettings(
        padStart: Duration(
          milliseconds: asInt(json['padStartMs']) ?? defaultPadStart.inMilliseconds,
        ),
        padStop: Duration(
          milliseconds: asInt(json['padStopMs']) ?? defaultPadStop.inMilliseconds,
        ),
        storageDir: asString(json['storageDir']),
        variantPreference: _enumByName(
          VariantPreference.values,
          json['variantPreference'],
          VariantPreference.highest,
        ),
        autoExtendWatch: asBool(json['autoExtendWatch']) ?? true,
        cachedStreamLimit: asInt(json['cachedStreamLimit']) ?? 0,
      );

  static const defaultPadStart = Duration(minutes: 2);
  static const defaultPadStop = Duration(minutes: 5);

  /// (before, after) in minutes, as offered by the Android app.
  static const paddingPresets = [(0, 0), (1, 2), (2, 5), (5, 10), (5, 20), (10, 30)];

  final Duration padStart;
  final Duration padStop;

  /// Safety stop so a channel that never ends cannot fill the drive.
  final Duration maxDuration;
  final int minFreeBytes;

  /// Folder for recordings; null means the default (Videos\ZipTop).
  final String? storageDir;
  final VariantPreference variantPreference;

  /// Keep an unattended recording alive through the "are you still
  /// watching?" window by answering it automatically.
  final bool autoExtendWatch;

  /// Last known concurrent-stream allowance, for overlap warnings.
  final int cachedStreamLimit;

  DvrSettings copyWith({
    Duration? padStart,
    Duration? padStop,
    Object? storageDir = _keep,
    VariantPreference? variantPreference,
    bool? autoExtendWatch,
    int? cachedStreamLimit,
  }) =>
      DvrSettings(
        padStart: padStart ?? this.padStart,
        padStop: padStop ?? this.padStop,
        maxDuration: maxDuration,
        minFreeBytes: minFreeBytes,
        storageDir: identical(storageDir, _keep) ? this.storageDir : storageDir as String?,
        variantPreference: variantPreference ?? this.variantPreference,
        autoExtendWatch: autoExtendWatch ?? this.autoExtendWatch,
        cachedStreamLimit: cachedStreamLimit ?? this.cachedStreamLimit,
      );

  Json toJson() => {
        'padStartMs': padStart.inMilliseconds,
        'padStopMs': padStop.inMilliseconds,
        'storageDir': storageDir,
        'variantPreference': variantPreference.name,
        'autoExtendWatch': autoExtendWatch,
        'cachedStreamLimit': cachedStreamLimit,
      };
}

/// Shared title normalisation. Series matching has no programme id to go on.
String normalizeTitle(String title) => title
    .toLowerCase()
    .replaceFirst(RegExp(r'^(new|live)[:\s]+'), '')
    .replaceFirst(RegExp(r'\s*\((19|20)\d{2}\)\s*$'), '')
    .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
