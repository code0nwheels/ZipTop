import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/platform/reveal.dart';
import '../../dvr/dvr_service.dart';
import '../../dvr/models.dart';
import '../../theme.dart';
import '../guide/guide_view.dart' show formatClock;

String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).round()} MB';
  return '${(bytes / 1024).round()} KB';
}

String formatDay(DateTime time, [DateTime? today]) {
  final t = time.toLocal();
  final now = (today ?? DateTime.now()).toLocal();
  final days = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days == -1) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[t.weekday - 1]} ${t.day} ${months[t.month - 1]}';
}

String formatLength(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? '${d.inHours} h' : '${d.inHours} h $minutes min';
}

/// Why a recording did not finish cleanly, in the viewer's words.
String describeOutcome(Recording r) {
  final message = r.errorMessage;
  return switch (r.failure) {
    RecordingFailure.none => r.gapCount > 0
        ? 'Has ${r.gapCount} gap${r.gapCount == 1 ? '' : 's'}'
        : 'Shorter than planned',
    RecordingFailure.cancelledByUser => 'Stopped early',
    RecordingFailure.missed => "Missed: ZipTop wasn't running",
    RecordingFailure.unsupportedDash => "This channel's format can't be recorded",
    RecordingFailure.streamLimit => message ?? 'Stream limit reached',
    RecordingFailure.diskFull => message ?? 'Storage is full',
    _ => message ?? 'Recording failed',
  };
}

/// The recordings library: what is coming up, what has been recorded, the
/// series rules and the recording settings.
class RecordingsView extends StatelessWidget {
  const RecordingsView({super.key, required this.dvr, required this.onPlay});

  final DvrService dvr;

  /// Play a recording; [fromStart] ignores the saved position.
  final void Function(Recording recording, {bool fromStart}) onPlay;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dvr,
      builder: (context, _) {
        final store = dvr.store;
        final upcoming = [...store.active, ...store.scheduled];
        return DefaultTabController(
          length: 4,
          child: ColoredBox(
            color: ZipColors.background,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Text('Recordings', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(width: 24),
                      Expanded(
                        child: TabBar(
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          tabs: [
                            Tab(text: 'Upcoming (${upcoming.length})'),
                            Tab(text: 'Recorded (${store.finished.length})'),
                            Tab(text: 'Series (${store.rules.length})'),
                            const Tab(text: 'Settings'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: TabBarView(
                    children: [
                      _list(
                        upcoming,
                        'Nothing scheduled. Record from the guide, or with the record button '
                        'on the video.',
                        (r) => _UpcomingTile(dvr: dvr, recording: r, onPlay: onPlay),
                      ),
                      _list(
                        store.finished,
                        'No recordings yet.',
                        (r) => _RecordedTile(dvr: dvr, recording: r, onPlay: onPlay),
                      ),
                      _list(
                        store.rules,
                        'No series. Choose "Record all episodes" on a programme to add one.',
                        (rule) => _SeriesTile(dvr: dvr, rule: rule),
                      ),
                      _SettingsTab(dvr: dvr),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _list<T>(List<T> items, String empty, Widget Function(T item) tile) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            empty,
            textAlign: TextAlign.center,
            style: const TextStyle(color: ZipColors.textMuted),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, index) => tile(items[index]),
    );
  }
}

class _UpcomingTile extends StatelessWidget {
  const _UpcomingTile({required this.dvr, required this.recording, required this.onPlay});

  final DvrService dvr;
  final Recording recording;
  final void Function(Recording recording, {bool fromStart}) onPlay;

  @override
  Widget build(BuildContext context) {
    final r = recording;
    final running = r.state == RecordingState.recording;
    final when = '${formatDay(r.plannedStart)}  ${formatClock(r.plannedStart)} – '
        '${formatClock(r.plannedStop)}';
    return ListTile(
      leading: Icon(
        running ? Icons.fiber_manual_record : Icons.schedule,
        color: running ? ZipColors.offline : ZipColors.accent,
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        running
            ? '${r.streamName}  ·  Recording, ${formatBytes(r.bytesWritten)} so far  ·  '
                'ends ${formatClock(r.plannedStop)}'
            : '${r.streamName}  ·  $when${r.seriesRuleId == null ? '' : '  ·  Series'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running && r.filePath != null && r.bytesWritten > 0)
            TextButton(
              onPressed: () => onPlay(r, fromStart: true),
              child: const Text('Watch so far'),
            ),
          TextButton(
            onPressed: () => dvr.cancel(r.id),
            child: Text(running ? 'Stop' : 'Cancel'),
          ),
        ],
      ),
    );
  }
}

class _RecordedTile extends StatelessWidget {
  const _RecordedTile({required this.dvr, required this.recording, required this.onPlay});

  final DvrService dvr;
  final Recording recording;
  final void Function(Recording recording, {bool fromStart}) onPlay;

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete recording'),
        content: Text(
          recording.hasPlayableFile
              ? 'Delete "${recording.title}" and its file? This cannot be undone.'
              : 'Remove "${recording.title}" from the list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(recording.hasPlayableFile ? 'Delete' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await dvr.delete(recording.id);
  }

  @override
  Widget build(BuildContext context) {
    final r = recording;
    final start = r.actualStart ?? r.plannedStart;
    final stop = r.actualStop;
    final failed = r.state == RecordingState.failed;
    final partial = r.state == RecordingState.partial;
    final canRetry = failed && DateTime.now().isBefore(r.plannedStop);
    final details = [
      r.streamName,
      '${formatDay(start)}  ${formatClock(start)}',
      if (stop != null && r.hasPlayableFile) formatLength(stop.difference(start)),
      if (r.hasPlayableFile) formatBytes(r.bytesWritten),
    ].join('  ·  ');

    return ListTile(
      leading: Icon(
        failed
            ? Icons.error_outline
            : partial
                ? Icons.warning_amber_rounded
                : Icons.check_circle_outline,
        color: failed
            ? ZipColors.offline
            : partial
                ? ZipColors.retrying
                : ZipColors.live,
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        failed || partial ? '$details\n${describeOutcome(r)}' : details,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: failed || partial,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (r.hasPlayableFile) ...[
            FilledButton.tonal(
              onPressed: () => onPlay(r),
              child: Text(r.resumePositionMs > 0 ? 'Resume' : 'Play'),
            ),
            if (r.resumePositionMs > 0)
              TextButton(
                onPressed: () => onPlay(r, fromStart: true),
                child: const Text('From start'),
              ),
            IconButton(
              tooltip: 'Show in folder',
              onPressed: () => revealInFolder(r.filePath!),
              icon: const Icon(Icons.folder_open, size: 20),
            ),
          ],
          if (canRetry)
            TextButton(onPressed: () => dvr.retry(r.id), child: const Text('Try again')),
          IconButton(
            tooltip: r.hasPlayableFile ? 'Delete' : 'Remove',
            onPressed: () => _confirmDelete(context),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

class _SeriesTile extends StatelessWidget {
  const _SeriesTile({required this.dvr, required this.rule});

  final DvrService dvr;
  final SeriesRule rule;

  @override
  Widget build(BuildContext context) {
    final scheduled = dvr.store.scheduled.where((r) => r.seriesRuleId == rule.id).length;
    return ListTile(
      leading: const Icon(Icons.repeat, color: ZipColors.accent),
      title: Text(rule.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          rule.streamName ?? 'Any channel',
          '$scheduled scheduled',
          rule.keepMax > 0 ? 'keeps the newest ${rule.keepMax}' : 'keeps all',
          if (!rule.enabled) 'paused',
        ].join('  ·  '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: rule.enabled ? 'Pause this series' : 'Resume this series',
            child: Switch(
              value: rule.enabled,
              onChanged: (value) {
                dvr.store.updateRule(rule.id, (r) => r.withEnabled(value));
                if (value) dvr.tick();
              },
            ),
          ),
          IconButton(
            tooltip: 'Delete series',
            onPressed: () => dvr.removeRule(rule.id),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.dvr});

  final DvrService dvr;

  @override
  Widget build(BuildContext context) {
    final store = dvr.store;
    final settings = store.settings;
    final padding = (settings.padStart.inMinutes, settings.padStop.inMinutes);
    final presets = [
      ...DvrSettings.paddingPresets,
      if (!DvrSettings.paddingPresets.contains(padding)) padding,
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Save recordings to'),
          subtitle: Text(dvr.directory.path),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (settings.storageDir != null)
                TextButton(
                  onPressed: () => store.saveSettings(settings.copyWith(storageDir: null)),
                  child: const Text('Use default'),
                ),
              FilledButton.tonal(
                onPressed: () async {
                  final picked = await getDirectoryPath(
                    initialDirectory: dvr.directory.existsSync() ? dvr.directory.path : null,
                    confirmButtonText: 'Record here',
                  );
                  if (picked != null) {
                    store.saveSettings(store.settings.copyWith(storageDir: picked));
                  }
                },
                child: const Text('Change…'),
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: const Text('Quality'),
          trailing: DropdownButton<VariantPreference>(
            value: settings.variantPreference,
            onChanged: (value) {
              if (value != null) store.saveSettings(settings.copyWith(variantPreference: value));
            },
            items: [
              for (final v in VariantPreference.values)
                DropdownMenuItem(value: v, child: Text(v.label)),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.more_time),
          title: const Text('Padding'),
          subtitle: const Text('Start early and finish late, in case the schedule slips'),
          trailing: DropdownButton<(int, int)>(
            value: padding,
            onChanged: (value) {
              if (value == null) return;
              store.saveSettings(
                settings.copyWith(
                  padStart: Duration(minutes: value.$1),
                  padStop: Duration(minutes: value.$2),
                ),
              );
            },
            items: [
              for (final preset in presets)
                DropdownMenuItem(
                  value: preset,
                  child: Text(
                    preset == (0, 0)
                        ? 'None'
                        : '${preset.$1} min before, ${preset.$2} min after',
                  ),
                ),
            ],
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.timer_outlined),
          title: const Text('Keep recordings alive past the watch limit'),
          subtitle: const Text(
            'Answers "are you still watching?" automatically while recording',
          ),
          value: settings.autoExtendWatch,
          onChanged: (value) => store.saveSettings(settings.copyWith(autoExtendWatch: value)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(72, 12, 24, 8),
          child: Text(
            'Recordings only run while ZipTop is open. Each one uses a stream on your '
            'account, and a single recording stops after 6 hours.',
            style: TextStyle(color: ZipColors.textMuted),
          ),
        ),
      ],
    );
  }
}
