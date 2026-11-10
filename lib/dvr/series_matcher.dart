import '../core/models/guide.dart';
import 'dvr_store.dart';
import 'models.dart';

/// Turns "record every episode" rules into concrete scheduled recordings.
///
/// The guide carries no programme or series identifier, so matching is by
/// normalised title. That is fuzzy by nature, which is why the planner is a
/// pure function over (rules, guide, existing rows): it is the only place
/// the fuzziness lives.
abstract final class SeriesMatcher {
  /// Headroom above keepMax so a mis-normalised title cannot fill the store.
  static const pendingHeadroom = 3;

  /// The recordings [rules] would add, given a guide and what already
  /// exists. No I/O and no store writes.
  static List<Recording> plan({
    required List<SeriesRule> rules,
    required Guide guide,
    required List<Recording> existing,
    required Set<String> dismissedAiringKeys,
    required DateTime now,
    required String Function() newId,
  }) {
    final planned = <Recording>[];

    bool sameAiring(Recording r, String streamId, String titleNorm, DateTime start) =>
        r.streamId == streamId &&
        r.titleNorm == titleNorm &&
        r.plannedStart.difference(start).abs() < DvrStore.airingMatchWindow;

    for (final rule in rules) {
      if (!rule.enabled) continue;

      final pending = existing.where((r) => r.seriesRuleId == rule.id && !r.isTerminal).length;
      final allowance = rule.keepMax <= 0
          ? 1 << 30
          : (rule.keepMax + pendingHeadroom - pending).clamp(0, 1 << 30);
      if (allowance == 0) continue;

      var added = 0;
      for (final channel in guide.channels) {
        if (rule.streamId != null && channel.id != rule.streamId) continue;
        for (final programme in channel.programmes) {
          if (added >= allowance) break;
          if (!programme.start.isAfter(now)) continue;
          if (!programme.stop.isAfter(programme.start)) continue;

          final titleNorm = normalizeTitle(programme.title);
          if (titleNorm != rule.titleNorm) continue;

          final start = programme.start.subtract(rule.padStart);
          final stop = programme.stop.add(rule.padStop);

          // Against what is stored, whatever its state: a cancelled row is a
          // tombstone that stops the rule re-adding what the viewer declined.
          if (existing.any((r) => sameAiring(r, channel.id, titleNorm, start))) continue;
          // ...and against what this same pass already planned.
          if (planned.any((r) => sameAiring(r, channel.id, titleNorm, start))) continue;

          final candidate = Recording(
            id: newId(),
            streamId: channel.id,
            streamName: channel.name,
            streamType: channel.type ?? '',
            title: programme.title,
            titleNorm: titleNorm,
            description: programme.description,
            epgStart: programme.start,
            epgStop: programme.stop,
            plannedStart: start,
            plannedStop: stop,
            seriesRuleId: rule.id,
            createdAt: now,
          );
          if (dismissedAiringKeys.contains(candidate.airingKey)) continue;

          planned.add(candidate);
          added++;
        }
        if (added >= allowance) break;
      }
    }
    return planned;
  }

  /// How many future airings of this title the guide currently shows.
  static int countFutureAirings(Guide guide, String? streamId, String titleNorm, DateTime now) {
    var count = 0;
    for (final channel in guide.channels) {
      if (streamId != null && channel.id != streamId) continue;
      for (final programme in channel.programmes) {
        if (programme.start.isAfter(now) && normalizeTitle(programme.title) == titleNorm) {
          count++;
        }
      }
    }
    return count;
  }
}
