import 'package:dio/dio.dart' show Response;

import '../models/catalog.dart';
import '../models/guide.dart';
import '../models/playback.dart';
import 'api_client.dart';

/// A conditional GET: [value] is null when the server answered 304.
class Revalidated<T> {
  const Revalidated(this.value, this.etag);
  final T? value;
  final String? etag;

  bool get notModified => value == null;
}

/// Browsing: `/api/v2`. Every row arrives from the server already ordered and
/// filtered for this account.
class StreamsV2Api {
  StreamsV2Api(this._client);

  final ApiClient _client;

  Never _fail(Response<dynamic> res, String what) => throw ApiException(
        res.errorMessage ?? '$what (${res.statusCode})',
        status: res.statusCode,
      );

  Future<Revalidated<Catalog>> catalog({String? etag}) async {
    final res = await _client.get(
      'api/v2/catalog',
      query: {'include_hidden': 1},
      headers: {'If-None-Match': etag},
    );
    if (res.statusCode == 304) return Revalidated(null, etag);
    final json = res.json;
    if (!res.ok || json == null) _fail(res, 'Could not load channels');
    return Revalidated(Catalog.fromJson(json), res.headers.value('etag'));
  }

  Future<Revalidated<LiveState>> live({String? etag}) async {
    final res = await _client.get('api/v2/live', headers: {'If-None-Match': etag});
    if (res.statusCode == 304) return Revalidated(null, etag);
    final json = res.json;
    if (!res.ok || json == null) _fail(res, 'Could not load live state');
    return Revalidated(LiveState.fromJson(json), res.headers.value('etag'));
  }

  Future<Guide> guide({required int hours, String? category}) async {
    final res = await _client.get(
      'api/v2/guide',
      query: {'hours': hours, 'category': category},
    );
    final json = res.json;
    if (!res.ok || json == null) _fail(res, 'Could not load the guide');
    return Guide.fromJson(json);
  }

  Future<FavoritesResult> setFavorite(String streamId, bool favorite) async {
    final path = 'api/v2/favorites/${Uri.encodeComponent(streamId)}';
    final res = favorite ? await _client.put(path) : await _client.delete(path);
    final json = res.json;
    if (!res.ok || json == null) _fail(res, 'Could not update favorites');
    return FavoritesResult.fromJson(json);
  }

  Future<CategoryPrefs> preferences() async {
    final res = await _client.get('api/v2/categories/preferences');
    final json = res.json;
    if (!res.ok || json == null) _fail(res, 'Could not load categories');
    return CategoryPrefs.fromJson(json);
  }

  Future<CategoryPrefs> updatePreferences(CategoryPrefsUpdate update) async {
    final res = await _client.put('api/v2/categories/preferences', data: update.toJson());
    final json = res.json;
    if (!res.ok || json == null) _fail(res, 'Could not save categories');
    return CategoryPrefs.fromJson(json);
  }
}
