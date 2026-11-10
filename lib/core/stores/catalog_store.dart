import 'package:flutter/foundation.dart' hide Category;

import '../api/streams_v2_api.dart';
import '../models/catalog.dart';

/// The account's channel catalogue, shared by every screen: channels, the
/// server's ordered categories, favorites and live state.
///
/// Nothing here decides what a row holds. Popular now, Continue Watching,
/// Favorites, All channels and every channel category arrive built and
/// ordered, with the account's hidden choices flagged.
class CatalogStore extends ChangeNotifier {
  CatalogStore(this._api, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  /// Floor between catalogue revalidations.
  static const catalogMaxAge = Duration(seconds: 60);

  /// Floor between live polls (what's running, Popular now).
  static const liveMaxAge = Duration(seconds: 15);

  final StreamsV2Api _api;
  final DateTime Function() _now;

  List<Channel> _channels = const [];
  Map<String, Channel> _byId = const {};
  List<Category> _categories = const [];
  Set<String> _favoriteIds = const {};
  LiveState _live = const LiveState();
  bool _canViewCounts = false;

  DateTime? _loadedAt;
  DateTime? _liveAt;
  String? _etag;
  String? _liveEtag;

  bool get isLoaded => _loadedAt != null;
  Map<String, Channel> get channelsById => _byId;

  /// Every category in display order, hidden ones included (flagged).
  List<Category> get categories => _categories;
  Set<String> get favoriteIds => _favoriteIds;
  LiveState get live => _live;
  bool get canViewCounts => _canViewCounts;

  List<Category> get visibleCategories =>
      [for (final c in _categories) if (!c.hidden) c];

  Category? category(String? id) {
    if (id == null) return null;
    for (final c in _categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Every channel in All channels order.
  List<Channel> get allChannels {
    final order = category(CategoryIds.all)?.streamIds;
    if (order == null) return _channels;
    return [
      for (final id in order)
        if (_byId[id] != null) _byId[id]!,
    ];
  }

  /// A row's channels. Popular now follows the live poll, which is fresher.
  List<Channel> channelsIn(Category category) {
    final ids = category.id == CategoryIds.popular && _live.popularIds != null
        ? _live.popularIds!
        : category.streamIds;
    return [
      for (final id in ids)
        if (_byId[id] != null) _byId[id]!,
    ];
  }

  bool isFavorite(String streamId) => _favoriteIds.contains(streamId);

  /// running, paused, retrying, unavailable or stopped.
  String stateOf(Channel channel) =>
      channel.isAlwaysOn ? 'running' : _live.states[channel.id] ?? 'stopped';

  bool isRunning(Channel channel) {
    final state = stateOf(channel);
    return state == 'running' || state == 'paused';
  }

  int? viewerCount(String streamId) => _live.viewerCounts?[streamId];

  /// Fetches the catalogue, revalidating with its ETag. True when it changed.
  Future<bool> refresh() async {
    final result = await _api.catalog(etag: isLoaded ? _etag : null);
    final catalog = result.value;
    if (catalog == null) {
      _loadedAt = _now();
      return false;
    }
    apply(catalog);
    _etag = result.etag;
    return true;
  }

  /// Revalidates when older than [maxAge]. Failures are swallowed: a stale
  /// catalogue is still usable.
  Future<bool> refreshIfStale([Duration maxAge = catalogMaxAge]) async {
    final loadedAt = _loadedAt;
    if (loadedAt != null && _now().difference(loadedAt) < maxAge) return false;
    try {
      return await refresh();
    } catch (_) {
      return false;
    }
  }

  /// Polls live state when older than [maxAge]; true when it moved.
  Future<bool> refreshLiveIfStale([Duration maxAge = liveMaxAge]) async {
    final now = _now();
    final liveAt = _liveAt;
    if (liveAt != null && now.difference(liveAt) < maxAge) return false;
    // Stamped before the request, so a caller polling every maxAge isn't
    // skipped by the time the previous response took to arrive.
    _liveAt = now;
    try {
      final result = await _api.live(etag: _liveEtag);
      final live = result.value;
      if (live == null) return false;
      _liveEtag = result.etag;
      _live = live;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  void apply(Catalog catalog) {
    _channels = catalog.streams;
    _byId = {for (final c in catalog.streams) c.id: c};
    _categories = catalog.categories;
    _favoriteIds = catalog.favoriteIds.toSet();
    _canViewCounts = catalog.canViewCounts;
    _loadedAt = _now();
    notifyListeners();
  }

  /// Stars or unstars a channel. Applied locally at once, then replaced by the
  /// server's list; rolled back on failure. Favorites also lead every other
  /// row, so the catalogue is refetched afterwards.
  Future<void> setFavorite(String streamId, bool favorite) async {
    final before = _favoriteIds;
    _favoriteIds = favorite ? {...before, streamId} : ({...before}..remove(streamId));
    notifyListeners();
    try {
      final result = await _api.setFavorite(streamId, favorite);
      _favoriteIds = result.favoriteIds.toSet();
      _categories = [
        for (final c in _categories)
          c.id == CategoryIds.favorites ? c.withStreamIds(result.favoriteIds) : c,
      ];
      notifyListeners();
    } catch (_) {
      _favoriteIds = before;
      notifyListeners();
      rethrow;
    }
    try {
      await refresh();
    } catch (_) {
      // The optimistic state above already reflects the change.
    }
  }

  Future<CategoryPrefs> loadPreferences() => _api.preferences();

  /// Saves a preferences change, then refreshes the catalogue so rows reflect it.
  Future<CategoryPrefs> updatePreferences(CategoryPrefsUpdate update) async {
    final prefs = await _api.updatePreferences(update);
    try {
      await refresh();
    } catch (_) {
      // Saved; the next poll picks the new order up.
    }
    return prefs;
  }

  /// Drops everything, e.g. on sign-out.
  void clear() {
    _channels = const [];
    _byId = const {};
    _categories = const [];
    _favoriteIds = const {};
    _live = const LiveState();
    _loadedAt = null;
    _liveAt = null;
    _etag = null;
    _liveEtag = null;
    notifyListeners();
  }
}
