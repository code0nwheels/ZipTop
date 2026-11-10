import 'package:flutter/foundation.dart';

import '../api/streams_v2_api.dart';
import '../models/guide.dart';

/// The programme guide, cached in memory like the Android app's: reused for
/// five minutes, then fetched again when a screen next asks for it.
class GuideRepository extends ChangeNotifier {
  GuideRepository(this._api, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  static const hours = 24;
  static const maxAge = Duration(minutes: 5);

  final StreamsV2Api _api;
  final DateTime Function() _now;

  Guide? _guide;
  DateTime? _loadedAt;
  Future<Guide>? _inFlight;

  /// The last guide fetched, however old.
  Guide? get guide => _guide;
  DateTime? get loadedAt => _loadedAt;

  bool get isFresh {
    final at = _loadedAt;
    return at != null && _now().difference(at) < maxAge;
  }

  /// Returns the cached guide while it is fresh; otherwise fetches. Callers
  /// that arrive during a fetch share it.
  Future<Guide> load({bool force = false}) {
    final cached = _guide;
    if (!force && cached != null && isFresh) return Future.value(cached);
    return _inFlight ??= _fetch();
  }

  Future<Guide> _fetch() async {
    try {
      final guide = await _api.guide(hours: hours);
      _guide = guide;
      _loadedAt = _now();
      notifyListeners();
      return guide;
    } finally {
      _inFlight = null;
    }
  }

  /// Drops the cache, e.g. on sign-out.
  void clear() {
    _guide = null;
    _loadedAt = null;
    notifyListeners();
  }
}

/// The programme airing at [when]. Falls back to the server's `is_on_now`
/// flag when no programme matches the clock, which happens when an EPG feed's
/// time offsets are wrong.
Programme? programmeOnNow(List<Programme> programmes, DateTime when) {
  for (final p in programmes) {
    if (p.airsAt(when)) return p;
  }
  for (final p in programmes) {
    if (p.isOnNow) return p;
  }
  return null;
}
