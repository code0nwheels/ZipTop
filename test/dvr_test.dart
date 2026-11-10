import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/streams_v2_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/guide.dart';
import 'package:ziptop/core/models/playback.dart';
import 'package:ziptop/core/session/playback_session.dart';
import 'package:ziptop/core/stores/guide_repository.dart';
import 'package:ziptop/dvr/dvr_service.dart';
import 'package:ziptop/dvr/dvr_store.dart';
import 'package:ziptop/dvr/models.dart';
import 'package:ziptop/dvr/recording_runner.dart';
import 'package:ziptop/dvr/series_matcher.dart';

import 'fakes.dart';

final noon = DateTime(2026, 3, 1, 12);

Programme prog(String title, DateTime start, [int minutes = 60]) => Programme(
      title: title,
      start: start,
      stop: start.add(Duration(minutes: minutes)),
    );

Recording rec(
  String id, {
  String streamId = 's1',
  String title = 'Show',
  DateTime? start,
  int minutes = 60,
  RecordingState state = RecordingState.scheduled,
  String? ruleId,
  String? filePath,
  int bytes = 0,
}) {
  final s = start ?? noon;
  return Recording(
    id: id,
    streamId: streamId,
    streamName: 'Channel $streamId',
    streamType: 'iptv',
    title: title,
    titleNorm: normalizeTitle(title),
    plannedStart: s,
    plannedStop: s.add(Duration(minutes: minutes)),
    state: state,
    seriesRuleId: ruleId,
    filePath: filePath,
    bytesWritten: bytes,
    actualStart: state == RecordingState.scheduled ? null : s,
    createdAt: noon,
  );
}

SeriesRule rule(String id, String title, {String? streamId = 's1', int keepMax = 5}) => SeriesRule(
      id: id,
      displayTitle: title,
      titleNorm: normalizeTitle(title),
      streamId: streamId,
      padStart: const Duration(minutes: 2),
      padStop: const Duration(minutes: 5),
      keepMax: keepMax,
      createdAt: noon,
    );

GuideRepository emptyGuideRepo() => GuideRepository(
      StreamsV2Api(
        ApiClient(config: ApiConfig(), tokens: MemoryTokenStore(), events: AuthEvents()),
      ),
    );

void main() {
  test('title normalisation matches the Android app', () {
    expect(normalizeTitle('NEW: The Late Show (2024)'), 'the late show');
    expect(normalizeTitle('Live   NHL Hockey!'), 'nhl hockey');
    expect(normalizeTitle("Grey's Anatomy"), 'grey s anatomy');
    expect(normalizeTitle('  News  '), 'news');
  });

  group('DvrStore', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('ziptop_dvr_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('everything survives a reload', () async {
      final file = File('${temp.path}/dvr.json');
      final store = await DvrStore.open(file);
      store.add(rec('a', filePath: r'C:\x\a.ts', bytes: 10, state: RecordingState.completed));
      store.addRule(rule('r1', 'Show'));
      store.saveSettings(
        store.settings.copyWith(
          padStart: const Duration(minutes: 5),
          storageDir: r'D:\Recordings',
          variantPreference: VariantPreference.atMost720p,
          autoExtendWatch: false,
        ),
      );
      store.dismissAiring('k1');
      await store.saved;

      final again = await DvrStore.open(file);
      final a = again.byId('a')!;
      expect(a.state, RecordingState.completed);
      expect(a.filePath, r'C:\x\a.ts');
      expect(a.plannedStart, noon);
      expect(a.hasPlayableFile, isTrue);
      expect(again.rules.single.titleNorm, 'show');
      expect(again.settings.padStart, const Duration(minutes: 5));
      expect(again.settings.storageDir, r'D:\Recordings');
      expect(again.settings.variantPreference, VariantPreference.atMost720p);
      expect(again.settings.autoExtendWatch, isFalse);
      expect(again.dismissedAiringKeys, {'k1'});
    });

    test('a corrupt file is set aside rather than stopping the app', () async {
      final file = File('${temp.path}/dvr.json')..writeAsStringSync('{not json');
      final store = await DvrStore.open(file);
      expect(store.recordings, isEmpty);
      expect(File('${file.path}.corrupt').existsSync(), isTrue);
    });

    test('lists, same-airing lookup and conflicts', () async {
      final store = await DvrStore.open(null);
      store.addAll([
        rec('later', start: noon.add(const Duration(hours: 3))),
        rec('soon', start: noon.add(const Duration(hours: 1))),
        rec('running', streamId: 's2', state: RecordingState.recording),
        rec('done', state: RecordingState.completed, start: noon.subtract(const Duration(days: 1))),
        rec('gone', state: RecordingState.cancelled),
      ]);

      expect(store.scheduled.map((r) => r.id), ['soon', 'later']);
      expect(store.active.single.id, 'running');
      expect(store.finished.map((r) => r.id), ['done']);

      final at = noon.add(const Duration(hours: 1, minutes: 20));
      expect(store.findSameAiring('s1', 'show', at)?.id, 'soon');
      expect(store.findSameAiring('s9', 'show', at), isNull);

      final conflicts = store.conflictsAt(
        noon,
        noon.add(const Duration(minutes: 30)),
        excludeStreamId: 's1',
      );
      expect(conflicts.map((r) => r.id), ['running']);
    });
  });

  group('SeriesMatcher', () {
    Guide guideWith(List<Programme> programmes, {String id = 's1'}) => Guide(
          channels: [GuideChannel(id: id, name: 'Channel', type: 'iptv', programmes: programmes)],
        );
    var n = 0;
    String newId() => 'new${n++}';

    test('schedules future airings of the title, padded, on the rule channel', () {
      final guide = guideWith([
        prog('Show', noon.subtract(const Duration(hours: 1))), // already started
        prog('NEW: Show (2026)', noon.add(const Duration(hours: 1))),
        prog('Other', noon.add(const Duration(hours: 2))),
        prog('Show', noon.add(const Duration(hours: 5))),
      ]);
      final planned = SeriesMatcher.plan(
        rules: [rule('r1', 'Show')],
        guide: guide,
        existing: const [],
        dismissedAiringKeys: const {},
        now: noon,
        newId: newId,
      );

      expect(planned, hasLength(2));
      expect(planned.first.plannedStart, noon.add(const Duration(minutes: 58)));
      expect(planned.first.plannedStop, noon.add(const Duration(hours: 2, minutes: 5)));
      expect(planned.every((r) => r.seriesRuleId == 'r1'), isTrue);

      // Other channels are ignored.
      expect(
        SeriesMatcher.plan(
          rules: [rule('r1', 'Show', streamId: 'other')],
          guide: guide,
          existing: const [],
          dismissedAiringKeys: const {},
          now: noon,
          newId: newId,
        ),
        isEmpty,
      );
    });

    test('does not re-add what exists, was cancelled or was dismissed', () {
      final guide = guideWith([
        prog('Show', noon.add(const Duration(hours: 1))),
        prog('Show', noon.add(const Duration(hours: 5))),
      ]);
      final first = SeriesMatcher.plan(
        rules: [rule('r1', 'Show')],
        guide: guide,
        existing: const [],
        dismissedAiringKeys: const {},
        now: noon,
        newId: newId,
      );

      final existing = [first[0].copyWith(state: RecordingState.cancelled)];
      final second = SeriesMatcher.plan(
        rules: [rule('r1', 'Show')],
        guide: guide,
        existing: existing,
        dismissedAiringKeys: {first[1].airingKey},
        now: noon,
        newId: newId,
      );
      expect(second, isEmpty);
    });

    test('stops at the keep limit plus headroom', () {
      final guide = guideWith([
        for (var i = 1; i <= 12; i++) prog('Show', noon.add(Duration(hours: i * 2))),
      ]);
      final planned = SeriesMatcher.plan(
        rules: [rule('r1', 'Show', keepMax: 2)],
        guide: guide,
        existing: const [],
        dismissedAiringKeys: const {},
        now: noon,
        newId: newId,
      );
      expect(planned, hasLength(2 + SeriesMatcher.pendingHeadroom));
      expect(SeriesMatcher.countFutureAirings(guide, 's1', 'show', noon), 12);
    });
  });

  group('DvrService', () {
    late DvrStore store;
    late DateTime now;
    late DvrService service;

    setUp(() async {
      store = await DvrStore.open(null);
      now = noon;
      service = DvrService(
        store: store,
        api: FakeStreamsApi(),
        config: ApiConfig(),
        guide: emptyGuideRepo(),
        clock: () => now,
      );
    });

    tearDown(() => service.dispose());

    const channel = (id: 's1', name: 'Channel One', type: 'iptv');

    test('a future programme is scheduled with padding and not duplicated', () {
      final programme = prog('Show', noon.add(const Duration(hours: 2)));
      final first = service.scheduleProgramme(channel, programme);
      final again = service.scheduleProgramme(channel, programme);

      expect(again.id, first.id);
      expect(store.recordings, hasLength(1));
      expect(first.state, RecordingState.scheduled);
      expect(first.plannedStart, noon.add(const Duration(hours: 1, minutes: 58)));
      expect(first.plannedStop, noon.add(const Duration(hours: 3, minutes: 5)));
      expect(service.pendingFor('s1', programme)?.id, first.id);
      expect(service.hasPendingWork, isTrue);
    });

    test('cancelling a one-off removes it; a series airing leaves a tombstone', () {
      final one = service.scheduleProgramme(channel, prog('Show', noon.add(const Duration(hours: 2))));
      service.cancel(one.id);
      expect(store.recordings, isEmpty);

      store.add(rec('s', ruleId: 'r1', start: noon.add(const Duration(hours: 4))));
      service.cancel('s');
      expect(store.byId('s')!.state, RecordingState.cancelled);
      expect(store.dismissedAiringKeys, hasLength(1));
      expect(store.finished, isEmpty);
    });

    test('a recording whose window passed while the app was closed is marked missed', () {
      store.add(rec('old', start: noon.subtract(const Duration(hours: 3))));
      service.start();
      final row = store.byId('old')!;
      expect(row.state, RecordingState.failed);
      expect(row.failure, RecordingFailure.missed);
    });

    test('a recording cut off by the app closing is recovered on start', () {
      final temp = Directory.systemTemp.createTempSync('ziptop_dvr_rec');
      addTearDown(() => temp.deleteSync(recursive: true));
      final part = File('${temp.path}/x.part')..writeAsBytesSync(List.filled(2048, 1));
      store.addAll([
        rec('cut', state: RecordingState.recording, filePath: part.path),
        rec('empty', streamId: 's2', state: RecordingState.recording),
      ]);
      service.start();

      expect(store.byId('cut')!.state, RecordingState.partial);
      expect(store.byId('cut')!.bytesWritten, 2048);
      expect(store.byId('empty')!.state, RecordingState.failed);
    });

    test('warns when overlapping recordings exceed the stream limit', () {
      store.add(rec('other', streamId: 's2', start: noon));
      final stop = noon.add(const Duration(minutes: 30));
      expect(service.conflictWarning(noon, stop, streamId: 's1'), 'Overlaps 1 other recording.');

      store.saveSettings(store.settings.copyWith(cachedStreamLimit: 1));
      expect(service.conflictWarning(noon, stop, streamId: 's1'), contains('allows 1 stream'));
      expect(service.conflictWarning(noon, stop, streamId: 's2'), isNull);
    });

    test('removing a series rule removes its scheduled recordings', () {
      store.addRule(rule('r1', 'Show'));
      store.addAll([
        rec('a', ruleId: 'r1', start: noon.add(const Duration(hours: 2))),
        rec('b', ruleId: 'r1', state: RecordingState.completed),
      ]);
      service.removeRule('r1');
      expect(store.rules, isEmpty);
      expect(store.recordings.map((r) => r.id), ['b']);
    });
  });

  group('RecordingRunner end to end', () {
    late HttpServer server;
    late Directory temp;
    late DvrStore store;
    late FakeStreamsApi api;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('ziptop_runner');
      store = await DvrStore.open(null);
      api = FakeStreamsApi();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var fetches = 0;
      server.listen((request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          final c = fetches++;
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:$c\n'
            '#EXTINF:1,\nseg$c.ts\n#EXTINF:1,\nseg${c + 1}.ts\n#EXTINF:1,\nseg${c + 2}.ts\n',
          );
        } else {
          request.response.add(List.filled(1880, 0x47));
        }
        await request.response.close();
      });
      api.url = 'http://127.0.0.1:${server.port}/index.m3u8';
    });

    tearDown(() async {
      await server.close(force: true);
      temp.deleteSync(recursive: true);
    });

    RecordingRunner runnerFor(String id, {StreamSlots? slots}) => RecordingRunner(
          store: store,
          recordingId: id,
          api: api,
          config: ApiConfig(),
          directory: temp,
          slots: slots,
        );

    Recording shortRecording(String id, {String title = 'Short: Show?'}) {
      final now = DateTime.now();
      return Recording(
        id: id,
        streamId: 's1',
        streamName: 'Channel One',
        streamType: 'iptv',
        title: title,
        titleNorm: normalizeTitle(title),
        plannedStart: now,
        plannedStop: now.add(const Duration(milliseconds: 2500)),
        createdAt: now,
      );
    }

    test('records to a .ts file, completes, and releases the stream', () async {
      store.add(shortRecording('r'));
      await runnerFor('r').run();

      final row = store.byId('r')!;
      expect(row.state, RecordingState.completed);
      expect(row.failure, RecordingFailure.none);
      expect(row.container, 'ts');
      expect(row.gapCount, 0);
      expect(row.filePath, endsWith('.ts'));
      expect(row.filePath, contains('Short Show - Channel One - '));
      final file = File(row.filePath!);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), row.bytesWritten);
      expect(row.bytesWritten, greaterThanOrEqualTo(1880 * 3));
      expect(temp.listSync().where((f) => f.path.endsWith('.part')), isEmpty);

      expect(api.calls.take(4), ['limit s1', 'ready s1', 'url s1', 'beat s1']);
      expect(api.calls, containsAll(['leave s1', 'end s1']));
    });

    test('stopping early keeps the file as a partial recording', () async {
      final now = DateTime.now();
      store.add(
        shortRecording('r').copyWith(plannedStop: now.add(const Duration(minutes: 30))),
      );
      final runner = runnerFor('r');
      final done = runner.run();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      runner.stop();
      await done;

      final row = store.byId('r')!;
      expect(row.state, RecordingState.partial);
      expect(row.failure, RecordingFailure.cancelledByUser);
      expect(File(row.filePath!).existsSync(), isTrue);
    });

    test('a stream-limit refusal fails without leaving a file', () async {
      api.limitError = const StreamLimitException('Stream limit reached (2/2)');
      store.add(shortRecording('r'));
      await runnerFor('r').run();

      final row = store.byId('r')!;
      expect(row.state, RecordingState.failed);
      expect(row.failure, RecordingFailure.streamLimit);
      expect(row.filePath, isNull);
      expect(temp.listSync(), isEmpty);
    });

    test('a DASH channel is refused', () async {
      api.url = 'https://h.example/api/hls/1/a/b/manifest.mpd';
      store.add(shortRecording('r'));
      await runnerFor('r').run();
      expect(store.byId('r')!.failure, RecordingFailure.unsupportedDash);
    });

    test('does not leave a stream the viewer is still watching', () async {
      final slots = StreamSlots()..acquire('s1'); // the viewer
      store.add(shortRecording('r'));
      await runnerFor('r', slots: slots).run();

      expect(store.byId('r')!.state, RecordingState.completed);
      expect(api.calls, isNot(contains('leave s1')));
      expect(slots.isHeld('s1'), isTrue);
    });
  });
}
