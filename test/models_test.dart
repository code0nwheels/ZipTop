import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/streams_v2_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/catalog.dart';
import 'package:ziptop/core/models/guide.dart';
import 'package:ziptop/core/models/json.dart';
import 'package:ziptop/core/stores/catalog_store.dart';

/// Parses the backend's documented /api/v2 examples, copied from the Android
/// TV app's test resources. Refresh the copies when the contract changes.
Json fixture(String name) =>
    asJson(jsonDecode(File('test/fixtures/v2/$name').readAsStringSync()))!;

CatalogStore emptyStore() => CatalogStore(
      StreamsV2Api(
        ApiClient(config: ApiConfig(), tokens: MemoryTokenStore(), events: AuthEvents()),
      ),
    );

void main() {
  test('catalogue leads with the system rows and only references known streams', () {
    final catalog = Catalog.fromJson(fixture('catalog.json'));

    expect(catalog.apiVersion, 2);
    expect(
      catalog.categories.take(4).map((c) => c.id),
      [
        CategoryIds.popular,
        CategoryIds.continueWatching,
        CategoryIds.favorites,
        CategoryIds.all,
      ],
    );
    final known = catalog.streams.map((s) => s.id).toSet();
    for (final category in catalog.categories) {
      expect(known.containsAll(category.streamIds), isTrue, reason: category.id);
    }

    final nhl = catalog.categories.firstWhere((c) => c.id == 'canonical:NHL');
    expect(nhl.feeds.map((f) => f.label), ['Zip', 'AM', 'US']);

    final stream = catalog.streams.firstWhere((s) => s.id == 's-nhl-1');
    expect(stream.type, 'iptv');
    expect(stream.categoryId, 'canonical:NHL');
    expect(stream.nowPlaying?.title, 'NHL Hockey');
  });

  test('catalogue becomes the channel list in All channels order', () {
    final catalog = Catalog.fromJson(fixture('catalog.json'));
    final store = emptyStore()..apply(catalog);

    final all = catalog.categories.firstWhere((c) => c.id == CategoryIds.all);
    expect(store.allChannels.map((c) => c.id), all.streamIds);

    final byId = store.channelsById;
    expect(byId['s-nhl-1']!.number, 4);
    expect(byId['s-ent-1']!.name, 'AMC & Friends <HD>');
    // Only IPTV channels take the start-then-play path.
    expect(byId['s-nhl-1']!.isIptv, isTrue);
    expect(byId['s-247-1']!.isIptv, isFalse);
    expect(byId['r-1']!.isIptv, isFalse);
    expect(store.isFavorite('s-nhlp-2'), isTrue);
    expect(store.visibleCategories.any((c) => c.hidden), isFalse);
    // 24/7 channels count as running with no live entry.
    expect(store.isRunning(byId['s-247-1']!), isTrue);
    expect(store.stateOf(byId['s-nhl-1']!), 'stopped');
  });

  test('plan-scoped catalogue has no Popular row', () {
    final catalog = Catalog.fromJson(fixture('catalog-plan.json'));
    expect(catalog.accessMode, 'plans');
    expect(catalog.categories.any((c) => c.id == CategoryIds.popular), isFalse);
  });

  test('live state parses, with viewer counts only for staff', () {
    final live = LiveState.fromJson(fixture('live.json'));
    expect(live.capacityFull, isTrue);
    expect(live.states['s-uk-1'], 'unavailable');
    expect(live.viewerCounts, isNull);

    final staff = LiveState.fromJson(fixture('live-staff.json'));
    expect(staff.viewerCounts?['s-nhl-1'], 3);
  });

  test('guide parses channels and programme times', () {
    final guide = Guide.fromJson(fixture('guide.json'));
    expect(guide.channels.map((c) => c.id), ['s-nhl-1', 's-nhl-2']);
    expect(guide.windowHours, 12);

    final first = guide.channels.first;
    expect(first.type, 'iptv');
    expect(first.programmes.map((p) => p.title), ['NHL Hockey', 'NHL Tonight']);
    final programme = first.programmes.first;
    expect(programme.start.toUtc(), DateTime.utc(2026, 9, 14, 15));
    expect(programme.isOnNow, isTrue);
    expect(programme.airsAt(DateTime.utc(2026, 9, 14, 16)), isTrue);
    expect(programme.airsAt(DateTime.utc(2026, 9, 14, 18)), isFalse);
  });

  test('preferences and favorites parse', () {
    final prefs = CategoryPrefs.fromJson(fixture('preferences.json'));
    final favorites = prefs.categories.firstWhere((c) => c.id == CategoryIds.favorites);
    expect(favorites.reorderable, isFalse);
    expect(prefs.order, isNotEmpty);

    final saved = CategoryPrefs.fromJson(fixture('preferences-put.json'));
    expect(saved.hidden, contains(CategoryIds.continueWatching));

    final put = FavoritesResult.fromJson(fixture('favorite-put.json'));
    expect(put.isFavorite, isTrue);
    expect(put.favoriteIds.first, 's-nhl-1');
  });

  test('preferences update sends only what changed', () {
    expect(
      jsonEncode(const CategoryPrefsUpdate(hide: ['canonical:NHL']).toJson()),
      '{"hide":["canonical:NHL"]}',
    );
  });
}
