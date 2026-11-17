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

  static const reportFailed = "Couldn't send the report.";
  static const reportRateLimited =
      "You've sent a lot of reports recently. Try again a little later.";

  /// Tells the admins something is wrong with [streamId]. A refreshed earlier
  /// report (`200`, `created: false`) counts as success like a new one.
  ///
  /// Throws [ApiException] with text fit to show the viewer.
  Future<ReportResult> reportProblem(String streamId, ProblemReport report) async {
    final res = await _client.send(
      'POST',
      'api/v2/streams/${Uri.encodeComponent(streamId)}/report',
      data: report.toJson(),
      headers: {'Content-Type': 'application/json'},
    );
    final json = res.json;
    if (res.ok && json != null) return ReportResult.fromJson(json);
    throw ApiException(reportFailureMessage(res), status: res.statusCode);
  }

  /// Older servers without the endpoint answer 404 or 405 with no v2 error
  /// body (Flask's own pages), so they get the generic text.
  static String reportFailureMessage(Response<dynamic> res) {
    final status = res.statusCode;
    if (status == 429 || res.errorCode == 'rate_limited') return reportRateLimited;
    if (res.ok || status == 405) return reportFailed;
    final message = res.errorMessage?.trim();
    return message == null || message.isEmpty ? reportFailed : message;
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
