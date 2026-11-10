import 'package:flutter/material.dart';

import '../../core/models/catalog.dart';
import '../../core/models/guide.dart';
import '../../core/stores/guide_repository.dart';
import '../../dvr/dvr_service.dart';
import '../../dvr/models.dart';
import '../../dvr/series_matcher.dart';
import '../../theme.dart';

RecordTarget recordTargetOf(Channel channel) =>
    (id: channel.id, name: channel.name, type: channel.type ?? '');

/// What is on [channel] now, as a guide programme, when its times are known.
Programme? currentProgrammeOf(Channel channel) {
  final now = channel.nowPlaying;
  final start = now?.start;
  final stop = now?.stop;
  if (start == null || stop == null || !stop.isAfter(DateTime.now())) return null;
  return Programme(
    title: now?.title ?? '',
    description: now?.description,
    start: start,
    stop: stop,
    isOnNow: true,
  );
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Records [programme], after warning about overlaps if there are any.
Future<void> recordProgramme(
  BuildContext context,
  DvrService dvr,
  RecordTarget channel,
  Programme programme,
) async {
  final settings = dvr.store.settings;
  final onAir = !programme.start.isAfter(DateTime.now());
  final start = onAir ? DateTime.now() : programme.start.subtract(settings.padStart);
  final warning = dvr.conflictWarning(
    start,
    programme.stop.add(settings.padStop),
    streamId: channel.id,
  );
  if (warning != null && !await _confirm(context, 'Recording overlap', warning, 'Record anyway')) {
    return;
  }
  dvr.scheduleProgramme(channel, programme);
  if (context.mounted) _toast(context, onAir ? 'Recording started' : 'Recording scheduled');
}

Future<void> recordNextHour(BuildContext context, DvrService dvr, RecordTarget channel) async {
  final now = DateTime.now();
  final warning = dvr.conflictWarning(
    now,
    now.add(const Duration(hours: 1)),
    streamId: channel.id,
  );
  if (warning != null && !await _confirm(context, 'Recording overlap', warning, 'Record anyway')) {
    return;
  }
  dvr.scheduleFromNow(channel);
  if (context.mounted) _toast(context, 'Recording the next hour');
}

/// Asks before creating a series rule, saying how many airings the guide shows.
Future<void> recordSeries(
  BuildContext context,
  DvrService dvr,
  GuideRepository guide,
  RecordTarget channel,
  String title,
) async {
  final current = guide.guide;
  final count = current == null
      ? null
      : SeriesMatcher.countFutureAirings(
          current,
          channel.id,
          normalizeTitle(title),
          DateTime.now(),
        );
  final ok = await _confirm(
    context,
    'Record all episodes',
    'Record every showing of "$title" on ${channel.name}.\n\n'
        '${count == null ? '' : 'The guide currently shows $count upcoming '
            'airing${count == 1 ? '' : 's'}. '}'
        'The guide has no series information, so episodes are matched by title, and '
        'repeats are recorded too.',
    'Record series',
  );
  if (!ok) return;
  final added = dvr.addSeriesRule(channel, title);
  if (context.mounted) {
    _toast(context, added > 0 ? 'Series added: $added scheduled' : 'Series added');
  }
}

Future<bool> _confirm(BuildContext context, String title, String message, String action) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

enum _RecordChoice { programme, hour, series, stop }

/// The Record button on the video: stops a running recording of this channel,
/// or offers what can be recorded from it.
class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.dvr,
    required this.guide,
    required this.channel,
  });

  final DvrService dvr;
  final GuideRepository guide;
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dvr,
      builder: (context, _) {
        final active = dvr.activeOn(channel.id);
        final target = recordTargetOf(channel);
        final programme = currentProgrammeOf(channel);
        final title = programme?.title ?? '';
        return PopupMenuButton<_RecordChoice>(
          tooltip: active == null ? 'Record (R)' : 'Recording: ${active.title}',
          icon: Icon(
            active == null ? Icons.fiber_manual_record_outlined : Icons.fiber_manual_record,
            color: active == null ? null : ZipColors.danger,
          ),
          onSelected: (choice) {
            switch (choice) {
              case _RecordChoice.stop:
                dvr.cancel(active!.id);
              case _RecordChoice.programme:
                recordProgramme(context, dvr, target, programme!);
              case _RecordChoice.hour:
                recordNextHour(context, dvr, target);
              case _RecordChoice.series:
                recordSeries(context, dvr, guide, target, title);
            }
          },
          itemBuilder: (context) => [
            if (active != null)
              const PopupMenuItem(value: _RecordChoice.stop, child: Text('Stop recording'))
            else ...[
              if (programme != null)
                PopupMenuItem(
                  value: _RecordChoice.programme,
                  child: Text(
                    title.isEmpty ? 'Record what is left of this' : 'Record the rest of "$title"',
                  ),
                ),
              const PopupMenuItem(value: _RecordChoice.hour, child: Text('Record the next hour')),
              if (title.isNotEmpty)
                const PopupMenuItem(
                  value: _RecordChoice.series,
                  child: Text('Record all episodes'),
                ),
            ],
          ],
        );
      },
    );
  }
}
