import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/streams_v2_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/guide.dart';
import 'package:ziptop/core/stores/guide_repository.dart';
import 'package:ziptop/features/guide/guide_view.dart';

class FakeV2Api extends StreamsV2Api {
  FakeV2Api()
      : super(ApiClient(config: ApiConfig(), tokens: MemoryTokenStore(), events: AuthEvents()));

  int calls = 0;
  bool fail = false;

  @override
  Future<Guide> guide({required int hours, String? category}) async {
    calls++;
    if (fail) throw Exception('offline');
    return Guide(windowHours: hours);
  }
}

Programme prog(String title, DateTime start, int minutes, {bool onNow = false}) => Programme(
      title: title,
      start: start,
      stop: start.add(Duration(minutes: minutes)),
      isOnNow: onNow,
    );

void main() {
  group('GuideRepository', () {
    late FakeV2Api api;
    late DateTime now;
    late GuideRepository repo;

    setUp(() {
      api = FakeV2Api();
      now = DateTime(2026, 1, 1, 12);
      repo = GuideRepository(api, clock: () => now);
    });

    test('asks for 24 hours and reuses the answer for five minutes', () async {
      final first = await repo.load();
      expect(first.windowHours, 24);

      now = now.add(const Duration(minutes: 4));
      expect(identical(await repo.load(), first), isTrue);
      expect(api.calls, 1);

      now = now.add(const Duration(minutes: 2));
      await repo.load();
      expect(api.calls, 2);
    });

    test('force refetches, and concurrent callers share one request', () async {
      await repo.load();
      final both = await Future.wait([repo.load(force: true), repo.load(force: true)]);
      expect(api.calls, 2);
      expect(identical(both[0], both[1]), isTrue);
    });

    test('a failed fetch keeps the old guide and can be retried', () async {
      final first = await repo.load();
      api.fail = true;
      await expectLater(repo.load(force: true), throwsException);
      expect(identical(repo.guide, first), isTrue);

      api.fail = false;
      await repo.load(force: true);
      expect(api.calls, 3);
    });
  });

  group('programmeOnNow', () {
    final noon = DateTime(2026, 1, 1, 12);

    test('goes by the clock', () {
      final list = [prog('A', noon, 60), prog('B', noon.add(const Duration(hours: 1)), 60)];
      expect(programmeOnNow(list, noon.add(const Duration(minutes: 30)))?.title, 'A');
      expect(programmeOnNow(list, noon.add(const Duration(minutes: 60)))?.title, 'B');
    });

    test('falls back to the server flag when the feed clock is off', () {
      final list = [
        prog('Old', noon.subtract(const Duration(hours: 5)), 60, onNow: true),
        prog('Older', noon.subtract(const Duration(hours: 6)), 60),
      ];
      expect(programmeOnNow(list, noon)?.title, 'Old');
      expect(programmeOnNow([prog('X', noon.add(const Duration(hours: 2)), 30)], noon), isNull);
    });
  });

  group('GuideLayout', () {
    final layout = GuideLayout(now: DateTime(2026, 1, 1, 12, 47));

    test('starts at the previous half hour and spans 24 hours', () {
      expect(layout.start, DateTime(2026, 1, 1, 12, 30));
      expect(layout.width, 24 * 60 * GuideLayout.pxPerMinute);
      expect(GuideLayout(now: DateTime(2026, 1, 1, 12, 10)).start, DateTime(2026, 1, 1, 12));
    });

    test('places a programme by its times', () {
      final box = layout.blockFor(prog('A', DateTime(2026, 1, 1, 13), 30))!;
      expect(box.left, 30 * GuideLayout.pxPerMinute);
      expect(box.width, 30 * GuideLayout.pxPerMinute);
    });

    test('clips a programme that began before the window', () {
      final box = layout.blockFor(prog('A', DateTime(2026, 1, 1, 12), 60))!;
      expect(box.left, 0);
      expect(box.width, 30 * GuideLayout.pxPerMinute);
    });

    test('drops programmes outside the window', () {
      expect(layout.blockFor(prog('Past', DateTime(2026, 1, 1, 11), 60)), isNull);
      expect(layout.blockFor(prog('Far', DateTime(2026, 1, 3), 60)), isNull);
    });
  });

  test('clock format', () {
    expect(formatClock(DateTime(2026, 1, 1, 0, 5)), '12:05 AM');
    expect(formatClock(DateTime(2026, 1, 1, 12, 0)), '12:00 PM');
    expect(formatClock(DateTime(2026, 1, 1, 15, 30)), '3:30 PM');
  });
}
